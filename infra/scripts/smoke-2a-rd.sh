#!/usr/bin/env bash
# Phase 2A-RD synthetic smoke test runner.
#
# Hits every endpoint with the test users seeded by
# seed-2a-rd-test-data.py. Records pass/fail per scenario.
#
# Prereqs:
#   1. patient-api Lambda deployed to dev
#   2. seed-2a-rd-test-data.py has been run
#
# Run:
#   bash infra/scripts/smoke-2a-rd.sh
#
# Exits non-zero on any failure; intended to run end-to-end in CI.

set -uo pipefail
REGION="us-east-1"
ENV="dev"
USER_POOL_CLIENT="1q9l9ujtsomf3ugq2tnqvdg6d7"
PASS_PW="GoSteady2026!Pass+"
CLIENT_ID="client_rd_test"
PATIENT_BUSY="pat_rd_busy"
PATIENT_QUIET="pat_rd_quiet"
PATIENT_FAC_B="pat_rd_fac_b"
PATIENT_FAMILY="pat_rd_family"
FACILITY_A="fac_rd_a"
FACILITY_B="fac_rd_b"
CENSUS_A1="cen_rd_a1"
CENSUS_A2="cen_rd_a2"
CENSUS_B1="cen_rd_b1"

# Resolve API URL
API_URL=$(aws apigatewayv2 get-apis --region "$REGION" \
  --query 'Items[?Name==`gosteady-dev-api`].ApiEndpoint' --output text 2>/dev/null)
if [ -z "$API_URL" ]; then
  echo "FATAL: could not resolve API URL"; exit 2
fi
echo "API URL: $API_URL"

# Token cache (~10min refresh)
declare -A TOKENS
get_token() {
  local user="$1"
  if [ -n "${TOKENS[$user]:-}" ]; then
    echo "${TOKENS[$user]}"; return
  fi
  local tok=$(aws cognito-idp initiate-auth --region "$REGION" \
    --auth-flow USER_PASSWORD_AUTH \
    --client-id "$USER_POOL_CLIENT" \
    --auth-parameters "USERNAME=$user,PASSWORD=$PASS_PW" \
    --query 'AuthenticationResult.IdToken' --output text 2>/dev/null)
  TOKENS[$user]="$tok"
  echo "$tok"
}

PASS=0; FAIL=0
declare -a FAIL_LIST=()
run_scenario() {
  local name="$1"; local user="$2"; local method="$3"; local path="$4"
  local expect_status="$5"; local expect_jq="${6:-}"  # optional jq assertion
  local token=$(get_token "$user")
  if [ -z "$token" ] || [ "$token" = "None" ]; then
    echo "  [$name] FAIL: token unavailable for $user"
    FAIL=$((FAIL+1)); FAIL_LIST+=("$name (no token)"); return
  fi
  local response=$(curl -s -w "\n__HTTP_STATUS:%{http_code}" \
    -X "$method" -H "Authorization: Bearer $token" \
    "${API_URL}${path}")
  local body=$(echo "$response" | sed '$d')
  local status=$(echo "$response" | tail -1 | sed 's/__HTTP_STATUS://')

  local ok=true
  if [ "$status" != "$expect_status" ]; then
    ok=false
    echo "  [$name] FAIL: status $status (expected $expect_status)"
    echo "    body: $body" | head -3
  elif [ -n "$expect_jq" ]; then
    if ! echo "$body" | jq -e "$expect_jq" >/dev/null 2>&1; then
      ok=false
      echo "  [$name] FAIL: jq assertion '$expect_jq' failed"
      echo "    body: $body" | head -3
    fi
  fi
  if $ok; then
    echo "  [$name] PASS (HTTP $status)"
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1)); FAIL_LIST+=("$name")
  fi
}

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  Phase 2A-RD synthetic smoke"
echo "════════════════════════════════════════════════════════════"
echo ""

# T1: caregiver in-scope GET /patients/{id}
run_scenario "T1 caregiver gets in-scope patient" \
  "rd-caregiver@test.local" GET "/api/v1/patients/$PATIENT_BUSY" 200 \
  '.patient.patientId == "'"$PATIENT_BUSY"'" and .patient.facilityName != null'

# T2: caregiver OUT_OF_SCOPE (patient in facility B)
run_scenario "T2 caregiver out-of-scope returns 403" \
  "rd-caregiver@test.local" GET "/api/v1/patients/$PATIENT_FAC_B" 403 \
  '.error.code == "OUT_OF_SCOPE"'

# T3: family_viewer not in linkedPatientIds → 404 (existence-leak prevention)
run_scenario "T3 family_viewer non-linked returns 404" \
  "rd-familyviewer@test.local" GET "/api/v1/patients/$PATIENT_QUIET" 404 \
  '.error.code == "PATIENT_NOT_FOUND"'

# T3b: family_viewer linked patient → 200
run_scenario "T3b family_viewer linked patient returns 200" \
  "rd-familyviewer@test.local" GET "/api/v1/patients/$PATIENT_FAMILY" 200 \
  '.patient.patientId == "'"$PATIENT_FAMILY"'"'

# T5: activity 24h (newer than 60-row seed which is over 5 days)
# T5b: activity 7d gives all 60 rows paginated
run_scenario "T5 activity range=7d returns up to 50 sessions" \
  "rd-caregiver@test.local" GET "/api/v1/patients/$PATIENT_BUSY/activity?range=7d" 200 \
  '.sessions | length > 0 and length <= 50'

# T6: pagination — second page via nextCursor
TOKEN=$(get_token rd-caregiver@test.local)
FIRST_PAGE=$(curl -s -H "Authorization: Bearer $TOKEN" \
  "${API_URL}/api/v1/patients/${PATIENT_BUSY}/activity?range=7d&pageSize=50")
