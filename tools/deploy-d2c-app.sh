#!/usr/bin/env bash
# Build and deploy the GoSteady LIVE D2C consumer app (main_d2c.dart) to its
# OWN S3 + CloudFront site — app.gosteady.co (dev: dev.app.gosteady.co).
#
# This is the REAL consumer app: Cognito D2C pool + live API + the
# /setup/:walkerId claim flow. It is NOT:
#   - the facility portal      → tools/deploy-portal.sh   (dev.portal.gosteady.co)
#   - the mock userdemo wireframe → tools/deploy-d2c-demo.sh (Netlify, gosteady.co/userdemo)
#
# The D2C app has its OWN bucket + distribution (GoSteady-<Env>-D2CHosting), so
# there is NO shared-bucket "/d2c/" footgun — contrast deploy-portal.sh, which
# must `--exclude "d2c/*"` because the legacy D2C build shared the portal bucket
# (coord §C41.3 #3). Splitting the sites is the durable fix that §C41.3 flagged;
# app.gosteady.co IS that split (coord §C54).
#
# Usage:
#   ./tools/deploy-d2c-app.sh                 # full build + deploy (dev)
#   ./tools/deploy-d2c-app.sh --build-only    # build only, no AWS calls
#   ./tools/deploy-d2c-app.sh --env=prod      # deploy to prod hosting
#
# Pre-requisites (one-time):
#   - GoSteady-<Env>-D2CHosting deployed + its ACM cert VALIDATED (the
#     validation CNAMEs are added manually at Squarespace DNS; the deploy hangs
#     on the cert until then), and the app CNAME points at the CloudFront domain.
#   - GoSteady-<Env>-Api deployed (provides HttpApiUrl, the /api/v1/d2c/* routes,
#     and the CORS allow-origin for this app's domain).
#   - aws CLI configured with the target-account creds; flutter SDK on PATH.
set -euo pipefail

ENV="dev"
BUILD_ONLY=0
# All GoSteady stacks live in us-east-1 (IoT Core global endpoint + CloudFront
# ACM requirement). Pin it explicitly — the operator's default CLI region may
# differ (e.g. us-east-2), which would make the describe-stacks calls find
# nothing (see deploy-portal.sh for the same fix).
REGION="us-east-1"
TARGET="lib/main_d2c.dart"

for arg in "$@"; do
  case "$arg" in
    --build-only) BUILD_ONLY=1 ;;
    --env=*) ENV="${arg#*=}" ;;
    *) echo "Unknown arg: $arg" >&2; exit 64 ;;
  esac
done

# Stack name prefix matches infra/bin/gosteady.ts (capitalized env prefix).
STACK_PREFIX="GoSteady-$(echo "${ENV:0:1}" | tr '[:lower:]' '[:upper:]')${ENV:1}"
HOSTING_STACK="${STACK_PREFIX}-D2CHosting"
API_STACK="${STACK_PREFIX}-Api"

echo "▸ Resolving API base URL from ${API_STACK}…"
API_URL=$(aws cloudformation describe-stacks --stack-name "$API_STACK" --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`HttpApiUrl`].OutputValue' \
  --output text 2>/dev/null || true)
if [[ -z "$API_URL" || "$API_URL" == "None" ]]; then
  # Fall back: older CDK revisions exported the URL under any *Url key.
  API_URL=$(aws cloudformation describe-stacks --stack-name "$API_STACK" --region "$REGION" \
    --query 'Stacks[0].Outputs[?contains(OutputKey, `Url`)].OutputValue | [0]' \
    --output text 2>/dev/null || true)
fi
if [[ -z "$API_URL" || "$API_URL" == "None" ]]; then
  echo "✘ Could not resolve API URL from $API_STACK outputs." >&2
  echo "  Check that the stack is deployed and exposes an *Url* output." >&2
  exit 1
fi
API_URL="${API_URL%/}"
echo "  API_BASE_URL=$API_URL"

