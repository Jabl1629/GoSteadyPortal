#!/usr/bin/env bash
# Bring up a NEW PRODUCTION GoSteady unit — cloud side, end to end + reusable.
#
# Prod analogue of docs/playbooks/new-dev-unit-bringup.md, differing in THREE
# deliberate ways (coord §C57):
#   1. Prod IoT resources: gosteady-prod-* policy/table + GoSteady*Platform-prod
#      thing types (account 460223323193 — same as dev; prod is not a separate
#      account, so the IoT endpoint is UNCHANGED).
#   2. NO `activated_at` shortcut. Prod units go through the formal
#      claim → provision → activate flow (D2C: the household claims the QR,
#      which provisions + fires the activate cmd). The dev put-item shortcut is
#      forbidden for shipping units (defeats the audit trail + pre-activation
#      suppression — new-dev-unit-bringup.md §1.4).
#   3. Server-minted `walkerId` + QR/claim-link. The row is created through the
#      internal_admin bulk-create Lambda path (device-api `_action_admin_create`,
#      QR-provisioning spec §4 "load-bearing" mint), so the UUIDv4 walkerId is
#      minted + audited server-side, then written to the sparse `by-walker-id`
#      GSI that the /setup/{walkerId} public lookup resolves.
#
# This script does the CLOUD side only. The firmware flash (cert → modem
# sec_tag 201, rebuild with the serial baked, flash) is the bench/firmware
# handoff — printed at the end. Deferred (fleet, not first units): printed
# short-code fallback + claim-binding-to-phone (QR spec §2-3).
#
# Usage:
#   ./tools/bringup-prod-unit.sh <SERIAL> [deviceType] [hardwareVariant]
#   ./tools/bringup-prod-unit.sh GS0002000001 rollator_platform thingy91x_bench
#
#   deviceType: rollator_platform (default) | walker_cap
set -euo pipefail

SERIAL="${1:?usage: bringup-prod-unit.sh <SERIAL> [deviceType] [hardwareVariant]}"
DEVICE_TYPE="${2:-rollator_platform}"
HARDWARE_VARIANT="${3:-}"

REGION=us-east-1
ACCOUNT=460223323193
POLICY=gosteady-prod-device-policy
TABLE=gosteady-prod-devices
DEVICE_API_FN=gosteady-prod-device-api
APP_DOMAIN=app.gosteady.co
IOT_ENDPOINT=a2dl73jkjzv6h5-ats.iot.us-east-1.amazonaws.com
BUNDLE="$HOME/Desktop/gosteady-prod-cert-handoff"

case "$DEVICE_TYPE" in
  rollator_platform) THING_TYPE=GoSteadyRollatorPlatform-prod ;;
  walker_cap)        THING_TYPE=GoSteadyWalkerCap-prod ;;
  *) echo "✘ unknown deviceType: $DEVICE_TYPE (rollator_platform|walker_cap)" >&2; exit 64 ;;
esac

[[ "$SERIAL" =~ ^GS[0-9]{10}$ ]] || { echo "✘ serial must be GS + 10 digits" >&2; exit 64; }
SERIAL_LC=$(printf '%s' "$SERIAL" | tr '[:upper:]' '[:lower:]')  # macOS bash 3.2 lacks ${x,,}

echo "▸ PROD bring-up: $SERIAL  ($DEVICE_TYPE / $THING_TYPE)"
echo "  account $ACCOUNT · $REGION · IoT $IOT_ENDPOINT"

# Guard: refuse to run against the wrong account (dev and prod share 460223323193,
# but this makes the intent explicit + catches a mis-scoped profile).
CALLER=$(aws sts get-caller-identity --query Account --output text)
[[ "$CALLER" == "$ACCOUNT" ]] || { echo "✘ wrong AWS account ($CALLER != $ACCOUNT)" >&2; exit 1; }

# Guard: don't clobber an existing Thing.
if aws iot describe-thing --region "$REGION" --thing-name "$SERIAL" >/dev/null 2>&1; then
  echo "✘ IoT Thing $SERIAL already exists — pick a fresh serial or decommission it first" >&2
  exit 1
fi

mkdir -p "$BUNDLE/$SERIAL"

# flash_cert.py needs <bundle>/AmazonRootCA1.pem — stage it so the prod bundle is
# flash-ready (else the firmware cert flash fails resolving the root CA). Copy
# from the dev handoff bundle if present; otherwise warn (it's the public Amazon
# Root CA 1 — drop it in before flashing).
DEV_BUNDLE="$HOME/Desktop/gosteady-firmware-cert-handoff-2026-04-27"
if [[ ! -f "$BUNDLE/AmazonRootCA1.pem" ]]; then
  if [[ -f "$DEV_BUNDLE/AmazonRootCA1.pem" ]]; then
    cp "$DEV_BUNDLE/AmazonRootCA1.pem" "$BUNDLE/AmazonRootCA1.pem"
    echo "  staged AmazonRootCA1.pem into $BUNDLE/"
  else
    echo "  ⚠ AmazonRootCA1.pem missing from $BUNDLE — add it before flash_cert.py"
  fi
fi

echo "▸ Minting cert + key…"
aws iot create-keys-and-certificate --region "$REGION" --set-as-active \
  --certificate-pem-outfile "$BUNDLE/$SERIAL/$SERIAL.cert.pem" \
  --public-key-outfile      "$BUNDLE/$SERIAL/$SERIAL.public.key" \
  --private-key-outfile     "$BUNDLE/$SERIAL/$SERIAL.private.key" \
  --output json > "$BUNDLE/$SERIAL/$SERIAL.create.json"
