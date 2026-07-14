#!/usr/bin/env bash
# Create a GoSteady INTERNAL user (internal_admin / internal_support) — the
# identity behind the fleet ops CLI's *write* path (provision / end / reset / …).
#
# ⚠ OPERATOR-run by design. This creates a privileged, cross-tenant account,
#   sets its password, and grants internal authority. Run it yourself.
#
# What a working internal token requires (from cognito-pre-token/handler.py):
#   1. A Cognito user in the facility pool with custom:mfa_enrolled=true.
#   2. A permanent password.
#   3. A RoleAssignments row keyed by the user's Cognito username:
#        { userId: <username>, clientId: "_internal", role: <role> }
#      — the token's custom:role / custom:clientId come from THIS row, not
#      from the Cognito user attributes. No row ⇒ NO_ROLE_ASSIGNED, auth denied.
#
# ⚠ MFA CAVEAT (read this): the pool is MFA=OPTIONAL and the Pre-Token Lambda
#   currently gates internal roles on the custom:mfa_enrolled ATTRIBUTE — real
#   TOTP enrollment is a deferred Phase-2B item (see the handler comment). This
#   script sets the attribute so the token works, but that is NOT real MFA yet.
#   For a hardened prod internal_admin, additionally enroll a TOTP factor
#   (associate-software-token + verify-software-token + admin-set-user-mfa-
#   preference). NOTE: enforcing per-user TOTP makes USER_PASSWORD_AUTH return a
#   SOFTWARE_TOKEN_MFA challenge, so the CLI's auto-mint stops working
#   non-interactively — you'd copy a token from an authenticated browser
#   session instead. For the pilot, attribute-based is the frictionless path.
#
# Usage:
#   ./tools/create-internal-user.sh <email> [dev|prod] [internal_admin|internal_support]
#   ./tools/create-internal-user.sh ops@gosteady.co prod internal_admin
set -euo pipefail

EMAIL="${1:?usage: create-internal-user.sh <email> [dev|prod] [internal_admin|internal_support]}"
ENVN="${2:-dev}"
ROLE="${3:-internal_admin}"
REGION=us-east-1
ACCOUNT=460223323193
INTERNAL_CLIENT_ID=_internal

case "$ENVN" in dev|prod) ;; *) echo "env must be dev|prod" >&2; exit 1;; esac
case "$ROLE" in internal_admin|internal_support) ;; *) echo "role must be internal_admin|internal_support" >&2; exit 1;; esac
ENV_CAP="$(tr '[:lower:]' '[:upper:]' <<< "${ENVN:0:1}")${ENVN:1}"

echo "▸ Target: env=$ENVN role=$ROLE email=$EMAIL"

# ── Guard the account ─────────────────────────────────────────────
acct="$(aws sts get-caller-identity --query Account --output text)"
[ "$acct" = "$ACCOUNT" ] || { echo "wrong AWS account: $acct (expected $ACCOUNT)" >&2; exit 1; }

# ── Resolve pool / client / table from the Auth stack ─────────────
outs="$(aws cloudformation describe-stacks --region "$REGION" \
  --stack-name "GoSteady-${ENV_CAP}-Auth" \
  --query "Stacks[0].Outputs[?OutputKey=='UserPoolId'||OutputKey=='UserPoolClientId'].[OutputKey,OutputValue]" \
  --output text)"
POOL="$(awk '/UserPoolId/{print $2}' <<< "$outs")"
CLIENT="$(awk '/UserPoolClientId/{print $2}' <<< "$outs")"
TABLE="gosteady-${ENVN}-role-assignments"
[ -n "$POOL" ] && [ -n "$CLIENT" ] || { echo "could not resolve pool/client from GoSteady-${ENV_CAP}-Auth" >&2; exit 1; }
echo "▸ pool=$POOL client=$CLIENT table=$TABLE"

