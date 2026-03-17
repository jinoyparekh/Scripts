#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# EKS VPC Planner for AWS GovCloud
#
# What it does:
# - inspects a VPC
# - scores subnets for EKS suitability
# - suggests best subnet pairs/trios across AZs
# - suggests whether subnets are public/private-ish
# - shows SGs in the VPC
# - prints a ready-to-run aws eks create-cluster command
#
# Usage:
#   export AWS_REGION=us-gov-west-1
#   export VPC_ID=vpc-0123456789abcdef0
#   export CLUSTER_NAME=my-eks-cluster
#   export CLUSTER_ROLE_ARN=arn:aws-us-gov:iam::123456789012:role/EKSClusterRole
#   bash eks-vpc-plan.sh
#
# Optional:
#   export ENDPOINT_PUBLIC_ACCESS=false
#   export ENDPOINT_PRIVATE_ACCESS=true
#   export K8S_VERSION=1.31
# ============================================================

: "${AWS_REGION:?Set AWS_REGION, for example us-gov-west-1}"
: "${VPC_ID:?Set VPC_ID, for example vpc-0123456789abcdef0}"
: "${CLUSTER_NAME:?Set CLUSTER_NAME}"
: "${CLUSTER_ROLE_ARN:?Set CLUSTER_ROLE_ARN}"

ENDPOINT_PUBLIC_ACCESS="${ENDPOINT_PUBLIC_ACCESS:-false}"
ENDPOINT_PRIVATE_ACCESS="${ENDPOINT_PRIVATE_ACCESS:-true}"
K8S_VERSION="${K8S_VERSION:-}"

AWS="aws --region $AWS_REGION"
WORKDIR="eks-plan-${VPC_ID}-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$WORKDIR"

command -v aws >/dev/null 2>&1 || { echo "aws CLI not found"; exit 1; }
command -v jq  >/dev/null 2>&1 || { echo "jq not found"; exit 1; }

echo "Region        : $AWS_REGION"
echo "VPC           : $VPC_ID"
echo "Cluster       : $CLUSTER_NAME"
echo "Role ARN      : $CLUSTER_ROLE_ARN"
echo "Output folder : $WORKDIR"
echo

# -----------------------------
# Collect raw data
# -----------------------------
$AWS ec2 describe-vpcs --vpc-ids "$VPC_ID" > "$WORKDIR/vpc.json"
$AWS ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" > "$WORKDIR/subnets.json"
$AWS ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" > "$WORKDIR/route_tables.json"
$AWS ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" > "$WORKDIR/security_groups.json"
$AWS ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" > "$WORKDIR/igw.json"
$AWS ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC_ID" > "$WORKDIR/nat.json"

# DNS attributes matter for EKS-friendly VPC behavior
DNS_SUPPORT=$($AWS ec2 describe-vpc-attribute --vpc-id "$VPC_ID" --attribute enableDnsSupport --query 'EnableDnsSupport.Value' --output text)
DNS_HOSTNAMES=$($AWS ec2 describe-vpc-attribute --vpc-id "$VPC_ID" --attribute enableDnsHostnames --query 'EnableDnsHostnames.Value' --output text)

# -----------------------------
# Build subnet scoring table
# -----------------------------
SUBNET_TABLE="$WORKDIR/subnet_scores.tsv"

