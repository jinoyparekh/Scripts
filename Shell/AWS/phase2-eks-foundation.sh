#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Phase 2 - Private EKS network foundation for existing VPC (AWS GovCloud)
#
# What it creates:
# - New dedicated PRIVATE subnets in 2 or 3 AZs
# - One private route table for those subnets
# - S3 gateway endpoint
# - Interface endpoints for a fully-private EKS baseline (only if available)
# - Endpoint security group
# - Dedicated SG shells for EKS control plane and nodes
# - KMS key for logs
# - CloudWatch log groups with KMS + retention
# - VPC Flow Logs to CloudWatch Logs
#
# What it does NOT create:
# - EKS cluster
# - IAM roles for cluster/nodes/workloads
# - NAT / IGW routes
# - GitLab runners
#
# Assumptions:
# - Existing VPC already exists
# - You want PRIVATE-ONLY EKS subnets (no public IPs, no default internet route)
# - You will use EKS Pod Identity / private-first design in Phase 3
#
# Required env vars:
#   AWS_REGION=us-gov-west-1
#   VPC_ID=vpc-xxxxxxxxxxxxxxxxx
#   SUBNET_CIDRS=10.20.64.0/24,10.20.65.0/24,10.20.66.0/24
#
# Optional env vars:
#   NAME_PREFIX=gitlab-runners
#   CLUSTER_NAME=gitlab-runners-eks
#   FLOW_LOG_RETENTION_DAYS=3650
#   EKS_LOG_RETENTION_DAYS=3650
#
# Example:
#   export AWS_REGION=us-gov-west-1
#   export VPC_ID=vpc-0123456789abcdef0
#   export SUBNET_CIDRS=10.20.64.0/24,10.20.65.0/24,10.20.66.0/24
#   export NAME_PREFIX=gitlab-runners
#   export CLUSTER_NAME=gitlab-runners-eks
#   bash phase2-eks-foundation.sh
# -----------------------------------------------------------------------------

: "${AWS_REGION:?Set AWS_REGION}"
: "${VPC_ID:?Set VPC_ID}"
: "${SUBNET_CIDRS:?Set SUBNET_CIDRS as comma-separated CIDRs}"

NAME_PREFIX="${NAME_PREFIX:-gitlab-runners}"
CLUSTER_NAME="${CLUSTER_NAME:-${NAME_PREFIX}-eks}"
FLOW_LOG_RETENTION_DAYS="${FLOW_LOG_RETENTION_DAYS:-3650}"
EKS_LOG_RETENTION_DAYS="${EKS_LOG_RETENTION_DAYS:-3650}"

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1"; exit 1; }
}
need aws
need jq
need python3

AWS="aws --region ${AWS_REGION}"
OUTDIR="phase2-eks-foundation-${VPC_ID}-$(date +%Y%m%d-%H%M%S)"
mkdir -p "${OUTDIR}"

# ----------------------------
# Helpers
# ----------------------------
json_escape() {
  python3 - <<PY
import json,sys
print(json.dumps(sys.stdin.read()))
PY
}

get_account_id() {
  $AWS sts get-caller-identity --query 'Account' --output text
}

get_partition() {
  local arn
  arn="$($AWS sts get-caller-identity --query 'Arn' --output text)"
  if [[ "$arn" == arn:aws-us-gov:* ]]; then
    echo "aws-us-gov"
  else
    echo "aws"
  fi
}

tag_spec() {
  local type="$1"
  local name="$2"
  cat <<JSON
ResourceType=${type},Tags=[{Key=Name,Value=${name}},{Key=ManagedBy,Value=ChatGPT-Phase2},{Key=Environment,Value=prod},{Key=Workload,Value=${NAME_PREFIX}}]
JSON
}

exists_subnet_by_name() {
  local name="$1"
  $AWS ec2 describe-subnets \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=${name}" \
    --query 'Subnets[0].SubnetId' --output text 2>/dev/null || true
}

exists_route_table_by_name() {
  local name="$1"
  $AWS ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=${name}" \
    --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null || true
}

exists_sg_by_name() {
  local name="$1"
  $AWS ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=${name}" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true
}

