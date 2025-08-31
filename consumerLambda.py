import os
import json
import time
import base64
import zlib
from datetime import datetime, timedelta
import boto3
from decimal import Decimal

dynamodb = boto3.resource("dynamodb")

HOT_TABLE = os.environ["HOT_TABLE"]
NUM_BUCKETS = int(os.environ.get("PLANT_BUCKETS", "8"))
TTL_HOURS = int(os.environ.get("TTL_HOURS", "48"))

hot_table = dynamodb.Table(HOT_TABLE)


def _to_decimal(value):
    try:
        if value is None:
            return None
        if isinstance(value, Decimal):
            return value
        return Decimal(str(value))
    except Exception:
        return None


def lambda_handler(event, context):
    """
    Triggered by Kinesis Data Streams.
    Expects Kinesis records containing the enriched JSON produced by the enrichment Lambda.
    Writes time-series rows into DynamoDB hot table with TTL and plant-bucket GSI key.
    """
    ttl_epoch = int((datetime.utcnow() + timedelta(hours=TTL_HOURS)).timestamp())

    with hot_table.batch_writer(overwrite_by_pkeys=["plantMachineId", "timestamp"]) as batch:
        for record in event.get("Records", []):
            try:
                data_b64 = record["kinesis"]["data"]
                payload = json.loads(base64.b64decode(data_b64).decode("utf-8"), parse_float=Decimal)
            except Exception:
                continue

            plant_id = payload.get("plantId") or "unknown"
            machine_id = payload.get("machineId") or "unknown"
            received_at = payload.get("receivedAt")
            ts = int(received_at) if received_at is not None else int(time.time() * 1000)

            # Precompute strings to avoid f-string expression issues
            plant_machine = f"{plant_id}#{machine_id}"
            machine_bytes = machine_id.encode("utf-8")
            bucket_num = zlib.crc32(machine_bytes) % NUM_BUCKETS
            plant_bucket = f"{plant_id}#{bucket_num}"

            item = {
                "plantMachineId": plant_machine,
                "timestamp": ts,
                "plantId": plant_id,
                "machineId": machine_id,
                "macId": payload.get("macId"),
                "kw": _to_decimal(payload.get("kw")),
                "kvar": _to_decimal(payload.get("kvar")),
                "kva": _to_decimal(payload.get("kva")),
                "powerFactor": _to_decimal(payload.get("powerFactor")),
                "utilization": _to_decimal(payload.get("utilization")),
                "packetId": payload.get("packetId"),
                "slaveId": payload.get("slaveId"),
                "slaveName": payload.get("slaveName"),
                "plantBucket": plant_bucket,
                "ttl": ttl_epoch,
            }

            batch.put_item(Item=item)

    return {"ok": True}