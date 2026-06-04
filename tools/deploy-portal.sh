#!/usr/bin/env bash
# Build and deploy the GoSteady live-mode portal to dev.portal.gosteady.co.
#
# Usage:
#   ./tools/deploy-portal.sh                    # full build + deploy
#   ./tools/deploy-portal.sh --build-only       # build only, no AWS calls
#   ./tools/deploy-portal.sh --env=prod         # deploy to prod hosting (Phase 3A)
#
# Pre-requisites (one-time):
#   - GoSteady-Dev-PortalHosting stack deployed
#   - dev.portal CNAME at Squarespace DNS points to the CloudFront domain
#   - aws CLI configured with dev-account credentials
#   - flutter SDK ≥ 3.16.0 on PATH
#
# Per phase-2b-0-foundation.md L15 + §Deployment > Deploy Commands.
set -euo pipefail

ENV="dev"
BUILD_ONLY=0
# All GoSteady stacks live in us-east-1 (IoT Core global endpoint + CloudFront
# ACM requirement). The operator's default CLI region may differ (e.g.
# us-east-2), so pin it explicitly — otherwise the describe-stacks calls below
# silently find nothing and the script aborts with "Could not resolve API URL".
REGION="us-east-1"

for arg in "$@"; do
  case "$arg" in
    --build-only)
      BUILD_ONLY=1
      ;;
    --env=*)
      ENV="${arg#*=}"
      ;;
    *)
      echo "Unknown arg: $arg" >&2
      exit 64
      ;;
  esac
done

# Stack name prefix matches infra/bin/gosteady.ts naming convention
# (capitalized env prefix).
STACK_PREFIX="GoSteady-$(echo "${ENV:0:1}" | tr '[:lower:]' '[:upper:]')${ENV:1}"
HOSTING_STACK="${STACK_PREFIX}-Hosting"
API_STACK="${STACK_PREFIX}-Api"

echo "▸ Resolving API base URL from ${API_STACK}…"
API_URL=$(aws cloudformation describe-stacks --stack-name "$API_STACK" --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`HttpApiUrl`].OutputValue' \
  --output text 2>/dev/null || true)

if [[ -z "$API_URL" || "$API_URL" == "None" ]]; then
  # Fall back: older CDK revisions exported the URL under ApiUrl / any *Url key.
  API_URL=$(aws cloudformation describe-stacks --stack-name "$API_STACK" --region "$REGION" \
    --query 'Stacks[0].Outputs[?contains(OutputKey, `Url`)].OutputValue | [0]' \
    --output text 2>/dev/null || true)
fi

if [[ -z "$API_URL" || "$API_URL" == "None" ]]; then
  echo "✘ Could not resolve API URL from $API_STACK outputs." >&2
  echo "  Check that the stack is deployed and exposes an *Url* output." >&2
  exit 1
fi

# Strip trailing slash if present.
API_URL="${API_URL%/}"
echo "  API_BASE_URL=$API_URL"

echo "▸ Building Flutter portal (BUILD_MODE=live, --release)…"
flutter build web -t lib/main.dart \
  --dart-define=BUILD_MODE=live \
  --dart-define=API_BASE_URL="$API_URL" \
  --release

if [[ $BUILD_ONLY -eq 1 ]]; then
  echo "✓ Build complete at build/web/. Skipping deploy."
  exit 0
fi

echo "▸ Resolving hosting outputs from ${HOSTING_STACK}…"
BUCKET=$(aws cloudformation describe-stacks --stack-name "$HOSTING_STACK" --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`BucketName`].OutputValue' \
  --output text)
DIST_ID=$(aws cloudformation describe-stacks --stack-name "$HOSTING_STACK" --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`DistributionId`].OutputValue' \
  --output text)
PORTAL_URL=$(aws cloudformation describe-stacks --stack-name "$HOSTING_STACK" --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`PortalUrl`].OutputValue' \
  --output text)

if [[ -z "$BUCKET" || -z "$DIST_ID" ]]; then
  echo "✘ Could not resolve BucketName/DistributionId from $HOSTING_STACK." >&2
  echo "  Has the stack been deployed?" >&2
  exit 1
fi

echo "  Bucket:       $BUCKET"
echo "  Distribution: $DIST_ID"

echo "▸ Syncing build/web/ → s3://$BUCKET/ (protecting /d2c/)…"
# CRITICAL: the D2C app is hosted in the SAME bucket under d2c/. It has no
# presence in build/web/, so a bare `--delete` sweep would wipe the entire
# D2C app on every facility deploy. Exclude d2c/* from both the upload set and
# the delete sweep. (Recoverable via S3 versioning if it ever happens — but
# don't rely on that. See firmware-coordination §C41.3 #3.)
aws s3 sync build/web/ "s3://$BUCKET/" --delete --exclude "d2c/*" --region "$REGION"

echo "▸ Invalidating CloudFront cache /*…"
INVAL_ID=$(aws cloudfront create-invalidation \
  --distribution-id "$DIST_ID" \
  --region "$REGION" \
  --paths "/*" \
  --query 'Invalidation.Id' \
  --output text)
echo "  invalidation: $INVAL_ID"

echo
echo "✓ Deployed: $PORTAL_URL"
echo
echo "  Cache invalidation typically completes within ~60 seconds."
echo "  Verify with:"
echo "    curl -I '$PORTAL_URL'"
