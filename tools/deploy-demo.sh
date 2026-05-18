#!/usr/bin/env bash
# Build the facility demo and drop it into the GoSteadyWeb repo as the
# /facilitydemo subdirectory. Push GoSteadyWeb → Netlify auto-deploys to
# https://gosteady.co/facilitydemo/
#
# Usage:
#   tools/deploy-demo.sh                    # build + commit + push
#   tools/deploy-demo.sh --skip-push        # build + commit, hold the push
#   tools/deploy-demo.sh --build-only       # build but leave artifacts in /tmp
#
# Notes:
#   - Designed to be run from the GoSteadyPortal repo root.
#   - Builds in /tmp so the iCloud-synced primary checkout doesn't have to
#     materialize the build/ folder (28 MB of canvaskit + main.dart.js).
#   - Assumes the GoSteadyWeb checkout lives at $WEB_REPO (default below).
#   - Only stages files under facilitydemo/ — never touches anything else
#     that may be in your GoSteadyWeb working tree.
set -euo pipefail

# ── Config ─────────────────────────────────────────────────────────────
WEB_REPO="${WEB_REPO:-$HOME/Documents/GoSteadyWeb}"
BASE_HREF="/facilitydemo/"
SUBDIR="facilitydemo"
TARGET="lib/facility_demo/main_demo.dart"
BUILD_OUT="/tmp/portal-build-out"

# ── Args ───────────────────────────────────────────────────────────────
SKIP_PUSH=0
BUILD_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --skip-push)  SKIP_PUSH=1 ;;
    --build-only) BUILD_ONLY=1 ;;
    -h|--help)
      sed -n '1,/^set /p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Unknown arg: $arg" >&2; exit 2 ;;
  esac
done

# ── Resolve repo roots ────────────────────────────────────────────────
PORTAL_REPO="$(git rev-parse --show-toplevel)"
if [[ ! -f "${PORTAL_REPO}/${TARGET}" ]]; then
  echo "Error: ${TARGET} not in ${PORTAL_REPO}. Run from the gosteady-portal root."
  exit 1
fi
if [[ ! -d "${WEB_REPO}/.git" ]]; then
  echo "Error: ${WEB_REPO} is not a git checkout (expected GoSteadyWeb)."
  echo "Override with WEB_REPO=/path/to/GoSteadyWeb"
  exit 1
fi

PORTAL_BRANCH="$(git -C "${PORTAL_REPO}" rev-parse --abbrev-ref HEAD)"
PORTAL_SHA="$(git -C "${PORTAL_REPO}" rev-parse --short HEAD)"

# ── Build ──────────────────────────────────────────────────────────────
echo "==> Building ${TARGET} with --base-href ${BASE_HREF}"
echo "    portal repo:  ${PORTAL_REPO}"
echo "    portal HEAD:  ${PORTAL_BRANCH} @ ${PORTAL_SHA}"
echo "    output dir:   ${BUILD_OUT}"

rm -rf "${BUILD_OUT}"
(cd "${PORTAL_REPO}" && flutter build web \
  -t "${TARGET}" \
  --base-href "${BASE_HREF}" \
  --output "${BUILD_OUT}")

if [[ "${BUILD_ONLY}" == "1" ]]; then
  echo
  echo "✅ Build complete (build-only). Artifacts: ${BUILD_OUT}"
  exit 0
fi

# ── Drop into GoSteadyWeb ─────────────────────────────────────────────
echo
echo "==> Replacing ${WEB_REPO}/${SUBDIR}/ with new build"
rm -rf "${WEB_REPO:?}/${SUBDIR}"
mkdir -p "${WEB_REPO}/${SUBDIR}"
cp -R "${BUILD_OUT}/." "${WEB_REPO}/${SUBDIR}/"

# ── Commit + push ──────────────────────────────────────────────────────
cd "${WEB_REPO}"
git add "${SUBDIR}/"

if git diff --cached --quiet; then
  echo "==> Nothing changed in ${SUBDIR}/; skipping commit."
else
  echo "==> Committing"
  git -c user.email="deploy@gosteady.local" \
      -c user.name="GoSteady Deploy" \
      commit -m "Deploy facility demo from ${PORTAL_BRANCH} @ ${PORTAL_SHA}"
fi

if [[ "${SKIP_PUSH}" == "1" ]]; then
  echo
  echo "✅ Build + commit complete. Push held (--skip-push)."
  echo "   Run: cd ${WEB_REPO} && git push origin main"
  exit 0
fi

echo "==> Pushing to origin/main"
git push origin main

echo
echo "✅ Deploy complete."
echo "   Live URL: https://gosteady.co/facilitydemo/"
echo "   Netlify will rebuild within ~30–60 seconds."