jq -r '
  .Subnets[]
  | [
      .SubnetId,
      .AvailabilityZone,
      .AvailabilityZoneId,
      .CidrBlock,
      (.AvailableIpAddressCount|tostring),
      (.MapPublicIpOnLaunch|tostring),
      ((.Tags // []) | map(select(.Key=="Name") | .Value) | first // "-")
    ]
  | @tsv
' "$WORKDIR/subnets.json" > "$WORKDIR/subnets_raw.tsv"

get_route_table_for_subnet() {
  local subnet_id="$1"

  local explicit
  explicit=$(jq -r --arg subnet "$subnet_id" '
    .RouteTables[]
    | select(any(.Associations[]?; .SubnetId==$subnet))
    | .RouteTableId
  ' "$WORKDIR/route_tables.json" | head -n1)

  if [[ -n "${explicit:-}" ]]; then
    echo "$explicit"
    return
  fi

  jq -r '
    .RouteTables[]
    | select(any(.Associations[]?; .Main==true))
    | .RouteTableId
  ' "$WORKDIR/route_tables.json" | head -n1
}

classify_subnet_route() {
  local rtb_id="$1"

  if [[ -z "${rtb_id:-}" ]]; then
    echo "unknown"
    return
  fi

  local target
  target=$(jq -r --arg rtb "$rtb_id" '
    .RouteTables[]
    | select(.RouteTableId==$rtb)
    | .Routes[]
    | select(.DestinationCidrBlock=="0.0.0.0/0")
    | if .GatewayId then .GatewayId
      elif .NatGatewayId then .NatGatewayId
      elif .TransitGatewayId then .TransitGatewayId
      elif .VpcPeeringConnectionId then .VpcPeeringConnectionId
      else "other"
      end
  ' "$WORKDIR/route_tables.json" | head -n1)

  if [[ "${target:-}" == igw-* ]]; then
    echo "public"
  elif [[ "${target:-}" == nat-* ]]; then
    echo "private-nat"
  elif [[ -n "${target:-}" ]]; then
    echo "custom"
  else
    echo "isolated"
  fi
}

score_subnet() {
  local free_ips="$1"
  local route_type="$2"
  local map_public="$3"

  local score=0

  # IP capacity: EKS minimum 6, recommended 16+
  if (( free_ips >= 64 )); then
    score=$((score + 40))
  elif (( free_ips >= 32 )); then
    score=$((score + 32))
  elif (( free_ips >= 16 )); then
    score=$((score + 24))
  elif (( free_ips >= 6 )); then
    score=$((score + 10))
  else
    score=$((score - 100))
  fi

  # Prefer private subnets with NAT for worker nodes / common enterprise design
  case "$route_type" in
    private-nat) score=$((score + 25)) ;;
    custom)      score=$((score + 10)) ;;
    isolated)    score=$((score + 0))  ;;
    public)      score=$((score - 5))  ;;
    *)           score=$((score + 0))  ;;
  esac

  # Slight penalty if subnet auto-assigns public IPs
  if [[ "$map_public" == "true" ]]; then
    score=$((score - 3))
  fi

  echo "$score"
}

while IFS=$'\t' read -r subnet az azid cidr free_ips map_public name; do
  rtb=$(get_route_table_for_subnet "$subnet")
  route_type=$(classify_subnet_route "$rtb")
  score=$(score_subnet "$free_ips" "$route_type" "$map_public")

  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$score" "$subnet" "$az" "$azid" "$cidr" "$free_ips" "$route_type" "$map_public" "$name"
done < "$WORKDIR/subnets_raw.tsv" | sort -t$'\t' -k1,1nr > "$SUBNET_TABLE"

# -----------------------------
# Print scored subnets
# -----------------------------
echo "============================================================"
echo "DNS CHECK"
echo "============================================================"
echo "enableDnsSupport   = $DNS_SUPPORT"
echo "enableDnsHostnames = $DNS_HOSTNAMES"
echo

echo "============================================================"
echo "SUBNET SCORES"
echo "============================================================"
awk -F'\t' 'BEGIN {
  printf "%-6s %-22s %-16s %-18s %-8s %-12s %-9s %s\n",
         "Score","SubnetId","AZ","CIDR","FreeIPs","RouteType","PublicIP","Name"
}
{
  printf "%-6s %-22s %-16s %-18s %-8s %-12s %-9s %s\n",
         $1,$2,$3,$5,$6,$7,$8,$9
}' "$SUBNET_TABLE"
echo

# -----------------------------
# Best pair across distinct AZs
# -----------------------------
BEST_PAIR_FILE="$WORKDIR/best_pair.txt"
BEST_TRIO_FILE="$WORKDIR/best_trio.txt"

