#!/usr/bin/env bash
set -euo pipefail
source ./env.sh

ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${LAMBDA_ROLE_NAME}"
KINESIS_ARN="arn:aws:kinesis:${AWS_REGION}:${ACCOUNT_ID}:stream/${KINESIS_STREAM}"

wait_updated() { aws lambda wait function-updated --function-name "$1" --region "${AWS_REGION}"; }

create_or_update_lambda() {
  local NAME="$1" ENV_VARS="$2" SRC="$3"
  local DIR="/tmp/${NAME}"; mkdir -p "${DIR}"
  echo "${SRC}" > "${DIR}/index.py"; (cd "${DIR}" && zip -qr "/tmp/${NAME}.zip" .)
  if ! aws lambda get-function --function-name "${NAME}" --region "${AWS_REGION}" >/dev/null 2>&1; then
    aws lambda create-function --function-name "${NAME}" --runtime python3.11 --handler index.lambda_handler --role "${ROLE_ARN}" --timeout 60 --environment "Variables={${ENV_VARS}}" --zip-file fileb:///tmp/${NAME}.zip --region "${AWS_REGION}" >/dev/null
    wait_updated "${NAME}"
  else
    aws lambda update-function-code --function-name "${NAME}" --zip-file fileb:///tmp/${NAME}.zip --region "${AWS_REGION}" >/dev/null
    wait_updated "${NAME}"
    for i in 1 2 3 4; do
      if aws lambda update-function-configuration --function-name "${NAME}" --environment "Variables={${ENV_VARS}}" --region "${AWS_REGION}" >/dev/null; then break; fi
      sleep $((2**i))
    done
    wait_updated "${NAME}"
  fi
}

ENRICH_SRC='import os, json, time, boto3
from decimal import Decimal
kinesis = boto3.client("kinesis"); dynamodb = boto3.resource("dynamodb")
KINESIS_STREAM_NAME = os.environ["KINESIS_STREAM_NAME"]; DEVICE_REGISTRY_TABLE = os.environ["DEVICE_REGISTRY_TABLE"]
registry_tbl = dynamodb.Table(DEVICE_REGISTRY_TABLE)
def lambda_handler(event, context):
    record = event if isinstance(event, dict) else json.loads(event)
    plant_id = record.get("plantId"); machine_id = record.get("machineId") or record.get("slaveName"); mac_id = record.get("macId")
    util_threshold = 0.3
    if mac_id:
        item = registry_tbl.get_item(Key={"machineId": mac_id}).get("Item", {}) or {}
        util_threshold = float(item.get("utilThresholdKw", util_threshold))
        plant_id = plant_id or item.get("plantId"); machine_id = machine_id or item.get("machineId")
    def _num(v):
        try:
            if v is None: return None
            return float(v)
        except:
            return None
    kw = _num(record.get("kw")); kva = _num(record.get("kva"))
    pf = round(kw / kva, 4) if (kw is not None and kva and kva > 0) else None
    utilization = 1 if (kw is not None and kw >= util_threshold) else 0
    enriched = {**record, "powerFactor": pf, "utilization": utilization, "receivedAt": int(time.time()*1000)}
    part_key = f"{plant_id or \"unknown\"}#{machine_id or (mac_id or \"unknown\")}"
    kinesis.put_record(StreamName=KINESIS_STREAM_NAME, Data=json.dumps(enriched, default=lambda o: float(o) if isinstance(o, Decimal) else o), PartitionKey=part_key)
    return {"ok": True}
'

CONSUMER_SRC='import os, json, time, base64, zlib, boto3
from datetime import datetime, timedelta
dynamodb = boto3.resource("dynamodb"); hot_tbl = dynamodb.Table(os.environ["HOT_TABLE"])
NUM_BUCKETS = int(os.environ.get("PLANT_BUCKETS","8")); TTL_HOURS = int(os.environ.get("TTL_HOURS","48"))
def lambda_handler(event, context):
    with hot_tbl.batch_writer(overwrite_by_pkeys=["plantMachineId","timestamp"]) as batch:
        for rec in event.get("Records", []):
            payload = json.loads(base64.b64decode(rec["kinesis"]["data"]).decode("utf-8"))
            plant_id = payload.get("plantId") or "unknown"; machine_id = payload.get("machineId") or "unknown"
            ts = int(payload.get("receivedAt") or int(time.time()*1000))
            bucket = f"{plant_id}#{(zlib.crc32(machine_id.encode(\"utf-8\")) % NUM_BUCKETS)}"
            ttl = int((datetime.utcnow() + timedelta(hours=TTL_HOURS)).timestamp())
            def _num(v):
                try:
                    if v is None: return None
                    return float(v)
                except:
                    return None
            item = {"plantMachineId": f"{plant_id}#{machine_id}","timestamp": ts,"plantId": plant_id,"machineId": machine_id,
                    "macId": payload.get("macId"),"kw": _num(payload.get("kw")),"kvar": _num(payload.get("kvar")),"kva": _num(payload.get("kva")),
                    "powerFactor": _num(payload.get("powerFactor")),"utilization": _num(payload.get("utilization")),
                    "packetId": payload.get("packetId"),"slaveId": payload.get("slaveId"),"slaveName": payload.get("slaveName"),
                    "plantBucket": bucket,"ttl": ttl}
            batch.put_item(Item=item)
    return {"ok": True}
