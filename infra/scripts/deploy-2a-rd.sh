#!/usr/bin/env bash
# Phase 2A-RD deploy runbook.
#
# Order (per phase-2a-read.md §Deployment):
#   1. cdk deploy GoSteady-Dev-Api  (creates patient-api Lambda)
#   2. Synthetic invoke to ensure the patient-api log group exists
#      (avoids the "log group doesn't exist" Audit-stack deploy failure
#       seen on 2A-0 — see phase-2a-foundation.md changelog).
#   3. cdk deploy GoSteady-Dev-Audit  (subscription-filter attach)
#
# Run from infra/ dir.

set -euo pipefail
cd "$(dirname "$0")/.."

echo "════════════════════════════════════════════════════════════"
echo "  Phase 2A-RD deploy — patient-api + audit subscription filter"
echo "════════════════════════════════════════════════════════════"

echo ""
echo "── Step 1/3: build (tsc) ──"
npm run build

echo ""
echo "── Step 2/3: cdk diff first (sanity) ──"
npx cdk diff GoSteady-Dev-Api --context env=dev 2>&1 | tail -60
echo ""
read -p "Continue with deploy? [y/N] " yn
case "$yn" in [Yy]*) ;; *) echo "Aborted."; exit 1 ;; esac

echo ""
echo "── Step 3a/3: cdk deploy GoSteady-Dev-Api ──"
npx cdk deploy GoSteady-Dev-Api --context env=dev --require-approval never

echo ""
echo "── Step 3b/3: synthetic invoke to create log group ──"
aws lambda invoke --region us-east-1 \
  --function-name gosteady-dev-patient-api \
  --cli-binary-format raw-in-base64-out \
  --payload '{"requestContext":{"http":{"method":"GET","path":"/api/v1/me/patients"},"requestId":"deploy-bootstrap"},"routeKey":"GET /api/v1/me/patients"}' \
  /tmp/_synth_invoke.json 2>&1 | head -5
echo "  (log group should now exist; cold-start invoke output ↓)"
cat /tmp/_synth_invoke.json 2>/dev/null | head -3 || true

echo ""
echo "── Step 3c/3: cdk deploy GoSteady-Dev-Audit ──"
npx cdk deploy GoSteady-Dev-Audit --context env=dev --require-approval never --exclusively

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  Deploy complete. Smoke test next:"
echo "    bash infra/scripts/smoke-2a-rd.sh"
echo "════════════════════════════════════════════════════════════"
