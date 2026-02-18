import io
import json
import os

import requests


def handler(ctx, data: io.BytesIO = None):
    hec_url = os.getenv("SPLUNK_HEC_URL")
    hec_token = os.getenv("SPLUNK_HEC_TOKEN")
    hec_index = os.getenv("SPLUNK_HEC_INDEX", "main")

    if not hec_url or not hec_token:
        raise RuntimeError("SPLUNK_HEC_URL and SPLUNK_HEC_TOKEN are required")

    raw_body = data.getvalue().decode("utf-8") if data else "{}"
    payload = json.loads(raw_body)

    headers = {
        "Authorization": f"Splunk {hec_token}",
        "Content-Type": "application/json",
    }

    event_doc = {
        "index": hec_index,
        "source": "oci-functions",
        "sourcetype": "oci:log",
        "event": payload,
    }

    resp = requests.post(hec_url, headers=headers, data=json.dumps(event_doc), timeout=15)
    resp.raise_for_status()
    return {"status": "ok", "code": resp.status_code}
