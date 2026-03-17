#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   export AWS_REGION=us-gov-west-1
#   export VPC_ID=vpc-xxxxxxxxxxxxxxxxx
#   bash phase1-eks-assessment.sh

: "${AWS_REGION:?Set AWS_REGION}"
: "${VPC_ID:?Set VPC_ID}"

OUTDIR="phase1-eks-assessment-${VPC_ID}-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUTDIR/raw"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1"
    exit 1
  }
}

need aws
need jq

save_json() {
  local name="$1"
  shift
  echo "Collecting $name ..."
  aws --region "$AWS_REGION" "$@" > "$OUTDIR/raw/${name}.json"
}

echo "Region : $AWS_REGION"
echo "VPC    : $VPC_ID"
echo "Outdir : $OUTDIR"
echo

# Core inventory
save_json vpc ec2 describe-vpcs --vpc-ids "$VPC_ID"
save_json subnets ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID"
save_json route_tables ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID"
save_json security_groups ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID"
save_json nacls ec2 describe-network-acls --filters "Name=vpc-id,Values=$VPC_ID"
save_json igws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID"
save_json nat_gateways ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC_ID"
save_json vpc_endpoints ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$VPC_ID"
save_json tgw_attachments ec2 describe-transit-gateway-attachments --filters "Name=resource-id,Values=$VPC_ID"
save_json instances ec2 describe-instances --filters "Name=vpc-id,Values=$VPC_ID" "Name=instance-state-name,Values=pending,running,stopping,stopped"

DNS_SUPPORT=$(aws --region "$AWS_REGION" ec2 describe-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --attribute enableDnsSupport \
  --query 'EnableDnsSupport.Value' \
  --output text)

DNS_HOSTNAMES=$(aws --region "$AWS_REGION" ec2 describe-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --attribute enableDnsHostnames \
  --query 'EnableDnsHostnames.Value' \
  --output text)

REPORT="$OUTDIR/phase1-summary.txt"
CSV="$OUTDIR/subnet-analysis.csv"

echo "subnet_id,name,az,cidr,available_ips,map_public_ip,route_table,default_route_type,default_route_target,eks_minimum,eks_preferred" > "$CSV"

get_main_rtb() {
  jq -r '
    .RouteTables[]
    | select(any(.Associations[]?; .Main == true))
    | .RouteTableId
  ' "$OUTDIR/raw/route_tables.json" | head -n1
}

