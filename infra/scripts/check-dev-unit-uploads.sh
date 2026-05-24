#!/usr/bin/env bash
# Diagnostic for "no recent activity uploads from GS9999999998" — Phase 2A-RD
# real-data smoke step 5 investigation lever.
#
# Checks:
#   1. Most recent heartbeat in Shadow (lastSeen / battery_pct)
#   2. Activity rows in DDB ordered DESC by timestamp (count last 7d)
#   3. Snippet uploads to S3 (count last 7d)
#   4. Heartbeat-processor log volume last 24h
#   5. SIM-exhaustion signals via crash_forensics + recent fault_counters
#
# Run:  bash infra/scripts/check-dev-unit-uploads.sh GS9999999998

set -euo pipefail
SERIAL="${1:-GS9999999998}"
REGION="us-east-1"
ENV="dev"

echo "════════════════════════════════════════════════════════════"
echo "  Dev unit upload diagnostic  —  serial: $SERIAL"
echo "════════════════════════════════════════════════════════════"

# 1. Shadow
echo ""
echo "── 1) Device Shadow (lastSeen, battery_pct, firmware, fault counters) ──"
aws iot-data get-thing-shadow \
  --thing-name "$SERIAL" \
  --region "$REGION" \
  /tmp/_dev_shadow.json >/dev/null 2>&1 \
  && jq '.state.reported | {firmware, battery_pct, rsrp_dbm, snr_db,
       boot_count, reset_reason, fault_counters, watchdog_hits, lastSeen, ts}' \
       /tmp/_dev_shadow.json \
  || echo "  (no shadow document — device never connected)"

# 2. Activity rows (DDB)
echo ""
echo "── 2) Activity Series: last 10 rows on this serial's patient ──"
# First discover which patient is currently assigned
PATIENT_ID=$(aws dynamodb query \
  --table-name "gosteady-${ENV}-device-assignments" \
  --index-name by-patient --region "$REGION" 2>/dev/null \
  --filter-expression 'serialNumber = :s AND attribute_not_exists(validUntil)' \
  --expression-attribute-values "{\":s\":{\"S\":\"$SERIAL\"}}" \
  --query 'Items[0].patientId.S' --output text 2>/dev/null || echo "NONE")

if [ "$PATIENT_ID" = "NONE" ] || [ "$PATIENT_ID" = "None" ]; then
  # Fall back: scan assignments table for this serial
  PATIENT_ID=$(aws dynamodb query \
    --table-name "gosteady-${ENV}-device-assignments" --region "$REGION" \
    --key-condition-expression "serialNumber = :s" \
    --filter-expression "attribute_not_exists(validUntil)" \
    --expression-attribute-values "{\":s\":{\"S\":\"$SERIAL\"}}" \
    --query 'Items[0].patientId.S' --output text 2>/dev/null || echo "NONE")
fi

if [ "$PATIENT_ID" != "NONE" ] && [ "$PATIENT_ID" != "None" ] && [ -n "$PATIENT_ID" ]; then
  echo "  Patient currently assigned: $PATIENT_ID"
  aws dynamodb query \
    --table-name "gosteady-${ENV}-activity" --region "$REGION" \
    --key-condition-expression "patientId = :p" \
    --expression-attribute-values "{\":p\":{\"S\":\"$PATIENT_ID\"}}" \
    --no-scan-index-forward --limit 10 \
    --query 'Items[*].{ts:timestamp.S,steps:steps.N,distance:distanceFt.N,firmware:firmwareVersion.S}' \
    --output table 2>/dev/null \
    || echo "  (no activity rows; query failed)"
else
  echo "  ! No active assignment for $SERIAL — checking ALL assignments..."
  aws dynamodb query \
    --table-name "gosteady-${ENV}-device-assignments" --region "$REGION" \
    --key-condition-expression "serialNumber = :s" \
    --expression-attribute-values "{\":s\":{\"S\":\"$SERIAL\"}}" \
    --no-scan-index-forward --limit 3 \
    --query 'Items[*].{patientId:patientId.S,assignedAt:assignedAt.S,validUntil:validUntil.S}' \
    --output table 2>/dev/null
fi

# 3. Snippet uploads
echo ""
echo "── 3) Recent snippet uploads (last 14 days, top 5) ──"
aws s3api list-objects-v2 \
  --bucket "gosteady-${ENV}-snippets" --region "$REGION" \
  --prefix "$SERIAL/" --max-keys 1000 \
  --query "reverse(sort_by(Contents, &LastModified))[:5].{Key:Key, Size:Size, LastModified:LastModified}" \
  --output table 2>/dev/null || echo "  (no snippets in bucket)"

# 4. Heartbeat-processor log volume
echo ""
echo "── 4) heartbeat-processor log volume (last 48h) ──"
START_MS=$(($(date +%s) - 48*3600))000
aws logs filter-log-events --region "$REGION" \
  --log-group-name "/aws/lambda/gosteady-${ENV}-heartbeat-processor" \
  --filter-pattern "{ \$.serial = \"$SERIAL\" }" \
  --start-time "$START_MS" \
  --query 'length(events)' --output text 2>/dev/null \
  | awk '{print "  events filtered (serial match): " $1}' \
  || echo "  (filter failed)"

# Last 3 heartbeat events for this serial
aws logs filter-log-events --region "$REGION" \
  --log-group-name "/aws/lambda/gosteady-${ENV}-heartbeat-processor" \
  --filter-pattern "{ \$.serial = \"$SERIAL\" }" \
  --start-time "$START_MS" --max-items 3 \
  --query 'events[*].{ts:timestamp,msg:message}' --output text 2>/dev/null \
  | head -20 || true

# 5. activity-processor reject signals
echo ""
echo "── 5) activity-processor recent reject log lines (last 48h) ──"
aws logs filter-log-events --region "$REGION" \
  --log-group-name "/aws/lambda/gosteady-${ENV}-activity-processor" \
  --filter-pattern "{ \$.event = \"activity_reject\" }" \
  --start-time "$START_MS" --max-items 5 \
  --query 'events[*].message' --output text 2>/dev/null \
  | head -30 || echo "  (no activity_reject events)"

echo ""
echo "── 6) IoT MQTT connection events (last 48h) ──"
# Quick check: was this device CONNECTED at all in the last 48h?
aws logs filter-log-events --region "$REGION" \
  --log-group-name "/aws/lambda/gosteady-${ENV}-connection-coordinator" \
  --filter-pattern "$SERIAL" \
  --start-time "$START_MS" --max-items 5 \
  --query 'length(events)' --output text 2>/dev/null \
  | awk '{print "  coordinator events touching " "'"$SERIAL"'" ": " $1}' \
  || echo "  (coordinator log group not found)"

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  Done."
echo "════════════════════════════════════════════════════════════"
echo ""
echo "Interpretation guide:"
echo "  - Stale Shadow + zero events     → SIM exhausted or device offline"
echo "  - Fresh Shadow + zero activity   → firmware bug (sessions not capturing)"
echo "  - Fresh Shadow + rejects > 0     → cloud-side validation rejecting payload"
echo "  - watchdog_hits or fault_counters changing → firmware regression"