chmod 0600 "$BUNDLE/$SERIAL/$SERIAL.private.key"
CERT_ARN=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['certificateArn'])" "$BUNDLE/$SERIAL/$SERIAL.create.json")
CERT_ID="${CERT_ARN##*/}"
echo "  cert $CERT_ID"

echo "▸ Creating IoT Thing + attaching prod policy…"
aws iot create-thing --region "$REGION" --thing-name "$SERIAL" --thing-type-name "$THING_TYPE" >/dev/null
aws iot attach-policy --region "$REGION" --policy-name "$POLICY" --target "$CERT_ARN"
aws iot attach-thing-principal --region "$REGION" --thing-name "$SERIAL" --principal "$CERT_ARN"

echo "▸ Creating device row + minting walkerId (server-side internal_admin)…"
WALKER_ID=$(python3 - "$SERIAL" "$DEVICE_TYPE" "$CERT_ID" "$HARDWARE_VARIANT" "$DEVICE_API_FN" "$REGION" "$TABLE" <<'PY'
import sys, json, time, boto3
serial, dtype, cert_id, hwv, fn, region, table = sys.argv[1:8]
dev = {"serialNumber": serial, "deviceType": dtype, "certFingerprint": cert_id}
if hwv:
    dev["hardwareVariant"] = hwv
# Option-A synthetic internal_admin invoke (precedent: infra/scripts/smoke-dt0.py).
event = {
    "routeKey": "POST /api/v1/admin/devices",
    "rawPath": "/api/v1/admin/devices",
    "requestContext": {"http": {"method": "POST"}, "authorizer": {"jwt": {"claims": {
        "sub": "prod-bringup-internal-admin",
        "custom:clientId": "_internal",
        "custom:role": "internal_admin",
        "custom:mfa_enrolled": "true",
        "iat": str(int(time.time())),
    }}}},
    "pathParameters": {},
    "body": json.dumps({"devices": [dev]}),
}
resp = boto3.client("lambda", region_name=region).invoke(
    FunctionName=fn, Payload=json.dumps(event).encode())
payload = json.loads(resp["Payload"].read())
status, body = payload.get("statusCode"), json.loads(payload.get("body") or "null")
if status != 200:
    sys.stderr.write(f"admin-create failed: {status} {body}\n"); sys.exit(1)
devs = (body or {}).get("devices") or []
if devs:
    print(devs[0]["walkerId"]); sys.exit(0)
# Serial already existed (idempotent skip) — reuse the row's walkerId.
it = boto3.client("dynamodb", region_name=region).get_item(
    TableName=table, Key={"serialNumber": {"S": serial}}).get("Item", {})
wid = it.get("walkerId", {}).get("S")
if not wid:
    sys.stderr.write(f"{serial} exists WITHOUT a walkerId (created pre-mint) — decommission + re-run\n")
    sys.exit(1)
sys.stderr.write(f"{serial} already existed; reusing its walkerId\n")
print(wid)
PY
)
echo "  walkerId $WALKER_ID"
SETUP_URL="https://$APP_DOMAIN/setup/$WALKER_ID"

echo "▸ Rendering QR (best-effort)…"
QR_PNG="$BUNDLE/$SERIAL/$SERIAL.qr.png"
if command -v qrencode >/dev/null 2>&1; then
  qrencode -o "$QR_PNG" -s 8 -m 2 "$SETUP_URL" && echo "  QR → $QR_PNG"
elif python3 -c "import qrcode" >/dev/null 2>&1; then
  python3 -c "import qrcode,sys;qrcode.make(sys.argv[1]).save(sys.argv[2])" "$SETUP_URL" "$QR_PNG" && echo "  QR → $QR_PNG"
else
  echo "  ⚠ no QR renderer (brew install qrencode  OR  pip install 'qrcode[pil]'); the claim URL below still works"
fi

echo "▸ Verifying cloud state…"
STATUS_ROW=$(aws dynamodb get-item --region "$REGION" --table-name "$TABLE" \
  --key "{\"serialNumber\":{\"S\":\"$SERIAL\"}}" \
  --query 'Item.{s:status.S,w:walkerId.S,t:deviceType.S}' --output text)
echo "  registry: $STATUS_ROW  (expect: ready_to_provision  $WALKER_ID  $DEVICE_TYPE)"

cat <<EOF

════════ PROD UNIT $SERIAL — ready_to_provision ════════
  deviceType : $DEVICE_TYPE
  walkerId   : $WALKER_ID
  claim URL  : $SETUP_URL
  QR / cert  : $BUNDLE/$SERIAL/

  ⚠ QR LOCK (QR spec §5): only print/glue the sticker once app.gosteady.co
    resolves live (DNS + ACM). The claim itself also needs the app live.

  FIRMWARE HANDOFF (bench; SW2 = nRF91; endpoint unchanged — shared account):
    1. Flash Nordic at_client, then in gosteady-firmware:
         tools/flash_cert.py --serial $SERIAL      # cert+key → modem sec_tag 201
    2. Rebuild the rollator image with THIS serial baked (client_id):
         west build -b thingy91x/nrf9151/ns -d build_rollator_${SERIAL_LC} \\
           -- -DEXTRA_CONF_FILE=prj_rollator_cloud.conf \\
              -DCONFIG_AWS_IOT_CLIENT_ID_STATIC=\"$SERIAL\"
    3. nrfjprog -f NRF91 --program build_rollator_${SERIAL_LC}/merged.hex \\
         --chiperase --verify --reset
    → device boots, connects as $SERIAL, publishes heartbeat to gs/$SERIAL/*.

  THEN (full claim→activate, needs Twilio prod secret + app live):
    open $SETUP_URL on a phone → SMS-OTP sign-up → claim → provisions the
    device + fires the activate cmd → walk → activity → dashboard.
EOF
