#!/usr/bin/env bash
# Build the facility demo and force-push it to the gh-pages branch so
# GitHub Pages serves the latest at https://jabl1629.github.io/GoSteadyPortal/
#
# Usage:
#   tools/deploy-demo.sh
#
# Notes:
#   - Designed to be run from the repo root.
#   - Uses a temporary clone in /tmp/gh-pages-deploy so the iCloud-synced
#     primary checkout is never put on the orphan branch (which would force
#     iCloud to reindex thousands of files unnecessarily).
#   - Pages picks up the push within ~30–90 s.
set -euo pipefail

REPO_OWNER="Jabl1629"
REPO_NAME="GoSteadyPortal"
REPO_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}.git"
BASE_HREF="/${REPO_NAME}/"
DEPLOY_TMP="/tmp/gh-pages-deploy"

# Resolve the repo root regardless of where the script was invoked from.
cd "$(git rev-parse --show-toplevel)"
REPO_ROOT="$(pwd)"
BUILD_OUT="${REPO_ROOT}/build/web-facility-demo"
TARGET="lib/facility_demo/main_demo.dart"

if [[ ! -f "${TARGET}" ]]; then
  echo "Error: ${TARGET} not found. Run from the gosteady-portal root."
  exit 1
fi

echo "==> Building ${TARGET} with --base-href ${BASE_HREF}"
rm -rf "${BUILD_OUT}"
flutter build web -t "${TARGET}" --base-href "${BASE_HREF}" --output "${BUILD_OUT}"

echo "==> Preparing fresh clone at ${DEPLOY_TMP}"
rm -rf "${DEPLOY_TMP}"
git clone --depth 1 "${REPO_URL}" "${DEPLOY_TMP}"

echo "==> Resetting to orphan gh-pages branch"
cd "${DEPLOY_TMP}"
git checkout --orphan gh-pages
git rm -rf . >/dev/null

echo "==> Copying build artifacts to root + adding .nojekyll"
cp -R "${BUILD_OUT}/." .
touch .nojekyll

COMMIT_SHA="$(git -C "${REPO_ROOT}" rev-parse --short HEAD)"
COMMIT_BRANCH="$(git -C "${REPO_ROOT}" rev-parse --abbrev-ref HEAD)"
COMMIT_MSG="Deploy facility demo from ${COMMIT_BRANCH} @ ${COMMIT_SHA}"

git add -A
git -c user.email="deploy@gosteady.local" -c user.name="GoSteady Deploy" \
  commit -m "${COMMIT_MSG}"

echo "==> Force-pushing gh-pages"
git push -f origin gh-pages

echo
echo "✅ Deploy complete."
echo "   Live URL: https://${REPO_OWNER,,}.github.io/${REPO_NAME}/"
echo "   GitHub Pages will rebuild within ~30–90 seconds."
echo
echo "Cleaning up ${DEPLOY_TMP}…"
cd "${REPO_ROOT}"
rm -rf "${DEPLOY_TMP}"