exists_log_group() {
  local name="$1"
  $AWS logs describe-log-groups \
    --log-group-name-prefix "$name" \
    --query "logGroups[?logGroupName=='${name}'].logGroupName | [0]" \
    --output text 2>/dev/null || true
}

endpoint_exists() {
  local service_name="$1"
  $AWS ec2 describe-vpc-endpoints \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=service-name,Values=${service_name}" \
    --query 'VpcEndpoints[0].VpcEndpointId' --output text 2>/dev/null || true
}

service_supported() {
  local service_name="$1"
  local count
  count="$($AWS ec2 describe-vpc-endpoint-services \
    --query "length(ServiceDetails[?ServiceName=='${service_name}'])" \
    --output text 2>/dev/null || echo 0)"
  [[ "$count" != "0" ]]
}

ensure_log_group() {
  local log_group="$1"
  local kms_key_arn="$2"
  local retention_days="$3"

  if [[ "$(exists_log_group "$log_group")" == "None" || "$(exists_log_group "$log_group")" == "null" || -z "$(exists_log_group "$log_group")" ]]; then
    $AWS logs create-log-group --log-group-name "$log_group" --kms-key-id "$kms_key_arn"
  fi
  $AWS logs put-retention-policy --log-group-name "$log_group" --retention-in-days "$retention_days"
}

ensure_sg_rule_ingress_cidr_443() {
  local sg_id="$1"
  local cidr="$2"
  $AWS ec2 authorize-security-group-ingress \
    --group-id "$sg_id" \
    --ip-permissions "IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=${cidr},Description=HTTPS from VPC}]" >/dev/null 2>&1 || true
}

ensure_sg_rule_ingress_self_all() {
  local sg_id="$1"
  $AWS ec2 authorize-security-group-ingress \
    --group-id "$sg_id" \
    --ip-permissions "IpProtocol=-1,UserIdGroupPairs=[{GroupId=${sg_id},Description=Self all}]" >/dev/null 2>&1 || true
}

ensure_sg_rule_egress_vpc_all() {
  local sg_id="$1"
  local cidr="$2"
  $AWS ec2 authorize-security-group-egress \
    --group-id "$sg_id" \
    --ip-permissions "IpProtocol=-1,IpRanges=[{CidrIp=${cidr},Description=All to VPC CIDR}]" >/dev/null 2>&1 || true
}

ensure_sg_rule_ingress_from_sg_443() {
  local target_sg="$1"
  local source_sg="$2"
  $AWS ec2 authorize-security-group-ingress \
    --group-id "$target_sg" \
    --ip-permissions "IpProtocol=tcp,FromPort=443,ToPort=443,UserIdGroupPairs=[{GroupId=${source_sg},Description=443 from source SG}]" >/dev/null 2>&1 || true
}

# ----------------------------
# Basic discovery
# ----------------------------
ACCOUNT_ID="$(get_account_id)"
PARTITION="$(get_partition)"
VPC_CIDR="$($AWS ec2 describe-vpcs --vpc-ids "$VPC_ID" --query 'Vpcs[0].CidrBlock' --output text)"
AZS="$($AWS ec2 describe-availability-zones --filters Name=state,Values=available --query 'AvailabilityZones[].ZoneName' --output text)"
IFS=',' read -r -a CIDR_ARRAY <<< "$SUBNET_CIDRS"
read -r -a AZ_ARRAY <<< "$AZS"

SUBNET_COUNT="${#CIDR_ARRAY[@]}"
if (( SUBNET_COUNT < 2 )); then
  echo "Provide at least 2 subnet CIDRs in SUBNET_CIDRS."
  exit 1
fi

