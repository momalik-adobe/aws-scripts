#!/usr/bin/env bash
set -euo pipefail

# Usage: ./10_onboard_things.sh <plantId> <count> [--thing-prefix <prefix>] [--group <groupName>] [--policy <policyName>] [--start-from <index>]
# Requires: AWS CLI v2, jq, curl
# Notes:
# - Creates/uses a thing group for the plant, a shared IoT policy, and one cert per thing
# - Writes certs to: ./<plantId>/<n>/{certificate.pem.crt,private.pem.key,public.pem.key,AmazonRootCA1.pem,endpoint.txt,thingName.txt}
# - Names things by default as: "${PROJECT}-${plantId}-${ENV}-${n}" (falls back to "${plantId}-${n}" if PROJECT/ENV unset)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "${SCRIPT_DIR}/env.sh" ] && source "${SCRIPT_DIR}/env.sh" || true


: "${AWS_REGION:=${AWS_DEFAULT_REGION:-ap-south-1}}"
: "${PROJECT:=machine-monitoring}"
: "${ENV:=dev}"
: "${ACCOUNT_ID:=$(aws sts get-caller-identity --query Account --output text --region "${AWS_REGION}")}" || true

PROJECT_SAFE="${PROJECT//-/_}"
ENV_SAFE="${ENV//-/_}"

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required. Install with: brew install jq (macOS) or sudo apt-get install jq (Debian/Ubuntu)." >&2
  exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "Error: curl is required." >&2
  exit 1
fi

if [ $# -lt 2 ]; then
  echo "Usage: $0 <plantId> <count> [--thing-prefix <prefix>] [--group <groupName>] [--policy <policyName>] [--start-from <index>]" >&2
  exit 1
fi

PLANT_ID="$1"; shift
COUNT="$1"; shift
THING_PREFIX="${PROJECT}-${PLANT_ID}-${ENV}"
GROUP_NAME="${PROJECT_SAFE}_${PLANT_ID//-/_}_${ENV_SAFE}"
POLICY_NAME="${PROJECT_SAFE}_${PLANT_ID//-/_}_device_policy_${ENV_SAFE}"
MANUAL_START=""

while [ $# -gt 0 ]; do
  case "$1" in
    --thing-prefix) THING_PREFIX="$2"; shift 2;;
    --group) GROUP_NAME="$2"; shift 2;;
    --policy) POLICY_NAME="$2"; shift 2;;
    --start-from) MANUAL_START="$2"; shift 2;;
    *) echo "Unknown arg: $1" >&2; exit 1;;
  esac
done

ensure_group() {
  local name="$1"
  if ! aws iot describe-thing-group --thing-group-name "$name" --region "${AWS_REGION}" >/dev/null 2>&1; then
    aws iot create-thing-group --thing-group-name "$name" --region "${AWS_REGION}" >/dev/null
  fi
}

ensure_policy() {
  local name="$1"
  if ! aws iot get-policy --policy-name "$name" --region "${AWS_REGION}" >/dev/null 2>&1; then
    local doc
    doc=$(cat <<POLICY
{
  "Version":"2012-10-17",
  "Statement":[
    {"Effect":"Allow","Action":["iot:Connect"],"Resource":"*"},
    {"Effect":"Allow","Action":["iot:Publish","iot:Receive"],"Resource":"arn:aws:iot:${AWS_REGION}:${ACCOUNT_ID}:topic/*"},
    {"Effect":"Allow","Action":["iot:Subscribe"],"Resource":"arn:aws:iot:${AWS_REGION}:${ACCOUNT_ID}:topicfilter/*"}
  ]
}
POLICY
)
    aws iot create-policy --policy-name "$name" --policy-document "$doc" --region "${AWS_REGION}" >/dev/null
  fi
}

get_endpoint() {
  aws iot describe-endpoint --endpoint-type iot:Data-ATS --query endpointAddress --output text --region "${AWS_REGION}"
}