get_rtb_for_subnet() {
  local subnet_id="$1"

  local explicit
  explicit=$(jq -r --arg subnet "$subnet_id" '
    .RouteTables[]
    | select(any(.Associations[]?; .SubnetId == $subnet))
    | .RouteTableId
  ' "$OUTDIR/raw/route_tables.json" | head -n1)

  if [[ -n "${explicit:-}" ]]; then
    echo "$explicit"
  else
    get_main_rtb
  fi
}

classify_default_route() {
  local rtb_id="$1"

  jq -r --arg rtb "$rtb_id" '
    .RouteTables[]
    | select(.RouteTableId == $rtb)
    | .Routes[]
    | select(.DestinationCidrBlock == "0.0.0.0/0")
    | if .GatewayId then
        if (.GatewayId | startswith("igw-")) then "igw," + .GatewayId else "gateway," + .GatewayId end
      elif .NatGatewayId then "nat," + .NatGatewayId
      elif .TransitGatewayId then "tgw," + .TransitGatewayId
      elif .VpcPeeringConnectionId then "pcx," + .VpcPeeringConnectionId
      else "other,unknown"
      end
  ' "$OUTDIR/raw/route_tables.json" | head -n1
}

{
  echo "============================================================"
  echo "PHASE 1 - EKS READINESS ASSESSMENT"
  echo "============================================================"
  echo "Region: $AWS_REGION"
  echo "VPC   : $VPC_ID"
  echo

  echo "1) VPC BASICS"
  echo "------------------------------------------------------------"
  jq -r '
    .Vpcs[0] |
    "CIDR: " + .CidrBlock + "\n" +
    "State: " + .State + "\n" +
    "DHCP Options: " + .DhcpOptionsId + "\n" +
    "Tags: " + (((.Tags // []) | map("\(.Key)=\(.Value)")) | join(", "))
  ' "$OUTDIR/raw/vpc.json"
  echo "enableDnsSupport   : $DNS_SUPPORT"
  echo "enableDnsHostnames : $DNS_HOSTNAMES"
  echo

  echo "2) SUBNET ANALYSIS"
  echo "------------------------------------------------------------"
} > "$REPORT"

jq -r '
  .Subnets[]
  | [
      .SubnetId,
      ((.Tags // []) | map(select(.Key=="Name") | .Value) | first // "-"),
      .AvailabilityZone,
      .CidrBlock,
      (.AvailableIpAddressCount|tostring),
      (.MapPublicIpOnLaunch|tostring)
    ]
  | @tsv
' "$OUTDIR/raw/subnets.json" | while IFS=$'\t' read -r SUBNET_ID NAME AZ CIDR FREEIPS MAPPUBLIC; do
  RTB=$(get_rtb_for_subnet "$SUBNET_ID")
  ROUTE_INFO=$(classify_default_route "$RTB" || true)

  ROUTE_TYPE="none"
  ROUTE_TARGET="none"
  if [[ -n "${ROUTE_INFO:-}" ]]; then
    ROUTE_TYPE="${ROUTE_INFO%%,*}"
    ROUTE_TARGET="${ROUTE_INFO#*,}"
  fi

  EKS_MINIMUM="NO"
  EKS_PREFERRED="NO"
  if [[ "$FREEIPS" =~ ^[0-9]+$ ]]; then
    if (( FREEIPS >= 6 )); then EKS_MINIMUM="YES"; fi
    if (( FREEIPS >= 16 )); then EKS_PREFERRED="YES"; fi
  fi

  echo "$SUBNET_ID,$NAME,$AZ,$CIDR,$FREEIPS,$MAPPUBLIC,$RTB,$ROUTE_TYPE,$ROUTE_TARGET,$EKS_MINIMUM,$EKS_PREFERRED" >> "$CSV"

  {
    echo "Subnet: $SUBNET_ID"
    echo "  Name              : $NAME"
    echo "  AZ                : $AZ"
    echo "  CIDR              : $CIDR"
    echo "  Available IPs     : $FREEIPS"
    echo "  MapPublicIpLaunch : $MAPPUBLIC"
    echo "  Route Table       : $RTB"
    echo "  Default Route     : $ROUTE_TYPE -> $ROUTE_TARGET"
    echo "  EKS Minimum (6+)  : $EKS_MINIMUM"
    echo "  EKS Preferred(16+): $EKS_PREFERRED"
    echo
  } >> "$REPORT"
done

AZ_COUNT=$(jq -r '.Subnets[].AvailabilityZone' "$OUTDIR/raw/subnets.json" | sort -u | wc -l | xargs)
TOTAL_SUBNETS=$(jq -r '.Subnets | length' "$OUTDIR/raw/subnets.json")
MIN_OK_COUNT=$(awk -F',' 'NR>1 && $10=="YES" {c++} END {print c+0}' "$CSV")
PREF_OK_COUNT=$(awk -F',' 'NR>1 && $11=="YES" {c++} END {print c+0}' "$CSV")
PRIVATE_NAT_COUNT=$(awk -F',' 'NR>1 && $8=="nat" {c++} END {print c+0}' "$CSV")
PUBLIC_IGW_COUNT=$(awk -F',' 'NR>1 && $8=="igw" {c++} END {print c+0}' "$CSV")

{
  echo "3) HIGH-LEVEL READINESS"
  echo "------------------------------------------------------------"
  echo "Total subnets                  : $TOTAL_SUBNETS"
  echo "Unique AZs                     : $AZ_COUNT"
  echo "Subnets meeting EKS minimum    : $MIN_OK_COUNT"
  echo "Subnets meeting EKS preferred  : $PREF_OK_COUNT"
  echo "Subnets with NAT default route : $PRIVATE_NAT_COUNT"
  echo "Subnets with IGW default route : $PUBLIC_IGW_COUNT"
  echo

  echo "4) SECURITY INVENTORY"
  echo "------------------------------------------------------------"
  echo "Security Groups:"
  jq -r '.SecurityGroups[] | "  " + .GroupId + " | " + .GroupName + " | " + .Description' "$OUTDIR/raw/security_groups.json"
  echo
  echo "Network ACLs:"
  jq -r '.NetworkAcls[] | "  " + .NetworkAclId + " | default=" + (.IsDefault|tostring) + " | associations=" + (((.Associations // []) | map(.SubnetId)) | join(";"))' "$OUTDIR/raw/nacls.json"
  echo
  echo "Internet Gateways:"
  jq -r 'if (.InternetGateways|length)==0 then "  none" else .InternetGateways[] | "  " + .InternetGatewayId end' "$OUTDIR/raw/igws.json"
  echo
  echo "NAT Gateways:"
  jq -r 'if (.NatGateways|length)==0 then "  none" else .NatGateways[] | "  " + .NatGatewayId + " | subnet=" + .SubnetId + " | state=" + .State end' "$OUTDIR/raw/nat_gateways.json"
  echo
  echo "VPC Endpoints:"
  jq -r 'if (.VpcEndpoints|length)==0 then "  none" else .VpcEndpoints[] | "  " + .VpcEndpointId + " | " + .ServiceName + " | " + .VpcEndpointType + " | " + .State end' "$OUTDIR/raw/vpc_endpoints.json"
  echo
  echo "Transit Gateway Attachments:"
  jq -r 'if (.TransitGatewayAttachments|length)==0 then "  none" else .TransitGatewayAttachments[] | "  " + .TransitGatewayAttachmentId + " | " + .State end' "$OUTDIR/raw/tgw_attachments.json"
  echo

  echo "5) EXISTING EC2 FOOTPRINT"
  echo "------------------------------------------------------------"
  jq -r '
    [
      .Reservations[].Instances[]
      | "  " + .InstanceId + " | subnet=" + .SubnetId + " | az=" + .Placement.AvailabilityZone + " | privateIp=" + (.PrivateIpAddress // "-") + " | name=" + (((.Tags // []) | map(select(.Key=="Name") | .Value) | first) // "-")
    ] | if length==0 then "  none" else .[] end
  ' "$OUTDIR/raw/instances.json"
  echo

  echo "6) PHASE 1 DECISION HINTS"
  echo "------------------------------------------------------------"

  if [[ "$DNS_SUPPORT" != "True" || "$DNS_HOSTNAMES" != "True" ]]; then
    echo "- FAIL: DNS settings are not EKS-friendly yet."
  else
    echo "- PASS: DNS settings look usable for EKS."
  fi

  if (( AZ_COUNT < 2 )); then
    echo "- FAIL: fewer than 2 AZs available."
  else
    echo "- PASS: at least 2 AZs available."
  fi

  if (( MIN_OK_COUNT < 2 )); then
    echo "- FAIL: fewer than 2 subnets have the minimum free IPs."
  else
    echo "- PASS: at least 2 subnets meet minimum free IPs."
  fi

  if (( PRIVATE_NAT_COUNT >= 2 )); then
    echo "- GOOD: there are private/NAT-routed subnet candidates."
  elif (( PUBLIC_IGW_COUNT >= 2 )); then
    echo "- CAUTION: public-routed subnet candidates exist; private-first design may need routing changes."
  else
    echo "- CAUTION: no obvious NAT or IGW pattern; inspect custom routing/TGW design closely."
  fi

  if jq -e '.VpcEndpoints | length > 0' "$OUTDIR/raw/vpc_endpoints.json" >/dev/null; then
    echo "- INFO: VPC endpoints already exist; review whether they support a private EKS design."
  else
    echo "- INFO: no VPC endpoints found; fully private EKS will likely need endpoint work."
  fi

  echo
  echo "Files:"
  echo "- Summary: $REPORT"
  echo "- Subnet CSV: $CSV"
  echo "- Raw JSON:   $OUTDIR/raw/"
} >> "$REPORT"

cat "$REPORT"
echo
echo "Artifacts saved under: $OUTDIR"