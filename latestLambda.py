import os
import boto3
from boto3.dynamodb.types import TypeDeserializer

_dynamodb = boto3.resource("dynamodb")
LATEST_TABLE = os.environ["LATEST_TABLE"]
latest_table = _dynamodb.Table(LATEST_TABLE)

deserializer = TypeDeserializer()


def _from_ddb_image(image: dict) -> dict:
    return {k: deserializer.deserialize(v) for k, v in (image or {}).items()}


def lambda_handler(event, context):
    for record in event.get("Records", []):
        if record.get("eventName") not in ("INSERT", "MODIFY"):
            continue

        new_image = record.get("dynamodb", {}).get("NewImage")
        if not new_image:
            continue

        item = _from_ddb_image(new_image)
        plant_id = item.get("plantId")
        machine_id = item.get("machineId")
        ts = item.get("timestamp")
        if not plant_id or not machine_id or ts is None:
            continue

        latest_key = f"{plant_id}#{machine_id}"
        latest_row = {
            "plantMachineId": latest_key,
            "plantId": plant_id,
            "machineId": machine_id,
            "lastTimestamp": int(ts),
            # keep only device-sent metrics
            "macId": item.get("macId"),
            "kw": item.get("kw"),
            "kvar": item.get("kvar"),
            "kva": item.get("kva"),
        }

        try:
            latest_table.put_item(
                Item=latest_row,
                ConditionExpression="attribute_not_exists(lastTimestamp) OR :ts > lastTimestamp",
                ExpressionAttributeValues={":ts": int(ts)},
            )
        except latest_table.meta.client.exceptions.ConditionalCheckFailedException:
            pass
        except Exception as e:
            print("Put latest failed:", str(e))

    return {"ok": True}