# ── Create the user (idempotent) ──────────────────────────────────
if aws cognito-idp admin-get-user --region "$REGION" --user-pool-id "$POOL" --username "$EMAIL" >/dev/null 2>&1; then
  echo "▸ user already exists — ensuring attributes + role row"
  aws cognito-idp admin-update-user-attributes --region "$REGION" --user-pool-id "$POOL" --username "$EMAIL" \
    --user-attributes Name=custom:mfa_enrolled,Value=true Name=email_verified,Value=true >/dev/null
  USERNAME="$(aws cognito-idp admin-get-user --region "$REGION" --user-pool-id "$POOL" --username "$EMAIL" --query Username --output text)"
else
  USERNAME="$(aws cognito-idp admin-create-user --region "$REGION" --user-pool-id "$POOL" \
    --username "$EMAIL" --message-action SUPPRESS \
    --user-attributes Name=email,Value="$EMAIL" Name=email_verified,Value=true Name=custom:mfa_enrolled,Value=true \
    --query 'User.Username' --output text)"
  echo "▸ created user (username=$USERNAME)"
fi

# ── Set a permanent password (you type it; it never leaves your shell) ──
read -r -s -p "Set a permanent password for $EMAIL: " PW; echo
aws cognito-idp admin-set-user-password --region "$REGION" --user-pool-id "$POOL" \
  --username "$USERNAME" --password "$PW" --permanent
echo "▸ password set"

# ── Grant authority: RoleAssignments row (pre-token reads this) ───
aws dynamodb put-item --region "$REGION" --table-name "$TABLE" --item \
  "{\"userId\":{\"S\":\"$USERNAME\"},\"clientId\":{\"S\":\"$INTERNAL_CLIENT_ID\"},\"role\":{\"S\":\"$ROLE\"}}"
echo "▸ RoleAssignments row written (userId=$USERNAME role=$ROLE clientId=_internal)"

# ── Verify the whole chain: mint a token + decode the claims ──────
echo "▸ verifying token mint (USER_PASSWORD_AUTH)…"
auth="$(aws cognito-idp initiate-auth --region "$REGION" --client-id "$CLIENT" \
  --auth-flow USER_PASSWORD_AUTH --auth-parameters USERNAME="$EMAIL",PASSWORD="$PW" --output json 2>&1)" || {
    echo "  initiate-auth failed: $auth" >&2; exit 1; }
if grep -q ChallengeName <<< "$auth"; then
  echo "  ⚠ got an auth challenge (MFA?) — token can't be auto-minted; use a browser-copied token." >&2
else
  python3 - "$auth" <<'PY'
import sys, json, base64
d = json.loads(sys.argv[1])
idt = d.get("AuthenticationResult", {}).get("IdToken")
if not idt:
    print("  no IdToken returned"); sys.exit(1)
p = idt.split(".")[1]; p += "=" * (-len(p) % 4)
c = json.loads(base64.urlsafe_b64decode(p))
print(f"  ✓ token OK — custom:role={c.get('custom:role')} custom:clientId={c.get('custom:clientId')} "
      f"mfa={c.get('custom:mfa_enrolled')} aud={c.get('aud')}")
PY
fi

cat <<EOF

✅ Internal user ready ($ENVN). Use it with the fleet CLI for WRITES:

  # Auto-mint per run (the CLI mints a fresh token each invocation):
  export GOSTEADY_ENV=$ENVN
  export GOSTEADY_USER='$EMAIL'
  export GOSTEADY_PASS='<the password you just set>'
  export GOSTEADY_CLIENT_ID='$CLIENT'

  ./tools/fleet.py --env $ENVN ls                       # audited read via the API
  ./tools/fleet.py --env $ENVN reset GS0002000001       # a write (audited)

  # Or paste a token instead of user/pass:  export GOSTEADY_TOKEN='eyJ...'

Reminder: this is attribute-based MFA (Phase-2B will wire real TOTP). See the
header of this script before hardening.
EOF