if (( ${#AZ_ARRAY[@]} < SUBNET_COUNT )); then
  echo "Not enough AZs available in region ${AWS_REGION} for ${SUBNET_COUNT} subnets."
  exit 1
fi

echo "Region         : $AWS_REGION"
echo "Account        : $ACCOUNT_ID"
echo "Partition      : $PARTITION"
echo "VPC            : $VPC_ID"
echo "VPC CIDR       : $VPC_CIDR"
echo "Subnet CIDRs   : $SUBNET_CIDRS"
echo "Cluster Name   : $CLUSTER_NAME"
echo "Output Dir     : $OUTDIR"
echo

# Validate CIDRs are inside VPC CIDR and do not overlap existing subnets
python3 - "$VPC_CIDR" "$SUBNET_CIDRS" <<'PY'
import ipaddress, sys
vpc = ipaddress.ip_network(sys.argv[1])
subs = [ipaddress.ip_network(x.strip()) for x in sys.argv[2].split(",") if x.strip()]
for s in subs:
    if not s.subnet_of(vpc):
        raise SystemExit(f"ERROR: {s} is not inside VPC CIDR {vpc}")
print("CIDR containment check passed.")
PY

$AWS ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}" > "${OUTDIR}/existing-subnets.json"

python3 - "${OUTDIR}/existing-subnets.json" "$SUBNET_CIDRS" <<'PY'
import ipaddress, json, sys
existing = json.load(open(sys.argv[1]))
new_subs = [ipaddress.ip_network(x.strip()) for x in sys.argv[2].split(",") if x.strip()]
existing_subs = [ipaddress.ip_network(s["CidrBlock"]) for s in existing["Subnets"]]
for n in new_subs:
    for e in existing_subs:
        if n.overlaps(e):
            raise SystemExit(f"ERROR: proposed subnet {n} overlaps existing subnet {e}")
print("CIDR overlap check passed.")
PY

# ----------------------------
# KMS key for logs
# ----------------------------
LOG_KMS_ALIAS="alias/${NAME_PREFIX}-foundation-logs"
LOGS_SERVICE_PRINCIPAL="logs.${AWS_REGION}.amazonaws.com"

LOG_KMS_KEY_ARN="$($AWS kms list-aliases --query "Aliases[?AliasName=='${LOG_KMS_ALIAS}'].TargetKeyId | [0]" --output text 2>/dev/null || true)"
if [[ -z "${LOG_KMS_KEY_ARN}" || "${LOG_KMS_KEY_ARN}" == "None" || "${LOG_KMS_KEY_ARN}" == "null" ]]; then
  cat > "${OUTDIR}/kms-policy.json" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EnableRootPermissions",
      "Effect": "Allow",
      "Principal": { "AWS": "arn:${PARTITION}:iam::${ACCOUNT_ID}:root" },
      "Action": "kms:*",
      "Resource": "*"
    },
    {
      "Sid": "AllowCloudWatchLogsUse",
      "Effect": "Allow",
      "Principal": { "Service": "${LOGS_SERVICE_PRINCIPAL}" },
      "Action": [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:ReEncrypt*",
        "kms:GenerateDataKey*",
        "kms:DescribeKey"
      ],
      "Resource": "*"
    }
  ]
}
JSON

  LOG_KMS_KEY_ARN="$($AWS kms create-key \
    --description "${NAME_PREFIX} foundation logs KMS key" \
    --policy file://"${OUTDIR}/kms-policy.json" \
    --query 'KeyMetadata.Arn' --output text)"

  $AWS kms create-alias --alias-name "${LOG_KMS_ALIAS}" --target-key-id "${LOG_KMS_KEY_ARN}"
else
  # list-aliases returned KeyId; convert to ARN
  LOG_KMS_KEY_ARN="$($AWS kms describe-key --key-id "$LOG_KMS_KEY_ARN" --query 'KeyMetadata.Arn' --output text)"
fi

# ----------------------------
# Log groups
# ----------------------------
FLOW_LOG_GROUP="/aws/vpc/${NAME_PREFIX}/flowlogs"
EKS_LOG_GROUP="/aws/eks/${CLUSTER_NAME}/cluster"

ensure_log_group "${FLOW_LOG_GROUP}" "${LOG_KMS_KEY_ARN}" "${FLOW_LOG_RETENTION_DAYS}"
ensure_log_group "${EKS_LOG_GROUP}" "${LOG_KMS_KEY_ARN}" "${EKS_LOG_RETENTION_DAYS}"

# ----------------------------
# IAM role for VPC Flow Logs
# ----------------------------
FLOW_ROLE_NAME="${NAME_PREFIX}-vpc-flowlogs-role"
FLOW_POLICY_NAME="${NAME_PREFIX}-vpc-flowlogs-policy"

