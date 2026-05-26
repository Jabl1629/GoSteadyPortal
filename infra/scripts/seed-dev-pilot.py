#!/usr/bin/env python3
"""
Seed the GoSteady "dev pilot" tenant — a clean home for the active
firmware dev unit (GS9999999998) so caregivers signing in to
dev.portal.gosteady.co see real device data under a sensibly-named
client/facility/census rather than the historical dtc_smoke_test tenant.

Idempotent — safe to re-run.

Approach C per phase-2b-fac-r-facility-reads.md discussion 2026-05-25:
the existing GS9999999998 → pt_bench_98 DeviceAssignment stays as-is
(no wipe-cmd cycle, no provisioning wait). This script:

  1. Creates Organizations rows for client_dev_pilot (Client, Facility,
     Census)
  2. UpdateItems the existing Patients row pt_bench_98 to flip
     clientId/facilityId/censusId to the new tenant + add timezone +
     prettify displayName
  3. UpdateItems the Device Registry row for GS9999999998 to flip
     owningClientId / owningFacilityId
  4. Creates a Cognito user dev-pilot-caregiver@test.local with the
     correct custom claims (caregiver role, scoped to fac_dev_pilot_a +
     cen_dev_pilot_a1) + Users table row + RoleAssignments row

Run:
    cd infra/scripts
    python3 seed-dev-pilot.py

Test sign-in after running:
    URL:      https://dev.portal.gosteady.co/
    Email:    dev-pilot-caregiver@test.local
    Password: GoSteady2026!Pass+

Activity Series rows already written under dtc_smoke_test's hierarchy
keep their old hierarchy snapshots — they'd surface as old facility name
in any historical query. Activity rows written from this point forward
will get the new client_dev_pilot snapshot. Acceptable for dev work.
"""

from __future__ import annotations

import sys
from datetime import datetime, timezone
from typing import Any

import boto3
from botocore.exceptions import ClientError


REGION = "us-east-1"
ENV = "dev"

# ── Target tenancy (the "after" state) ─────────────────────────────
CLIENT_ID = "client_dev_pilot"
CLIENT_DISPLAY_NAME = "GoSteady Dev Pilot"
FACILITY_ID = "fac_dev_pilot_a"
FACILITY_DISPLAY_NAME = "Dev Pilot Facility"
CENSUS_ID = "cen_dev_pilot_a1"
CENSUS_DISPLAY_NAME = "Bench"
FACILITY_TIMEZONE = "America/Denver"  # matches the dashboard timestamps (UTC-06:00 → MDT)

# ── Patient + device to "move" ─────────────────────────────────────
PATIENT_ID = "pt_bench_98"  # already exists; we update tenancy in place
PATIENT_DISPLAY_NAME = "Bench Patient (GS9999999998)"  # keep current
DEVICE_SERIAL = "GS9999999998"

# ── Caregiver user for portal sign-in ──────────────────────────────
CAREGIVER_EMAIL = "dev-pilot-caregiver@test.local"
CAREGIVER_PASSWORD = "GoSteady2026!Pass+"  # meets 14-char + symbol policy
CAREGIVER_DISPLAY_NAME = "Dev Pilot Caregiver"