awk -F'\t' '
{
  score[NR]=$1
  subnet[NR]=$2
  az[NR]=$3
  cidr[NR]=$5
  freeips[NR]=$6
  route[NR]=$7
  name[NR]=$9
  n=NR
}
END {
  best=-999999
  for (i=1; i<=n; i++) {
    if (freeips[i] < 6) continue
    for (j=i+1; j<=n; j++) {
      if (freeips[j] < 6) continue
      if (az[i] == az[j]) continue
      s = score[i] + score[j]
      if (s > best) {
        best=s
        bi=i
        bj=j
      }
    }
  }
  if (best > -999999) {
    print subnet[bi] "\t" az[bi] "\t" freeips[bi] "\t" route[bi] "\t" name[bi]
    print subnet[bj] "\t" az[bj] "\t" freeips[bj] "\t" route[bj] "\t" name[bj]
  }
}' "$SUBNET_TABLE" > "$BEST_PAIR_FILE"

awk -F'\t' '
{
  score[NR]=$1
  subnet[NR]=$2
  az[NR]=$3
  cidr[NR]=$5
  freeips[NR]=$6
  route[NR]=$7
  name[NR]=$9
  n=NR
}
END {
  best=-999999
  for (i=1; i<=n; i++) {
    if (freeips[i] < 6) continue
    for (j=i+1; j<=n; j++) {
      if (freeips[j] < 6) continue
      if (az[i] == az[j]) continue
      for (k=j+1; k<=n; k++) {
        if (freeips[k] < 6) continue
        if (az[k] == az[i] || az[k] == az[j]) continue
        s = score[i] + score[j] + score[k]
        if (s > best) {
          best=s
          bi=i; bj=j; bk=k
        }
      }
    }
  }
  if (best > -999999) {
    print subnet[bi] "\t" az[bi] "\t" freeips[bi] "\t" route[bi] "\t" name[bi]
    print subnet[bj] "\t" az[bj] "\t" freeips[bj] "\t" route[bj] "\t" name[bj]
    print subnet[bk] "\t" az[bk] "\t" freeips[bk] "\t" route[bk] "\t" name[bk]
  }
}' "$SUBNET_TABLE" > "$BEST_TRIO_FILE"

echo "============================================================"
echo "RECOMMENDED SUBNET PAIR"
echo "============================================================"
if [[ -s "$BEST_PAIR_FILE" ]]; then
  cat "$BEST_PAIR_FILE" | awk -F'\t' '{printf "Subnet=%s  AZ=%s  FreeIPs=%s  Route=%s  Name=%s\n",$1,$2,$3,$4,$5}'
else
  echo "No valid pair found with at least 6 free IPs in different AZs."
fi
echo

echo "============================================================"
echo "RECOMMENDED SUBNET TRIO"
echo "============================================================"
if [[ -s "$BEST_TRIO_FILE" ]]; then
  cat "$BEST_TRIO_FILE" | awk -F'\t' '{printf "Subnet=%s  AZ=%s  FreeIPs=%s  Route=%s  Name=%s\n",$1,$2,$3,$4,$5}'
else
  echo "No valid 3-AZ trio found."
fi
echo

