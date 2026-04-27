"""
Snippet Parser Lambda — Phase 1A revision

Triggered by: IoT Rule on gs/+/snippet
IoT Rule SQL:
    SELECT encode(*, 'base64') AS payload_b64,
           topic(2)            AS thingName,
           timestamp()         AS rule_ts_ms
    FROM 'gs/+/snippet'

Why a Lambda is in the snippet path (firmware coord §F.3 / §C.2): NCS
3.2.4 ships MQTT 3.1.1 only, so MQTT 5 user properties are not available
to carry snippet metadata. Firmware moves snippet_id / window_start_ts /
anomaly_trigger into a JSON header preamble inside the binary payload.
IoT Rule SQL alone cannot extract the JSON-embedded snippet_id to build
the S3 key, so a thin Python Lambda parses the preamble and PutObject's
the full payload (preamble + binary body) to S3.

Wire format (firmware coord §F.3 / ARCHITECTURE.md §7):

    [4-byte big-endian uint32: header_len]
    [header_len bytes UTF-8 JSON: {snippet_id, window_start_ts, anomaly_trigger?}]
    [16-byte payload header (little-endian): format_version, sensor_id,
                                             sample_rate_hz, sample_count_n,
                                             window_start_uptime_ms]
    [N × 28-byte sample records: t_ms, ax, ay, az, gx, gy, gz]

Total payload ≤100 KB (firmware contract; IoT Core hard cap is 128 KB).

Error policy: any exception propagates → IoT Rule sees a failed
invocation → routes to the SQS DLQ (gosteady-{env}-iot-dlq).
A structured error log lands first so ops can see the cause without
draining the DLQ.

Idempotency: same snippet_id → same S3 key → byte-equal overwrite.
PutObject is idempotent at the object-key level for our use case.
"""

import base64
import json
import os
import struct
from datetime import datetime, timezone

import boto3

# ── Configuration ────────────────────────────────────────────────
SNIPPET_BUCKET = os.environ["SNIPPET_BUCKET"]

# Validation knobs — must match firmware §F.3 / §F.4.
EXPECTED_FORMAT_VERSION = 1
EXPECTED_SENSOR_ID = 1
EXPECTED_SAMPLE_RATE_HZ = 100  # warn-only on mismatch (spec D5 logic)
ALLOWED_ANOMALY_TRIGGERS = {"session_sigma", "R_outlier", "high_g"}

# 16-byte payload header (little-endian, packed):
#   uint8 format_version, uint8 sensor_id, uint16 sample_rate_hz,
#   uint32 sample_count_n, uint64 window_start_uptime_ms
PAYLOAD_HEADER_FMT = "<BBHIQ"
PAYLOAD_HEADER_LEN = struct.calcsize(PAYLOAD_HEADER_FMT)
assert PAYLOAD_HEADER_LEN == 16

# ── AWS clients ──────────────────────────────────────────────────
_s3 = boto3.client("s3")


# ── Errors ───────────────────────────────────────────────────────
class SnippetValidationError(ValueError):
    """Snippet payload failed structural or schema validation."""


# ── Helpers ──────────────────────────────────────────────────────
def _parse_iso(ts: str) -> datetime:
    return datetime.fromisoformat(ts.replace("Z", "+00:00"))


def _validate_json_header(header: dict) -> None:
    snippet_id = header.get("snippet_id")
    if not isinstance(snippet_id, str) or not snippet_id:
        raise SnippetValidationError("snippet_id missing or not a non-empty string")

    window_start_ts = header.get("window_start_ts")
    if not isinstance(window_start_ts, str):
        raise SnippetValidationError("window_start_ts missing or not a string")
    try:
        _parse_iso(window_start_ts)
    except (TypeError, ValueError) as e:
        raise SnippetValidationError(f"window_start_ts not parseable ISO 8601: {e}")

    trigger = header.get("anomaly_trigger")
    if trigger is not None and trigger not in ALLOWED_ANOMALY_TRIGGERS:
        raise SnippetValidationError(
            f"anomaly_trigger {trigger!r} not in {sorted(ALLOWED_ANOMALY_TRIGGERS)}"
        )