'

LATEST_SRC='import os, boto3, decimal
dynamodb = boto3.resource("dynamodb"); latest_tbl = dynamodb.Table(os.environ["LATEST_TABLE"])
def lambda_handler(event, context):
    for r in event.get("Records", []):
        if r.get("eventName") not in ("INSERT","MODIFY"): continue
        new = r["dynamodb"].get("NewImage") or {}
        def _s(a):
            if not a: return None
            return list(a.values())[0]
        def _n(a):
            if not a: return None
            v = list(a.values())[0]
            if isinstance(v, (int,float,decimal.Decimal)): return float(v)
            try: return float(v)
            except: return None
        plant_id = _s(new.get("plantId")); machine_id = _s(new.get("machineId")); ts = _n(new.get("timestamp"))
        if not plant_id or not machine_id or ts is None: continue
        item = {"plantMachineId": f"{plant_id}#{machine_id}","plantId": plant_id,"machineId": machine_id,"lastTimestamp": ts,
                "macId": _s(new.get("macId")), "kw": _n(new.get("kw")), "kvar": _n(new.get("kvar")), "kva": _n(new.get("kva")),
                "powerFactor": _n(new.get("powerFactor")), "utilization": _n(new.get("utilization"))}
        try:
            latest_tbl.put_item(Item=item, ConditionExpression="attribute_not_exists(lastTimestamp) OR :ts > lastTimestamp", ExpressionAttributeValues={":ts": ts})
        except Exception as e:
            if "ConditionalCheckFailedException" not in str(e): print("Put latest failed:", e)
    return {"ok": True}
'

create_or_update_lambda "${ENRICH_FN}" "KINESIS_STREAM_NAME=${KINESIS_STREAM},DEVICE_REGISTRY_TABLE=${DDB_REG}" "${ENRICH_SRC}"
create_or_update_lambda "${CONSUMER_FN}" "HOT_TABLE=${DDB_HOT},PLANT_BUCKETS=${PLANT_BUCKETS},TTL_HOURS=${HOT_TTL_HOURS}" "${CONSUMER_SRC}"
create_or_update_lambda "${LATEST_FN}" "LATEST_TABLE=${DDB_LATEST}" "${LATEST_SRC}"

# Kinesis → consumer mapping
if ! aws lambda list-event-source-mappings --function-name "${CONSUMER_FN}" --event-source-arn "${KINESIS_ARN}" --region "${AWS_REGION}" --query 'EventSourceMappings[0].UUID' --output text 2>/dev/null | grep -qv None; then
  aws lambda create-event-source-mapping --function-name "${CONSUMER_FN}" --event-source-arn "${KINESIS_ARN}" --batch-size 200 --maximum-batching-window-in-seconds 2 --starting-position LATEST --region "${AWS_REGION}" >/dev/null
fi

# DDB stream → latest mapping
STREAM_ARN="$(aws dynamodb describe-table --table-name "${DDB_HOT}" --query "Table.LatestStreamArn" --output text --region "${AWS_REGION}")"
if ! aws lambda list-event-source-mappings --function-name "${LATEST_FN}" --event-source-arn "${STREAM_ARN}" --region "${AWS_REGION}" --query 'EventSourceMappings[0].UUID' --output text 2>/dev/null | grep -qv None; then
  aws lambda create-event-source-mapping --function-name "${LATEST_FN}" --event-source-arn "${STREAM_ARN}" --batch-size 200 --maximum-batching-window-in-seconds 2 --starting-position LATEST --region "${AWS_REGION}" >/dev/null
fi

echo "Lambdas ready."
