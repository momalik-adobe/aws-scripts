import os
import json
import time
import base64
import zlib
from datetime import datetime, timedelta
import boto3
from decimal import Decimal

# DynamoDB resource/table
_dynamodb = boto3.resource("dynamodb")

HOT_TABLE = os.environ["HOT_TABLE"]
NUM_BUCKETS = int(os.environ.get("PLANT_BUCKETS", "8"))
TTL_HOURS = int(os.environ.get("TTL_HOURS", "48"))

hot_table = _dynamodb.Table(HOT_TABLE)


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
    Skips records where required numeric fields are missing or non-numeric.
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

            # Numeric validations: require kw to be present and numeric; optional others
            kw_dec = _to_decimal(payload.get("kw"))
            if kw_dec is None:
                # Skip packets without a valid kw value
                continue
            kvar_dec = _to_decimal(payload.get("kvar"))
            kva_dec = _to_decimal(payload.get("kva"))
           

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
                "kw": kw_dec,
                "kvar": kvar_dec,
                "kva": kva_dec,
                "packetId": payload.get("packetId"),
                "slaveId": payload.get("slaveId"),
                "slaveName": payload.get("slaveName"),
                "plantBucket": plant_bucket,
                "ttl": ttl_epoch,
            }

            batch.put_item(Item=item)

    return {"ok": True}