CURSOR=$(echo "$FIRST_PAGE" | jq -r '.nextCursor // empty')
if [ -n "$CURSOR" ] && [ "$CURSOR" != "null" ]; then
  SECOND=$(curl -s -w "\n__HTTP_STATUS:%{http_code}" \
    -H "Authorization: Bearer $TOKEN" \
    "${API_URL}/api/v1/patients/${PATIENT_BUSY}/activity?range=7d&pageSize=50&cursor=$CURSOR")
  SEC_STATUS=$(echo "$SECOND" | tail -1 | sed 's/__HTTP_STATUS://')
  if [ "$SEC_STATUS" = "200" ]; then
    echo "  [T6 pagination cursor round-trip] PASS (HTTP 200, cursor consumed)"
    PASS=$((PASS+1))
  else
    echo "  [T6 pagination cursor round-trip] FAIL (HTTP $SEC_STATUS)"
    FAIL=$((FAIL+1)); FAIL_LIST+=("T6 pagination")
  fi
else
  echo "  [T6 pagination cursor round-trip] SKIP (first page wasn't full)"
fi

# T7: invalid range
run_scenario "T7 invalid range=90d returns 400 INVALID_RANGE" \
  "rd-caregiver@test.local" GET "/api/v1/patients/$PATIENT_BUSY/activity?range=90d" 400 \
  '.error.code == "INVALID_RANGE"'

# T8: zero activity
run_scenario "T8 quiet patient zero sessions" \
  "rd-caregiver@test.local" GET "/api/v1/patients/$PATIENT_QUIET/activity?range=7d" 200 \
  '.sessions == []'

# T9: alerts default = unacknowledged
run_scenario "T9 alerts default unacknowledged" \
  "rd-caregiver@test.local" GET "/api/v1/patients/$PATIENT_BUSY/alerts" 200 \
  '.filter == "unacknowledged" and (.alerts | length) > 0'

# T10: alerts status=all
run_scenario "T10 alerts status=all returns all" \
  "rd-caregiver@test.local" GET "/api/v1/patients/$PATIENT_BUSY/alerts?status=all" 200 \
  '.filter == "all" and (.alerts | length) >= 3'

# T11: /me/patients as caregiver
run_scenario "T11 me/patients as caregiver" \
  "rd-caregiver@test.local" GET "/api/v1/me/patients" 200 \
  '.scope.role == "caregiver" and (.patients | length) > 0'

# T12: /me/patients as facility_admin (empty facility scope is "all in client")
run_scenario "T12 me/patients as facility_admin" \
  "rd-facadmin@test.local" GET "/api/v1/me/patients" 200 \
  '.scope.role == "facility_admin"'

# T13: /me/patients as family_viewer
run_scenario "T13 me/patients as family_viewer linked subset" \
  "rd-familyviewer@test.local" GET "/api/v1/me/patients" 200 \
  '.scope.role == "family_viewer"'

# T16: census roster (caregiver in-scope)
run_scenario "T16 census roster in-scope" \
  "rd-caregiver@test.local" GET "/api/v1/facilities/$FACILITY_A/censuses/$CENSUS_A1/patients" 200 \
  '.census.censusId == "'"$CENSUS_A1"'"'

# T17: census roster (caregiver out-of-scope — different census)
run_scenario "T17 census roster out-of-scope" \
  "rd-caregiver@test.local" GET "/api/v1/facilities/$FACILITY_B/censuses/$CENSUS_B1/patients" 404 \
  '.error.code == "FACILITY_NOT_FOUND" or .error.code == "OUT_OF_SCOPE"'

# T18: census roster bad facility id
run_scenario "T18 census bad facility id" \
  "rd-facadmin@test.local" GET "/api/v1/facilities/fac_does_not_exist/censuses/cen_x/patients" 404 \
  '.error.code == "FACILITY_NOT_FOUND"'

# T20: malformed cursor
run_scenario "T20 malformed cursor returns 400" \
  "rd-caregiver@test.local" GET "/api/v1/patients/$PATIENT_BUSY/activity?range=24h&cursor=garbage!!" 400 \
  '.error.code == "INVALID_CURSOR"'

# T25: tenancy violation (caregiver of client_rd_test trying patient that doesn't exist
# in their client — synthesize by querying a known-other-client patient if one exists)
run_scenario "T25 nonexistent patient → 404 (no existence-leak)" \
  "rd-caregiver@test.local" GET "/api/v1/patients/pat_nonexistent_zzz" 404 \
  '.error.code == "PATIENT_NOT_FOUND"'

# T-auth: no token
NOAUTH=$(curl -s -w "\n__HTTP_STATUS:%{http_code}" \
  "${API_URL}/api/v1/me/patients")
NOAUTH_STATUS=$(echo "$NOAUTH" | tail -1 | sed 's/__HTTP_STATUS://')
if [ "$NOAUTH_STATUS" = "401" ]; then
  echo "  [T-auth no token returns 401] PASS"
  PASS=$((PASS+1))
else
  echo "  [T-auth no token returns 401] FAIL (got $NOAUTH_STATUS)"
  FAIL=$((FAIL+1)); FAIL_LIST+=("T-auth no token")
fi

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  Summary: PASS=$PASS  FAIL=$FAIL"
echo "════════════════════════════════════════════════════════════"
if [ $FAIL -gt 0 ]; then
  echo "Failed scenarios:"
  for f in "${FAIL_LIST[@]}"; do echo "  - $f"; done
  exit 1
fi
exit 0