def _validate_payload_header(payload_bytes: bytes, body_offset: int) -> None:
    if len(payload_bytes) - body_offset < PAYLOAD_HEADER_LEN:
        raise SnippetValidationError("binary body shorter than 16-byte payload header")
    fmt_v, sensor_id, sample_rate, _sample_count, _uptime = struct.unpack_from(
        PAYLOAD_HEADER_FMT, payload_bytes, body_offset
    )
    if fmt_v != EXPECTED_FORMAT_VERSION:
        raise SnippetValidationError(
            f"format_version {fmt_v} unsupported (expect {EXPECTED_FORMAT_VERSION})"
        )
    if sensor_id != EXPECTED_SENSOR_ID:
        raise SnippetValidationError(
            f"sensor_id {sensor_id} unsupported (expect {EXPECTED_SENSOR_ID})"
        )
    # Sample-rate mismatch is warn-not-error: firmware may experiment.
    if sample_rate != EXPECTED_SAMPLE_RATE_HZ:
        print(
            f"[SNIPPET][WARN] sample_rate_hz={sample_rate} "
            f"(expected {EXPECTED_SAMPLE_RATE_HZ}); accepting"
        )


# ── Handler ──────────────────────────────────────────────────────
def handler(event, _context):
    serial = event.get("thingName") or "UNKNOWN"
    payload_b64 = event.get("payload_b64")
    if not isinstance(payload_b64, str) or not payload_b64:
        raise SnippetValidationError("payload_b64 missing from rule event")

    payload_bytes = base64.b64decode(payload_b64)
    if len(payload_bytes) < 4:
        raise SnippetValidationError("payload shorter than 4-byte length prefix")

    (header_len,) = struct.unpack(">I", payload_bytes[:4])
    body_offset = 4 + header_len
    if body_offset > len(payload_bytes):
        raise SnippetValidationError(
            f"declared header_len={header_len} overruns payload "
            f"(total={len(payload_bytes)} bytes)"
        )

    try:
        header = json.loads(payload_bytes[4:body_offset].decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as e:
        raise SnippetValidationError(f"JSON header not parseable: {e}")
    if not isinstance(header, dict):
        raise SnippetValidationError("JSON header is not an object")

    _validate_json_header(header)
    _validate_payload_header(payload_bytes, body_offset)

    snippet_id = header["snippet_id"]
    window_start_ts = header["window_start_ts"]
    anomaly_trigger = header.get("anomaly_trigger")

    date = _parse_iso(window_start_ts).astimezone(timezone.utc).strftime("%Y-%m-%d")
    s3_key = f"{serial}/{date}/{snippet_id}.bin"

    try:
        _s3.put_object(
            Bucket=SNIPPET_BUCKET,
            Key=s3_key,
            Body=payload_bytes,
            ContentType="application/octet-stream",
        )
    except Exception:
        # Surface a structured error log before letting the IoT Rule
        # error-action route to the DLQ.
        print(
            json.dumps(
                {
                    "event": "device.snippet_upload_failed",
                    "serial": serial,
                    "snippet_id": snippet_id,
                    "s3_key": s3_key,
                    "size_bytes": len(payload_bytes),
                }
            )
        )
        raise

    print(
        json.dumps(
            {
                "event": "device.snippet_uploaded",
                "serial": serial,
                "snippet_id": snippet_id,
                "window_start_ts": window_start_ts,
                "anomaly_trigger": anomaly_trigger,
                "size_bytes": len(payload_bytes),
                "s3_key": s3_key,
            }
        )
    )
    return {"statusCode": 200, "body": f"snippet stored at s3://{SNIPPET_BUCKET}/{s3_key}"}
