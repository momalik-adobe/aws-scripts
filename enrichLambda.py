import os
import json
import time
from decimal import Decimal
import boto3

kinesis_client = boto3.client("kinesis")
dynamodb = boto3.resource("dynamodb")

KINESIS_STREAM_NAME = os.environ["KINESIS_STREAM_NAME"]
DEVICE_REGISTRY_TABLE = os.environ["DEVICE_REGISTRY_TABLE"]
device_registry_table = dynamodb.Table(DEVICE_REGISTRY_TABLE)


def _to_float(value):
    try:
        if value is None:
            return None
        if isinstance(value, Decimal):
            return float(value)
        return float(value)
    except Exception:
        return None


def _derive_metrics(payload: dict, default_util_threshold_kw: float) -> dict:
    # Allow both flattened and nested payloads
    kw = payload.get("kw")
    if kw is None:
        kw = payload.get("SlaveData", {}).get("Total_Kw")

    kvar = payload.get("kvar")
    if kvar is None:
        kvar = payload.get("SlaveData", {}).get("Total_KVAr")

    kva = payload.get("kva")
    if kva is None:
        kva = payload.get("SlaveData", {}).get("Total_kVA")

    kw_f = _to_float(kw)
    kva_f = _to_float(kva)

    power_factor = None
    if kw_f is not None and kva_f and kva_f > 0:
        try:
            power_factor = round(kw_f / kva_f, 4)
        except Exception:
            power_factor = None

    utilization = 1 if (kw_f is not None and kw_f >= default_util_threshold_kw) else 0

    return {
        "kw": _to_float(kw),
        "kvar": _to_float(kvar),
        "kva": _to_float(kva),
        "powerFactor": power_factor,
        "utilization": utilization,
    }


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
    Expected event is the output of an IoT Topic Rule SELECT, e.g.:
    {
      "packetId": ..., "macId": "...", "slaveName": "...", "slaveId": ...,
      "kw": ..., "kvar": ..., "kva": ...,
      "plantId": "ka", "machineId": "machine-123", "receivedAt": 1717098290000
    }
    Falls back to nested SlaveData if kw/kvar/kva are absent.
    """
    # IoT Rule can pass a dict or JSON string. Normalize to dict.
    payload = event if isinstance(event, dict) else json.loads(event)

    mac_id = payload.get("macId") or payload.get("MACID")
    plant_id = payload.get("plantId")
    machine_id = payload.get("machineId") or payload.get("slaveName")

    # Registry enrichment (optional)
    registry = _lookup_registry(mac_id)
    util_threshold_kw = float(registry.get("utilThresholdKw", 0.3))

    if not plant_id and registry.get("plantId"):
        plant_id = registry["plantId"]
    if not machine_id and registry.get("machineId"):
        machine_id = registry["machineId"]

    metrics = _derive_metrics(payload, util_threshold_kw)

    received_at = payload.get("receivedAt")
    if received_at is None:
        received_at = int(time.time() * 1000)

    enriched = {
        "packetId": payload.get("packetId") or payload.get("PacketID"),
        "macId": mac_id,
        "slaveName": payload.get("slaveName") or payload.get("SlaveName"),
        "slaveId": payload.get("slaveId") or payload.get("SlaveID"),
        "plantId": plant_id,
        "machineId": machine_id,
        "receivedAt": int(received_at),
        **metrics,
    }

    # Partition key without nested expressions in f-string
    part_plant = plant_id or "unknown"
    part_machine = machine_id or (mac_id or "unknown")
    partition_key = f"{part_plant}#{part_machine}"

    kinesis_client.put_record(
        StreamName=KINESIS_STREAM_NAME,
        Data=json.dumps(enriched),
        PartitionKey=partition_key,
    )

    return {"ok": True}