FLOW_ROLE_ARN="$($AWS iam get-role --role-name "$FLOW_ROLE_NAME" --query 'Role.Arn' --output text 2>/dev/null || true)"
if [[ -z "${FLOW_ROLE_ARN}" || "${FLOW_ROLE_ARN}" == "None" || "${FLOW_ROLE_ARN}" == "null" ]]; then
  cat > "${OUTDIR}/flowlogs-trust.json" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowVPCFlowLogsAssumeRole",
      "Effect": "Allow",
      "Principal": { "Service": "vpc-flow-logs.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
JSON

  $AWS iam create-role \
    --role-name "$FLOW_ROLE_NAME" \
    --assume-role-policy-document file://"${OUTDIR}/flowlogs-trust.json" >/dev/null

  cat > "${OUTDIR}/flowlogs-permissions.json" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowFlowLogsToWriteCWL",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams",
        "logs:PutLogEvents"
      ],
      "Resource": "*"
    }
  ]
}
JSON

  $AWS iam put-role-policy \
    --role-name "$FLOW_ROLE_NAME" \
    --policy-name "$FLOW_POLICY_NAME" \
    --policy-document file://"${OUTDIR}/flowlogs-permissions.json" >/dev/null

  FLOW_ROLE_ARN="$($AWS iam get-role --role-name "$FLOW_ROLE_NAME" --query 'Role.Arn' --output text)"
fi

# ----------------------------
# Create private subnets
# ----------------------------
declare -a PRIVATE_SUBNET_IDS=()
declare -a PRIVATE_SUBNET_NAMES=()
declare -a AZ_USED=()