download_root_ca() {
  local target="$1"
  if [ ! -f "$target" ]; then
    curl -fsSL "https://www.amazontrust.com/repository/AmazonRootCA1.pem" -o "$target"
  fi
}

create_thing_if_needed() {
  local thing_name="$1"
  if ! aws iot describe-thing --thing-name "$thing_name" --region "${AWS_REGION}" >/dev/null 2>&1; then
    aws iot create-thing --thing-name "$thing_name" \
      --attribute-payload "attributes={plantId=${PLANT_ID},machineIndex=$(echo "$thing_name" | grep -oE '[0-9]+$' || echo 0)}" \
      --region "${AWS_REGION}" >/dev/null
  fi
}

onboard_one() {
  local idx="$1"
  local thing_name="${THING_PREFIX}-${idx}"
  local out_dir="${PLANT_ID}/${idx}"
  mkdir -p "$out_dir"

  create_thing_if_needed "$thing_name"

  # Create cert/keys (set active) and save files
  local json tmp
  tmp=$(mktemp)
  aws iot create-keys-and-certificate --set-as-active --output json --region "${AWS_REGION}" > "$tmp"
  local cert_arn cert_id cert_pem pub_key priv_key
  cert_arn=$(jq -r '.certificateArn' "$tmp")
  cert_id=$(jq -r '.certificateId' "$tmp")
  jq -r '.certificatePem' "$tmp" > "${out_dir}/certificate.pem.crt"
  jq -r '.keyPair.PublicKey' "$tmp" > "${out_dir}/public.pem.key"
  jq -r '.keyPair.PrivateKey' "$tmp" > "${out_dir}/private.pem.key"
  rm -f "$tmp"

  # Attach policy and thing principal
  aws iot attach-policy --policy-name "${POLICY_NAME}" --target "$cert_arn" --region "${AWS_REGION}" >/dev/null
  aws iot attach-thing-principal --thing-name "$thing_name" --principal "$cert_arn" --region "${AWS_REGION}" >/dev/null
  aws iot add-thing-to-thing-group --thing-group-name "${GROUP_NAME}" --thing-name "$thing_name" --region "${AWS_REGION}" >/dev/null

  # Endpoint and Root CA
  local endpoint
  endpoint=$(get_endpoint)
  echo "$endpoint" > "${out_dir}/endpoint.txt"
  echo "$thing_name" > "${out_dir}/thingName.txt"
  download_root_ca "${out_dir}/AmazonRootCA1.pem"

  echo "Onboarded: ${thing_name}  →  ${out_dir}  (cert: ${cert_id})"
}

get_next_available_index() {
  local max_index=0
  local existing_things
  
  # Get all things in the group
  existing_things=$(aws iot list-things-in-thing-group --thing-group-name "${GROUP_NAME}" --query 'things' --output text --region "${AWS_REGION}" 2>/dev/null || echo "")
  
  # Extract indices from thing names and find the maximum
  if [ -n "$existing_things" ]; then
    for thing in $existing_things; do
      if [[ "$thing" =~ ${THING_PREFIX}-([0-9]+)$ ]]; then
        local idx="${BASH_REMATCH[1]}"
        if [ "$idx" -gt "$max_index" ]; then
          max_index="$idx"
        fi
      fi
    done
  fi
  
  echo $((max_index + 1))
}

main() {
  ensure_group "${GROUP_NAME}"
  ensure_policy "${POLICY_NAME}"
  
  local start_index
  if [ -n "$MANUAL_START" ]; then
    start_index="$MANUAL_START"
    echo "Using manual start index: ${start_index}"
  else
    start_index=$(get_next_available_index)
    echo "Auto-detected start index: ${start_index}"
  fi
  
  local end_index=$((start_index + COUNT - 1))
  
  echo "Onboarding ${COUNT} devices from index ${start_index} to ${end_index}"
  
  for ((i=start_index; i<=end_index; i++)); do
    onboard_one "$i"
  done
}

main "$@"