# ── Cognito + DDB table names ──────────────────────────────────────
USER_POOL_ID = "us-east-1_ZHbhl19tQ"
ORGANIZATIONS_TABLE = f"gosteady-{ENV}-organizations"
PATIENTS_TABLE = f"gosteady-{ENV}-patients"
DEVICES_TABLE = f"gosteady-{ENV}-devices"
USERS_TABLE = f"gosteady-{ENV}-users"
ROLE_ASSIGNMENTS_TABLE = f"gosteady-{ENV}-role-assignments"


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def main() -> int:
    ddb = boto3.resource("dynamodb", region_name=REGION)
    cog = boto3.client("cognito-idp", region_name=REGION)

    org_table = ddb.Table(ORGANIZATIONS_TABLE)
    patients_table = ddb.Table(PATIENTS_TABLE)
    devices_table = ddb.Table(DEVICES_TABLE)
    users_table = ddb.Table(USERS_TABLE)
    role_table = ddb.Table(ROLE_ASSIGNMENTS_TABLE)

    print(f"=== Seeding GoSteady Dev Pilot tenant (idempotent) ===")
    print(f"  Region: {REGION}")
    print(f"  Env:    {ENV}")
    print()

    # ── 1) Organizations rows ──────────────────────────────────────
    print(f"[1/5] Organizations rows for {CLIENT_ID}")
    org_table.put_item(
        Item={
            "clientId": CLIENT_ID,
            "sk": "META#client",
            "displayName": CLIENT_DISPLAY_NAME,
            "createdAt": now_iso(),
        }
    )
    print(f"  ✓ META#client  displayName={CLIENT_DISPLAY_NAME!r}")
    org_table.put_item(
        Item={
            "clientId": CLIENT_ID,
            "sk": f"facility#{FACILITY_ID}",
            "displayName": FACILITY_DISPLAY_NAME,
            "timezone": FACILITY_TIMEZONE,
            "createdAt": now_iso(),
        }
    )
    print(f"  ✓ facility#{FACILITY_ID}  displayName={FACILITY_DISPLAY_NAME!r}  tz={FACILITY_TIMEZONE}")
    org_table.put_item(
        Item={
            "clientId": CLIENT_ID,
            "sk": f"facility#{FACILITY_ID}#census#{CENSUS_ID}",
            "displayName": CENSUS_DISPLAY_NAME,
            "createdAt": now_iso(),
        }
    )
    print(f"  ✓ facility#{FACILITY_ID}#census#{CENSUS_ID}  displayName={CENSUS_DISPLAY_NAME!r}")

    # ── 2) Move pt_bench_98 to the new tenant ──────────────────────
    print(f"\n[2/5] Moving Patients row {PATIENT_ID} → {CLIENT_ID}/{FACILITY_ID}/{CENSUS_ID}")
    before = patients_table.get_item(Key={"patientId": PATIENT_ID}).get("Item")
    if not before:
        print(f"  ! ERROR: {PATIENT_ID} not found in Patients table. Aborting.", file=sys.stderr)
        return 1
    print(
        f"  before: clientId={before.get('clientId')!r}  facilityId={before.get('facilityId')!r}  "
        f"censusId={before.get('censusId')!r}  timezone={before.get('timezone')!r}"
    )
    patients_table.update_item(
        Key={"patientId": PATIENT_ID},
        UpdateExpression=(
            "SET clientId = :cid, facilityId = :fid, censusId = :ceid, "
            "#tz = :tz, displayName = :dn"
        ),
        ExpressionAttributeNames={"#tz": "timezone"},
        ExpressionAttributeValues={
            ":cid": CLIENT_ID,
            ":fid": FACILITY_ID,
            ":ceid": CENSUS_ID,
            ":tz": FACILITY_TIMEZONE,
            ":dn": PATIENT_DISPLAY_NAME,
        },
    )
    print(
        f"  ✓ after:  clientId={CLIENT_ID!r}  facilityId={FACILITY_ID!r}  censusId={CENSUS_ID!r}  "
        f"timezone={FACILITY_TIMEZONE!r}"
    )

    # ── 3) Flip Device Registry owning fields ──────────────────────
    print(f"\n[3/5] Flipping Device Registry owning fields for {DEVICE_SERIAL}")
    dev_before = devices_table.get_item(Key={"serialNumber": DEVICE_SERIAL}).get("Item")
    if not dev_before:
        print(f"  ! ERROR: {DEVICE_SERIAL} not found in Device Registry. Aborting.", file=sys.stderr)
        return 1
    print(
        f"  before: owningClientId={dev_before.get('owningClientId')!r}  "
        f"owningFacilityId={dev_before.get('owningFacilityId')!r}"
    )
    devices_table.update_item(
        Key={"serialNumber": DEVICE_SERIAL},
        UpdateExpression="SET owningClientId = :cid, owningFacilityId = :fid",
        ExpressionAttributeValues={":cid": CLIENT_ID, ":fid": FACILITY_ID},
    )
    print(
        f"  ✓ after:  owningClientId={CLIENT_ID!r}  owningFacilityId={FACILITY_ID!r}"
    )

    # ── 4) Cognito caregiver user ──────────────────────────────────
    print(f"\n[4/5] Cognito user {CAREGIVER_EMAIL}")
    sub = _ensure_cognito_user(cog)
    if not sub:
        print(f"  ! Cognito user creation failed; aborting", file=sys.stderr)
        return 1

    users_table.put_item(
        Item={
            "userId": sub,
            "clientId": CLIENT_ID,
            "email": CAREGIVER_EMAIL,
            "displayName": CAREGIVER_DISPLAY_NAME,
            "timezone": FACILITY_TIMEZONE,
            "createdAt": now_iso(),
        }
    )
    print(f"  ✓ Users table row  userId={sub}")

    role_table.put_item(
        Item={
            "userId": sub,
            "clientId": CLIENT_ID,
            "role": "caregiver",
            "scopedFacilityIds": {FACILITY_ID},
            "scopedCensusIds": {CENSUS_ID},
            "validFrom": now_iso(),
            "assignedBy": "seed-dev-pilot-script",
        }
    )
    print(f"  ✓ RoleAssignments row  role=caregiver  scope=fac:{FACILITY_ID}/cen:{CENSUS_ID}")

    # ── 5) Summary ─────────────────────────────────────────────────
    print(f"\n[5/5] Summary")
    print(f"  Client:    {CLIENT_ID}  ({CLIENT_DISPLAY_NAME})")
    print(f"  Facility:  {FACILITY_ID}  ({FACILITY_DISPLAY_NAME})")
    print(f"  Census:    {CENSUS_ID}  ({CENSUS_DISPLAY_NAME})")
    print(f"  Patient:   {PATIENT_ID}  ({PATIENT_DISPLAY_NAME})")
    print(f"  Device:    {DEVICE_SERIAL}  (unchanged active assignment)")
    print(f"  Caregiver: {CAREGIVER_EMAIL}")
    print()
    print(f"  Sign in at https://dev.portal.gosteady.co/")
    print(f"  Email:    {CAREGIVER_EMAIL}")
    print(f"  Password: {CAREGIVER_PASSWORD}")
    print()
    print(f"  After sign-in, /dev/me should show:")
    print(f"    clientId={CLIENT_ID}  role=caregiver  facilities={FACILITY_ID}  censuses={CENSUS_ID}")
    print()
    print(f"  Note: 2B-FAC-R isn't shipped yet — the Census view shows the")
    print(f"  'Foundation ready' stub. The /dev/me round-trip is the existing")
    print(f"  end-to-end smoke from 2B-0.")
    return 0