for i in "${!CIDR_ARRAY[@]}"; do
  CIDR="$(echo "${CIDR_ARRAY[$i]}" | xargs)"
  AZ="${AZ_ARRAY[$i]}"
  SUFFIX="$(tr '[:upper:]' '[:lower:]' <<< "${AZ##*-}")"
  NAME="${NAME_PREFIX}-private-${SUFFIX}"

  SUBNET_ID="$(exists_subnet_by_name "$NAME")"
  if [[ -z "${SUBNET_ID}" || "${SUBNET_ID}" == "None" || "${SUBNET_ID}" == "null" ]]; then
    SUBNET_ID="$($AWS ec2 create-subnet \
      --vpc-id "$VPC_ID" \
      --cidr-block "$CIDR" \
      --availability-zone "$AZ" \
      --tag-specifications "$(tag_spec subnet "$NAME")" \
      --query 'Subnet.SubnetId' --output text)"

    $AWS ec2 modify-subnet-attribute --subnet-id "$SUBNET_ID" --no-map-public-ip-on-launch
  fi

  # Tag for internal load balancers in EKS
  $AWS ec2 create-tags --resources "$SUBNET_ID" --tags \
    Key=kubernetes.io/role/internal-elb,Value=1 \
    Key=Tier,Value=private \
    Key=Purpose,Value=eks >/dev/null

  PRIVATE_SUBNET_IDS+=("$SUBNET_ID")
  PRIVATE_SUBNET_NAMES+=("$NAME")
  AZ_USED+=("$AZ")
done

# ----------------------------
# Route table
# ----------------------------
RT_NAME="${NAME_PREFIX}-private-rt"
RT_ID="$(exists_route_table_by_name "$RT_NAME")"
if [[ -z "${RT_ID}" || "${RT_ID}" == "None" || "${RT_ID}" == "null" ]]; then
  RT_ID="$($AWS ec2 create-route-table \
    --vpc-id "$VPC_ID" \
    --tag-specifications "$(tag_spec route-table "$RT_NAME")" \
    --query 'RouteTable.RouteTableId' --output text)"
fi

for subnet_id in "${PRIVATE_SUBNET_IDS[@]}"; do
  $AWS ec2 associate-route-table --subnet-id "$subnet_id" --route-table-id "$RT_ID" >/dev/null 2>&1 || true
done

# ----------------------------
# Security groups
# ----------------------------
EP_SG_NAME="${NAME_PREFIX}-vpce-sg"
NODE_SG_NAME="${NAME_PREFIX}-eks-nodes-sg"
CLUSTER_SG_NAME="${NAME_PREFIX}-eks-cluster-sg"

EP_SG_ID="$(exists_sg_by_name "$EP_SG_NAME")"
if [[ -z "${EP_SG_ID}" || "${EP_SG_ID}" == "None" || "${EP_SG_ID}" == "null" ]]; then
  EP_SG_ID="$($AWS ec2 create-security-group \
    --vpc-id "$VPC_ID" \
    --group-name "$EP_SG_NAME" \
    --description "Security group for VPC interface endpoints used by private EKS foundation" \
    --tag-specifications "$(tag_spec security-group "$EP_SG_NAME")" \
    --query 'GroupId' --output text)"
fi

NODE_SG_ID="$(exists_sg_by_name "$NODE_SG_NAME")"
if [[ -z "${NODE_SG_ID}" || "${NODE_SG_ID}" == "None" || "${NODE_SG_ID}" == "null" ]]; then
  NODE_SG_ID="$($AWS ec2 create-security-group \
    --vpc-id "$VPC_ID" \
    --group-name "$NODE_SG_NAME" \
    --description "Dedicated node security group shell for EKS managed node groups" \
    --tag-specifications "$(tag_spec security-group "$NODE_SG_NAME")" \
    --query 'GroupId' --output text)"
fi

CLUSTER_SG_ID="$(exists_sg_by_name "$CLUSTER_SG_NAME")"
if [[ -z "${CLUSTER_SG_ID}" || "${CLUSTER_SG_ID}" == "None" || "${CLUSTER_SG_ID}" == "null" ]]; then
  CLUSTER_SG_ID="$($AWS ec2 create-security-group \
    --vpc-id "$VPC_ID" \
    --group-name "$CLUSTER_SG_NAME" \
    --description "Dedicated control plane security group shell for EKS cluster" \
    --tag-specifications "$(tag_spec security-group "$CLUSTER_SG_NAME")" \
    --query 'GroupId' --output text)"
fi

# Endpoint SG: allow HTTPS from VPC CIDR
ensure_sg_rule_ingress_cidr_443 "$EP_SG_ID" "$VPC_CIDR"

# Node SG: self traffic, egress only to VPC CIDR
ensure_sg_rule_ingress_self_all "$NODE_SG_ID"
ensure_sg_rule_egress_vpc_all "$NODE_SG_ID" "$VPC_CIDR"

# Cluster SG: allow 443 from nodes
ensure_sg_rule_ingress_from_sg_443 "$CLUSTER_SG_ID" "$NODE_SG_ID"

# Tag SGs for future convenience
$AWS ec2 create-tags --resources "$NODE_SG_ID" "$CLUSTER_SG_ID" "$EP_SG_ID" \
  --tags Key=Purpose,Value=eks-foundation >/dev/null

# ----------------------------
# VPC endpoints
# ----------------------------
SERVICE_PREFIX="com.amazonaws.${AWS_REGION}"

# Always do S3 gateway if supported
S3_SERVICE="${SERVICE_PREFIX}.s3"
if service_supported "$S3_SERVICE"; then
  S3_EP_ID="$(endpoint_exists "$S3_SERVICE")"
  if [[ -z "${S3_EP_ID}" || "${S3_EP_ID}" == "None" || "${S3_EP_ID}" == "null" ]]; then
    $AWS ec2 create-vpc-endpoint \
      --vpc-id "$VPC_ID" \
      --vpc-endpoint-type Gateway \
      --service-name "$S3_SERVICE" \
      --route-table-ids "$RT_ID" \
      --tag-specifications "$(tag_spec vpc-endpoint "${NAME_PREFIX}-s3-gateway-endpoint")" >/dev/null
  fi
fi

create_interface_endpoint_if_supported() {
  local short_name="$1"
  local service_name="${SERVICE_PREFIX}.${short_name}"

  if ! service_supported "$service_name"; then
    echo "Skipping unsupported endpoint service: $service_name"
    return
  fi

  local ep_id
  ep_id="$(endpoint_exists "$service_name")"
  if [[ -n "${ep_id}" && "${ep_id}" != "None" && "${ep_id}" != "null" ]]; then
    echo "Endpoint already exists: ${service_name} -> ${ep_id}"
    return
  fi

  $AWS ec2 create-vpc-endpoint \
    --vpc-id "$VPC_ID" \
    --vpc-endpoint-type Interface \
    --service-name "$service_name" \
    --subnet-ids "${PRIVATE_SUBNET_IDS[@]}" \
    --security-group-ids "$EP_SG_ID" \
    --private-dns-enabled \
    --tag-specifications "$(tag_spec vpc-endpoint "${NAME_PREFIX}-${short_name}-endpoint")" >/dev/null

  echo "Created endpoint: ${service_name}"
}

# Core endpoints for private EKS baseline / private node operation
for svc in \
  ec2 \
  ecr.api \
  ecr.dkr \
  sts \
  logs \
  eks \
  eks-auth \
  ssm \
  ssmmessages \
  ec2messages \
  kms \
  autoscaling \
  elasticloadbalancing
do
  create_interface_endpoint_if_supported "$svc"
done

# ----------------------------
# VPC Flow Logs
# ----------------------------
FLOW_LOG_ID="$($AWS ec2 describe-flow-logs \
  --filter "Name=resource-id,Values=${VPC_ID}" \
  --query 'FlowLogs[0].FlowLogId' --output text 2>/dev/null || true)"

if [[ -z "${FLOW_LOG_ID}" || "${FLOW_LOG_ID}" == "None" || "${FLOW_LOG_ID}" == "null" ]]; then
  $AWS ec2 create-flow-logs \
    --resource-type VPC \
    --resource-ids "$VPC_ID" \
    --traffic-type ALL \
    --log-destination-type cloud-watch-logs \
    --log-group-name "$FLOW_LOG_GROUP" \
    --deliver-logs-permission-arn "$FLOW_ROLE_ARN" \
    --max-aggregation-interval 60 \
    --tag-specifications "$(tag_spec vpc-flow-log "${NAME_PREFIX}-vpc-flowlogs")" >/dev/null
fi

# ----------------------------
# Output summary
# ----------------------------
{
  echo "============================================================"
  echo "PHASE 2 COMPLETE - PRIVATE EKS FOUNDATION"
  echo "============================================================"
  echo "VPC ID                : $VPC_ID"
  echo "VPC CIDR              : $VPC_CIDR"
  echo "Cluster Name          : $CLUSTER_NAME"
  echo
  echo "Private Subnets:"
  for i in "${!PRIVATE_SUBNET_IDS[@]}"; do
    echo "  ${PRIVATE_SUBNET_IDS[$i]} | ${PRIVATE_SUBNET_NAMES[$i]} | ${AZ_USED[$i]} | ${CIDR_ARRAY[$i]}"
  done
  echo
  echo "Private Route Table   : $RT_ID"
  echo "Endpoint SG           : $EP_SG_ID"
  echo "Node SG               : $NODE_SG_ID"
  echo "Cluster SG            : $CLUSTER_SG_ID"
  echo "Flow Logs Role        : $FLOW_ROLE_ARN"
  echo "Logs KMS Key          : $LOG_KMS_KEY_ARN"
  echo "Flow Log Group        : $FLOW_LOG_GROUP"
  echo "EKS Log Group         : $EKS_LOG_GROUP"
  echo
  echo "VPC Endpoints:"
  $AWS ec2 describe-vpc-endpoints \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query 'VpcEndpoints[].{Id:VpcEndpointId,Service:ServiceName,Type:VpcEndpointType,State:State}' \
    --output table
  echo
  echo "Next phase inputs:"
  echo "  export CLUSTER_SUBNET_IDS=$(IFS=,; echo "${PRIVATE_SUBNET_IDS[*]}")"
  echo "  export CLUSTER_SECURITY_GROUP_ID=${CLUSTER_SG_ID}"
  echo "  export NODE_SECURITY_GROUP_ID=${NODE_SG_ID}"
  echo
  echo "Artifacts saved in: ${OUTDIR}"
} | tee "${OUTDIR}/summary.txt"