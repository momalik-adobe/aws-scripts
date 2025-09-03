import base64
import json


NUMERIC_FIELDS = [
    # Update this list to match your device payload metric keys
    "kw",
    "kva",
    "kvar",
    "total_kw",
    "total_kva",
    "total_kvar",
    "Total_Kw",
    "Total_KVAr",
    "Total_kVA"
]


def _to_float_or_none(value):
    if value is None:
        return None
    try:
        if isinstance(value, (int, float)):
            return float(value)
        # strings like "Response Timed Out" will raise
        return float(str(value).strip())
    except Exception:
        return None


def lambda_handler(event, context):
    out_records = []
    for rec in event.get("records", []):
        record_id = rec.get("recordId")
        try:
            raw = base64.b64decode(rec["data"]).decode("utf-8")
            obj = json.loads(raw)
        except Exception:
            out_records.append({"recordId": record_id, "result": "Dropped"})
            continue

        # Sanitize numeric fields
        for key in NUMERIC_FIELDS:
            if key in obj:
                obj[key] = _to_float_or_none(obj.get(key))

        # Policy: drop if required field (kw or total_kw) is missing after sanitize
        has_kw = obj.get("kw") is not None or obj.get("total_kw") is not None
        if not has_kw:
            out_records.append({"recordId": record_id, "result": "Dropped"})
            continue

        try:
            # Add newline after each JSON object for proper Athena parsing
            json_with_newline = json.dumps(obj) + "\n"
            enc = base64.b64encode(json_with_newline.encode("utf-8")).decode("utf-8")
            out_records.append({"recordId": record_id, "result": "Ok", "data": enc})
        except Exception:
            out_records.append({"recordId": record_id, "result": "Dropped"})

    return {"records": out_records}