# -----------------------------
# SG inventory
# -----------------------------
echo "============================================================"
echo "SECURITY GROUPS IN VPC"
echo "============================================================"
jq -r '
  .SecurityGroups[]
  | [
      .GroupId,
      .GroupName,
      .Description,
      ((.IpPermissions // []) | length | tostring),
      ((.IpPermissionsEgress // []) | length | tostring)
    ]
  | @tsv
' "$WORKDIR/security_groups.json" | \
awk -F'\t' 'BEGIN {
  printf "%-22s %-28s %-8s %-8s %s\n","GroupId","Name","Ingress","Egress","Description"
}
{
  printf "%-22s %-28s %-8s %-8s %s\n",$1,$2,$4,$5,$3
}'
echo

echo "Recommendation: create a dedicated cluster control-plane security group rather than reusing a broad shared SG."
echo

# -----------------------------
# Select subnets for command
# Prefer trio if present, else pair
# -----------------------------
SELECTED_SUBNETS=""
if [[ -s "$BEST_TRIO_FILE" ]]; then
  SELECTED_SUBNETS=$(awk -F'\t' '{print $1}' "$BEST_TRIO_FILE" | paste -sd, -)
elif [[ -s "$BEST_PAIR_FILE" ]]; then
  SELECTED_SUBNETS=$(awk -F'\t' '{print $1}' "$BEST_PAIR_FILE" | paste -sd, -)
fi

# -----------------------------
# Suggested SG create command
# -----------------------------
echo "============================================================"
echo "SUGGESTED SECURITY GROUP CREATION"
echo "============================================================"
cat <<EOF
aws ec2 create-security-group \
  --region $AWS_REGION \
  --vpc-id $VPC_ID \
  --group-name ${CLUSTER_NAME}-eks-control-plane-sg \
  --description "Dedicated EKS control plane security group for $CLUSTER_NAME"
EOF
echo

echo "After creating it, capture the SG ID, for example:"
echo 'CLUSTER_SG_ID=$(aws ec2 describe-security-groups --region '"$AWS_REGION"' --filters "Name=vpc-id,Values='"$VPC_ID"'" "Name=group-name,Values='"${CLUSTER_NAME}"'-eks-control-plane-sg" --query "SecurityGroups[0].GroupId" --output text)'
echo

# -----------------------------
# Final EKS create-cluster command
# -----------------------------
echo "============================================================"
echo "READY-TO-COPY EKS CREATE COMMAND"
echo "============================================================"

if [[ -z "$SELECTED_SUBNETS" ]]; then
  echo "Could not build create-cluster command because no valid subnet pair was found."
  exit 0
fi

if [[ -n "$K8S_VERSION" ]]; then
  VERSION_ARG="  --version $K8S_VERSION \\"
else
  VERSION_ARG=""
fi

cat <<EOF
# Replace sg-xxxxxxxxxxxxxxxxx with the dedicated control-plane SG you create
aws eks create-cluster \
  --region $AWS_REGION \
  --name $CLUSTER_NAME \
  --role-arn $CLUSTER_ROLE_ARN \
${VERSION_ARG}
  --resources-vpc-config subnetIds=$SELECTED_SUBNETS,securityGroupIds=sg-xxxxxxxxxxxxxxxxx,endpointPublicAccess=$ENDPOINT_PUBLIC_ACCESS,endpointPrivateAccess=$ENDPOINT_PRIVATE_ACCESS
EOF
echo

echo "============================================================"
echo "ALTERNATE: JSON INPUT FOR EKS CREATE"
echo "============================================================"

cat > "$WORKDIR/create-cluster.json" <<EOF
{
  "name": "$CLUSTER_NAME",
  "roleArn": "$CLUSTER_ROLE_ARN",
  "resourcesVpcConfig": {
    "subnetIds": [
$(echo "$SELECTED_SUBNETS" | awk -F',' '{for(i=1;i<=NF;i++) printf "      \"%s\"%s\n",$i,(i<NF?",":"")}')
    ],
    "securityGroupIds": [
      "sg-xxxxxxxxxxxxxxxxx"
    ],
    "endpointPublicAccess": $ENDPOINT_PUBLIC_ACCESS,
    "endpointPrivateAccess": $ENDPOINT_PRIVATE_ACCESS
  }$( [[ -n "$K8S_VERSION" ]] && printf ',\n  "version": "%s"\n' "$K8S_VERSION" || printf '\n')
}
EOF

echo "Saved JSON input file: $WORKDIR/create-cluster.json"
echo
echo "Run it like this after you set the SG ID:"
echo "aws eks create-cluster --region $AWS_REGION --cli-input-json file://$WORKDIR/create-cluster.json"
echo

echo "============================================================"
echo "NOTES"
echo "============================================================"
echo "- Use at least 2 subnets in different AZs."
echo "- Prefer private/NAT-backed subnets for worker-node environments."
echo "- Verify the selected subnets have enough free IP space for nodes and pods."
echo "- EKS cluster subnets should stay stable after cluster creation."
echo "- GovCloud ARNs should use arn:aws-us-gov:..."
echo
echo "Done. Artifacts saved in $WORKDIR"