import os
import json
import time
import boto3

kinesis_client = boto3.client("kinesis")
_dynamodb = boto3.resource("dynamodb")

KINESIS_STREAM_NAME = os.environ["KINESIS_STREAM_NAME"]
DEVICE_REGISTRY_TABLE = os.environ["DEVICE_REGISTRY_TABLE"]
device_registry_table = _dynamodb.Table(DEVICE_REGISTRY_TABLE)


def _lookup_registry(mac_id: str) -> dict:
    if not mac_id:
        return {}
    try:
        resp = device_registry_table.get_item(Key={"machineId": mac_id})
        return resp.get("Item", {}) or {}
    except Exception:
        return {}


def lambda_handler(event, context):
    """
    Pass-through enrichment: keep only device-sent fields and IDs.
    - No derived fields (no powerFactor/utilization).
    - Backfill plantId/machineId from registry if missing.
    - Ensure receivedAt exists.
    """
    payload = event if isinstance(event, dict) else json.loads(event)

    # Normalize common fields (support alternate keys)
    mac_id = payload.get("macId") or payload.get("MACID")
    plant_id = payload.get("plantId")
    machine_id = payload.get("machineId") or payload.get("slaveName")

    # Optional registry lookup to backfill IDs only
    registry = _lookup_registry(mac_id)
    if not plant_id and registry.get("plantId"):
        plant_id = registry["plantId"]
    if not machine_id and registry.get("machineId"):
        machine_id = registry["machineId"]

    received_at = payload.get("receivedAt")
    if received_at is None:
        received_at = int(time.time() * 1000)

    # Build record with only device-sent numeric fields and identifiers
    record = {
        "packetId": payload.get("packetId") or payload.get("PacketID"),
        "macId": mac_id,
        "slaveName": payload.get("slaveName") or payload.get("SlaveName"),
        "slaveId": payload.get("slaveId") or payload.get("SlaveID"),
        # Forward any present power metrics as-is (no coercion/derivation)
        "kw": payload.get("kw") if payload.get("kw") is not None else payload.get("SlaveData", {}).get("Total_Kw"),
        "kvar": payload.get("kvar") if payload.get("kvar") is not None else payload.get("SlaveData", {}).get("Total_KVAr"),
        "kva": payload.get("kva") if payload.get("kva") is not None else payload.get("SlaveData", {}).get("Total_kVA"),
        "plantId": plant_id,
        "machineId": machine_id,
        "receivedAt": int(received_at),
    }

    partition_key = f"{plant_id or 'unknown'}#{machine_id or (mac_id or 'unknown')}"

    kinesis_client.put_record(
        StreamName=KINESIS_STREAM_NAME,
        Data=json.dumps(record),
        PartitionKey=partition_key,
    )

    return {"ok": True}