def _ensure_cognito_user(cog: Any) -> str | None:
    """Create the Cognito user idempotently; set perm password; return sub."""
    custom_attrs = [
        {"Name": "email", "Value": CAREGIVER_EMAIL},
        {"Name": "email_verified", "Value": "true"},
        {"Name": "name", "Value": CAREGIVER_DISPLAY_NAME},
        {"Name": "custom:clientId", "Value": CLIENT_ID},
        {"Name": "custom:role", "Value": "caregiver"},
        {"Name": "custom:facilities", "Value": FACILITY_ID},
        {"Name": "custom:censuses", "Value": CENSUS_ID},
        {"Name": "custom:mfa_enrolled", "Value": "false"},
    ]
    try:
        cog.admin_create_user(
            UserPoolId=USER_POOL_ID,
            Username=CAREGIVER_EMAIL,
            UserAttributes=custom_attrs,
            MessageAction="SUPPRESS",
        )
        print(f"  ✓ admin_create_user")
    except ClientError as exc:
        if exc.response["Error"]["Code"] != "UsernameExistsException":
            raise
        # User exists — update attributes to keep them current
        cog.admin_update_user_attributes(
            UserPoolId=USER_POOL_ID,
            Username=CAREGIVER_EMAIL,
            UserAttributes=custom_attrs,
        )
        print(f"  ✓ exists; attributes refreshed")

    # Always set the permanent password (idempotent)
    try:
        cog.admin_set_user_password(
            UserPoolId=USER_POOL_ID,
            Username=CAREGIVER_EMAIL,
            Password=CAREGIVER_PASSWORD,
            Permanent=True,
        )
        print(f"  ✓ permanent password set")
    except ClientError as exc:
        if exc.response["Error"]["Code"] != "InvalidPasswordException":
            raise
        print(f"  ! password rejected by policy — update CAREGIVER_PASSWORD", file=sys.stderr)
        return None

    # Resolve and return the sub
    try:
        u = cog.admin_get_user(UserPoolId=USER_POOL_ID, Username=CAREGIVER_EMAIL)
        for a in u.get("UserAttributes", []):
            if a["Name"] == "sub":
                return a["Value"]
    except ClientError:
        return None
    return None


if __name__ == "__main__":
    sys.exit(main())