# Resolve the D2C Cognito pool + client ids from the D2C-Auth stack the SAME way
# we resolve the API URL — so a prod build bakes in the PROD pool, never the dev
# ids (coord §C57.3 #2: d2c_cognito_config.dart no longer hardcodes them). The
# outputs are D2CUserPoolId / D2CPortalClientId (infra/lib/stacks/d2c-auth-stack.ts).
D2C_AUTH_STACK="${STACK_PREFIX}-D2C-Auth"
echo "▸ Resolving D2C pool + client ids from ${D2C_AUTH_STACK}…"
D2C_USER_POOL_ID=$(aws cloudformation describe-stacks --stack-name "$D2C_AUTH_STACK" --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`D2CUserPoolId`].OutputValue' \
  --output text 2>/dev/null || true)
D2C_CLIENT_ID=$(aws cloudformation describe-stacks --stack-name "$D2C_AUTH_STACK" --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`D2CPortalClientId`].OutputValue' \
  --output text 2>/dev/null || true)
if [[ -z "$D2C_USER_POOL_ID" || "$D2C_USER_POOL_ID" == "None" \
   || -z "$D2C_CLIENT_ID"    || "$D2C_CLIENT_ID"    == "None" ]]; then
  echo "✘ Could not resolve D2C pool/client ids from $D2C_AUTH_STACK outputs." >&2
  echo "  Check that the D2C-Auth stack is deployed and exposes" >&2
  echo "  D2CUserPoolId + D2CPortalClientId." >&2
  exit 1
fi
echo "  D2C_USER_POOL_ID=$D2C_USER_POOL_ID"
echo "  D2C_CLIENT_ID=$D2C_CLIENT_ID"

# The D2C app serves at the domain ROOT with path-URL routing
# (main_d2c.dart calls setPathUrlStrategy() + D2CRoutes.prefix = ''), so
# --base-href stays "/". Deep links like /setup/<id> survive reload via the
# hosting stack's 404/403 → /index.html rewrite.
echo "▸ Building Flutter D2C app (${TARGET}, BUILD_MODE=live, --release)…"
flutter build web -t "$TARGET" \
  --dart-define=BUILD_MODE=live \
  --dart-define=API_BASE_URL="$API_URL" \
  --dart-define=D2C_USER_POOL_ID="$D2C_USER_POOL_ID" \
  --dart-define=D2C_CLIENT_ID="$D2C_CLIENT_ID" \
  --release

if [[ $BUILD_ONLY -eq 1 ]]; then
  echo "✓ Build complete at build/web/. Skipping deploy."
  exit 0
fi

echo "▸ Resolving hosting outputs from ${HOSTING_STACK}…"
BUCKET=$(aws cloudformation describe-stacks --stack-name "$HOSTING_STACK" --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`BucketName`].OutputValue' --output text)
DIST_ID=$(aws cloudformation describe-stacks --stack-name "$HOSTING_STACK" --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`DistributionId`].OutputValue' --output text)
APP_URL=$(aws cloudformation describe-stacks --stack-name "$HOSTING_STACK" --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`PortalUrl`].OutputValue' --output text)

if [[ -z "$BUCKET" || -z "$DIST_ID" ]]; then
  echo "✘ Could not resolve BucketName/DistributionId from $HOSTING_STACK." >&2
  echo "  Has the D2CHosting stack been deployed (+ ACM cert validated)?" >&2
  exit 1
fi
echo "  Bucket:       $BUCKET"
echo "  Distribution: $DIST_ID"

# Dedicated bucket — a full `--delete` sweep is safe (no shared /d2c/ path to
# protect, unlike the facility portal bucket).
echo "▸ Syncing build/web/ → s3://$BUCKET/ …"
aws s3 sync build/web/ "s3://$BUCKET/" --delete --region "$REGION"

echo "▸ Invalidating CloudFront cache /*…"
INVAL_ID=$(aws cloudfront create-invalidation \
  --distribution-id "$DIST_ID" --region "$REGION" \
  --paths "/*" --query 'Invalidation.Id' --output text)
echo "  invalidation: $INVAL_ID"

echo
echo "✓ Deployed D2C app: $APP_URL"
echo "  Setup deep-link:  ${APP_URL%/}/setup/<walkerId>"
echo
echo "  Cache invalidation typically completes within ~60 seconds."
echo "  Verify with:"
echo "    curl -I '$APP_URL'"
