#!/usr/bin/env bash
set -euo pipefail
source ./env.sh

ensure_iot_rule() {
  local NAME="$1" PAYLOAD="$2"
  if ! aws iot create-topic-rule --rule-name "${NAME}" --topic-rule-payload "${PAYLOAD}" --region "${AWS_REGION}" >/dev/null 2>&1; then
    aws iot replace-topic-rule --rule-name "${NAME}" --topic-rule-payload "${PAYLOAD}" --region "${AWS_REGION}"
  fi
}

RT_PAYLOAD="{
  \"sql\": \"SELECT PacketID as packetId, MACID as macId, SlaveName as slaveName, SlaveID as slaveId, SlaveData.Total_Kw as kw, SlaveData.Total_KVAr as kvar, SlaveData.Total_kVA as kva, topic(1) as plantId, topic(3) as machineId, timestamp() as receivedAt FROM '${IOT_TOPIC_FILTER}'\",
  \"actions\": [ { \"lambda\": { \"functionArn\": \"arn:aws:lambda:${AWS_REGION}:${ACCOUNT_ID}:function:${ENRICH_FN}\" } } ],
  \"ruleDisabled\": false
}"

FH_PAYLOAD="{
  \"sql\": \"SELECT PacketID as packetId, MACID as macId, SlaveName as slaveName, SlaveID as slaveId, SlaveData.Total_Kw as kw, SlaveData.Total_KVAr as kvar, SlaveData.Total_kVA as kva, topic(1) as plantId, topic(3) as machineId, timestamp() as receivedAt FROM '${IOT_TOPIC_FILTER}'\",
  \"actions\": [ { \"firehose\": { \"roleArn\": \"arn:aws:iam::${ACCOUNT_ID}:role/${IOT_ROLE_NAME}\", \"deliveryStreamName\": \"${FIREHOSE}\", \"separator\": \"\\n\" } } ],
  \"ruleDisabled\": false
}"

ensure_iot_rule "${RT_RULE}" "${RT_PAYLOAD}"
ensure_iot_rule "${FH_RULE}" "${FH_PAYLOAD}"

aws lambda add-permission --function-name "${ENRICH_FN}" \
  --statement-id "${PROJECT}-iot-$(date +%s)" \
  --action "lambda:InvokeFunction" \
  --principal iot.amazonaws.com \
  --source-arn "arn:aws:iot:${AWS_REGION}:${ACCOUNT_ID}:rule/${RT_RULE}" \
  --region "${AWS_REGION}" >/dev/null 2>&1 || true

echo "IoT rules ready: ${RT_RULE}, ${FH_RULE}"
