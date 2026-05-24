#!/usr/bin/env python3
"""
Seed test data for Phase 2A-RD synthetic smoke tests.

Idempotent — safe to re-run. Creates:

  Test client "client_rd_test" (a 2nd client distinct from dtc_smoke_test
  for cross-client TENANCY_VIOLATION proofs)
    - Organizations: META#client + 2 facilities + 2 censuses per facility
    - 4 patients spanning the 2 censuses + 1 patient in a different
      facility (for OUT_OF_SCOPE proofs)
    - 1 patient with 60 synthetic Activity Series rows over ~5 days
      (proves T6 pagination boundary)
    - 1 patient with 3 alerts (2 unacked, 1 acked) for T9/T10
    - 1 caregiver Cognito user + RoleAssignments row (scope = first census)
    - 1 facility_admin Cognito user + RoleAssignments row
    - 1 client_admin Cognito user + RoleAssignments row
    - 1 family_viewer Cognito user + RoleAssignments row with
      linkedPatientIds = the 60-row patient

Requires AWS creds in env (uses default profile). Region us-east-1.

Run:
    cd infra/scripts
    python3 seed-2a-rd-test-data.py

Test users (created if absent; password unchanged if exists):
  rd-caregiver@test.local         PW: GoSteady2026!Pass+
  rd-facadmin@test.local          PW: GoSteady2026!Pass+
  rd-clientadmin@test.local       PW: GoSteady2026!Pass+
  rd-familyviewer@test.local      PW: GoSteady2026!Pass+
"""

from __future__ import annotations

import json
import os
import sys
import time
import uuid
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from typing import Any

import boto3
from botocore.exceptions import ClientError


def D(x: float | int) -> Decimal:
    """Convert float→Decimal via str() to avoid binary-float precision loss."""
    return Decimal(str(x))

REGION = "us-east-1"
ENV = "dev"

# Tables (mirror infra/lib/config.ts naming)
PATIENTS_TABLE = f"gosteady-{ENV}-patients"
ACTIVITY_TABLE = f"gosteady-{ENV}-activity"
ALERTS_TABLE = f"gosteady-{ENV}-alerts"
ORGANIZATIONS_TABLE = f"gosteady-{ENV}-organizations"
ROLE_ASSIGNMENTS_TABLE = f"gosteady-{ENV}-role-assignments"
USERS_TABLE = f"gosteady-{ENV}-users"
DEVICE_ASSIGNMENTS_TABLE = f"gosteady-{ENV}-device-assignments"
DEVICES_TABLE = f"gosteady-{ENV}-devices"

USER_POOL_ID = "us-east-1_ZHbhl19tQ"
PORTAL_CUSTOMER_CLIENT_ID = "1q9l9ujtsomf3ugq2tnqvdg6d7"

# Test client + hierarchy
CLIENT_ID = "client_rd_test"
FACILITY_A = "fac_rd_a"
FACILITY_B = "fac_rd_b"
CENSUS_A1 = "cen_rd_a1"
CENSUS_A2 = "cen_rd_a2"
CENSUS_B1 = "cen_rd_b1"

# Patients
PATIENT_BUSY = "pat_rd_busy"      # the 60-activity-row patient (also for alerts)
PATIENT_QUIET = "pat_rd_quiet"    # no activity rows
PATIENT_FAC_B = "pat_rd_fac_b"    # in facility B (out-of-scope for the caregiver)
PATIENT_FAMILY = "pat_rd_family"  # linked to family_viewer

# Test users
USERS = {
    "rd-caregiver@test.local": {
        "role": "caregiver",
        "facilities": [FACILITY_A],
        "censuses": [CENSUS_A1],
        "displayName": "RD Test Caregiver",
        "mfa_enrolled": "false",  # caregiver doesn't require MFA per Phase 0A-rev A7
    },
    "rd-facadmin@test.local": {
        "role": "facility_admin",
        "facilities": [FACILITY_A],
        "censuses": [],
        "displayName": "RD Test Facility Admin",
        "mfa_enrolled": "true",  # facility_admin requires MFA — synthetic stamp for tests
    },
    "rd-clientadmin@test.local": {
        "role": "client_admin",
        "facilities": [],
        "censuses": [],
        "displayName": "RD Test Client Admin",
        "mfa_enrolled": "true",  # client_admin requires MFA — synthetic stamp for tests
    },
    "rd-familyviewer@test.local": {
        "role": "family_viewer",
        "facilities": [],
        "censuses": [],
        "displayName": "RD Test Family Viewer",
        "linked_patients": [PATIENT_FAMILY, PATIENT_BUSY],
        "mfa_enrolled": "false",
    },
}

PASSWORD = "GoSteady2026!Pass+"

# ──────────────────────────────────────────────────────────────────────


def now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def main() -> int:
    ddb = boto3.resource("dynamodb", region_name=REGION)
    cog = boto3.client("cognito-idp", region_name=REGION)

    org_table = ddb.Table(ORGANIZATIONS_TABLE)
    patients_table = ddb.Table(PATIENTS_TABLE)
    activity_table = ddb.Table(ACTIVITY_TABLE)
    alerts_table = ddb.Table(ALERTS_TABLE)
    role_table = ddb.Table(ROLE_ASSIGNMENTS_TABLE)
    users_table = ddb.Table(USERS_TABLE)

    print("=== 2A-RD test data seed ===")

    # 1) Organizations hierarchy
    print(f"\n[1/6] Organizations: client={CLIENT_ID}, 2 facilities, 3 censuses")
    org_table.put_item(Item={
        "clientId": CLIENT_ID, "sk": "META#client",
        "type": "client", "displayName": "RD Test Client",
        "status": "active", "createdAt": now_iso(),
        "metadata": {"purpose": "Phase 2A-RD synthetic smoke fixtures"},
    })
    for fid, fname in [(FACILITY_A, "RD Test Facility A"), (FACILITY_B, "RD Test Facility B")]:
        org_table.put_item(Item={
            "clientId": CLIENT_ID, "sk": f"facility#{fid}",
            "type": "facility", "parentId": CLIENT_ID,
            "displayName": fname, "status": "active",
            "createdAt": now_iso(),
        })
    for fid, cid, cname in [
        (FACILITY_A, CENSUS_A1, "RD Test Census A1 (East Wing)"),
        (FACILITY_A, CENSUS_A2, "RD Test Census A2 (West Wing)"),
        (FACILITY_B, CENSUS_B1, "RD Test Census B1 (Memory Care)"),
    ]:
        org_table.put_item(Item={
            "clientId": CLIENT_ID, "sk": f"facility#{fid}#census#{cid}",
            "type": "census", "parentId": fid,
            "displayName": cname, "status": "active",
            "createdAt": now_iso(),
        })

    # 2) Patients
    print(f"\n[2/6] Patients: 4 patients across 3 censuses")
    patient_specs = [
        (PATIENT_BUSY, "Jane D.", CENSUS_A1, FACILITY_A),
        (PATIENT_QUIET, "John Q.", CENSUS_A1, FACILITY_A),
        (PATIENT_FAC_B, "Mary B.", CENSUS_B1, FACILITY_B),
        (PATIENT_FAMILY, "Bob F.", CENSUS_A2, FACILITY_A),
    ]
    for pid, name, census, facility in patient_specs:
        patients_table.put_item(Item={
            "patientId": pid,
            "clientId": CLIENT_ID,
            "facilityId": facility,
            "censusId": census,
            "displayName": name,
            "status": "active",
            "timezone": "America/Los_Angeles",
            "status_patientId": f"active_{pid}",  # GSI SK format
            "createdAt": now_iso(),
        })

    # 3) Activity rows on PATIENT_BUSY (60 sessions over 5 days, ~12/day)
    print(f"\n[3/6] Activity: 60 rows on {PATIENT_BUSY} (5 days, ~12/day)")
    base = datetime.now(timezone.utc) - timedelta(days=5)
    activity_count = 0
    for i in range(60):
        # Spread across 5 days, ~12 per day, 90-min gaps
        session_start = base + timedelta(minutes=90 * i)
        session_end = session_start + timedelta(minutes=15 + (i % 10))
        ts = session_end.strftime("%Y-%m-%dT%H:%M:%SZ")
        date_local = session_end.strftime("%Y-%m-%d")
        expires_at = int((session_end + timedelta(days=395)).timestamp())
        activity_table.put_item(Item={
            "patientId": PATIENT_BUSY,
            "timestamp": ts,
            "sessionStart": session_start.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "sessionEnd": ts,
            "date": date_local,
            "timezone": "America/Los_Angeles",
            "steps": 100 + (i * 7) % 250,
            "distanceFt": D(200.0 + (i * 11.3)),
            "activeMinutes": 5 + (i % 12),
            "deviceSerial": "GS0000099998",  # synthetic dev unit alias
            "clientId": CLIENT_ID,
            "facilityId": FACILITY_A,
            "censusId": CENSUS_A1,
            "source": "device",
            "ingestedAt": ts,
            "expiresAt": expires_at,
            "roughnessR": D(round(0.02 + (i % 7) * 0.05, 4)),
            "surfaceClass": "indoor" if i % 4 != 0 else "outdoor",
            "firmwareVersion": "0.11.0-wipe-cmd",
        })
        activity_count += 1

    # 4) Alerts on PATIENT_BUSY (2 unacked, 1 acked)
    print(f"\n[4/6] Alerts: 3 rows on {PATIENT_BUSY} (2 unacked, 1 acked)")
    alerts = [
        {
            "eventTimestamp": (datetime.now(timezone.utc) - timedelta(hours=2)).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "alertType": "battery_critical",
            "severity": "critical",
            "source": "cloud",
            "acknowledged": False,
            "data": {"batteryPct": D("0.04")},
        },
        {
            "eventTimestamp": (datetime.now(timezone.utc) - timedelta(hours=12)).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "alertType": "signal_weak",
            "severity": "info",
            "source": "cloud",
            "acknowledged": False,
            "data": {"rsrpDbm": -115},
        },
        {
            "eventTimestamp": (datetime.now(timezone.utc) - timedelta(days=1)).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "alertType": "battery_low",
            "severity": "warning",
            "source": "cloud",
            "acknowledged": True,
            "acknowledgedAt": now_iso(),
            "acknowledgedBy": "caregiver_test_user",
            "data": {"batteryPct": D("0.08")},
        },
    ]
    for a in alerts:
        sk = f"{a['eventTimestamp']}#{a['alertType']}"
        expires_at = int((datetime.now(timezone.utc) + timedelta(days=730)).timestamp())
        alerts_table.put_item(Item={
            "patientId": PATIENT_BUSY,
            "timestamp": sk,
            "eventTimestamp": a["eventTimestamp"],
            "alertType": a["alertType"],
            "severity": a["severity"],
            "source": a["source"],
            "acknowledged": a["acknowledged"],
            "acknowledgedAt": a.get("acknowledgedAt"),
            "acknowledgedBy": a.get("acknowledgedBy"),
            "data": a["data"],
            "deviceSerial": "GS0000099998",
            "clientId": CLIENT_ID,
            "facilityId": FACILITY_A,
            "censusId": CENSUS_A1,
            "createdAt": now_iso(),
            "expiresAt": expires_at,
        })

    # 5) Cognito users + Users + RoleAssignments
    print(f"\n[5/6] Cognito + Users + RoleAssignments: {len(USERS)} test users")
    for email, spec in USERS.items():
        cog_sub = _ensure_cognito_user(cog, email, spec)
        if not cog_sub:
            print(f"  ! {email}: skip (sub unresolved)")
            continue
        # Users table row
        users_table.put_item(Item={
            "userId": cog_sub,
            "clientId": CLIENT_ID,
            "email": email,
            "displayName": spec["displayName"],
            "timezone": "America/Los_Angeles",
            "createdAt": now_iso(),
        })
        # RoleAssignments row
        item: dict[str, Any] = {
            "userId": cog_sub,
            "clientId": CLIENT_ID,
            "role": spec["role"],
            "validFrom": now_iso(),
            "assignedBy": "seed-2a-rd-script",
        }
        if spec.get("facilities"):
            item["scopedFacilityIds"] = set(spec["facilities"])
        if spec.get("censuses"):
            item["scopedCensusIds"] = set(spec["censuses"])
        if spec.get("linked_patients"):
            item["linkedPatientIds"] = set(spec["linked_patients"])
        role_table.put_item(Item=item)
        print(f"  ✓ {email}  role={spec['role']}  sub={cog_sub}")

    # 6) Summary
    print("\n[6/6] Summary")
    print(f"  Client: {CLIENT_ID}")
    print(f"  Facilities: {FACILITY_A}, {FACILITY_B}")
    print(f"  Censuses: {CENSUS_A1}, {CENSUS_A2} (facility A), {CENSUS_B1} (facility B)")
    print(f"  Patients: {[p[0] for p in patient_specs]}")
    print(f"  Activity rows on {PATIENT_BUSY}: {activity_count}")
    print(f"  Alerts on {PATIENT_BUSY}: 3 (2 unacked, 1 acked)")
    print(f"  Users: {list(USERS.keys())}  password: {PASSWORD}")
    print("\nObtain a token:")
    print(f"  aws cognito-idp initiate-auth --region us-east-1 \\")
    print(f"    --auth-flow USER_PASSWORD_AUTH \\")
    print(f"    --client-id {PORTAL_CUSTOMER_CLIENT_ID} \\")
    print(f"    --auth-parameters USERNAME=rd-caregiver@test.local,PASSWORD={PASSWORD!r}")
    return 0


def _ensure_cognito_user(cog: Any, email: str, spec: dict[str, Any]) -> str | None:
    """Create the Cognito user idempotently; set perm password; return sub."""
    custom_attrs = [
        {"Name": "email", "Value": email},
        {"Name": "email_verified", "Value": "true"},
        {"Name": "custom:clientId", "Value": CLIENT_ID},
        {"Name": "custom:role", "Value": spec["role"]},
        {"Name": "custom:facilities", "Value": ",".join(spec.get("facilities") or [])},
        {"Name": "custom:censuses", "Value": ",".join(spec.get("censuses") or [])},
        {"Name": "custom:mfa_enrolled", "Value": spec.get("mfa_enrolled", "false")},
    ]
    try:
        cog.admin_create_user(
            UserPoolId=USER_POOL_ID,
            Username=email,
            UserAttributes=custom_attrs,
            MessageAction="SUPPRESS",
        )
    except ClientError as exc:
        if exc.response["Error"]["Code"] != "UsernameExistsException":
            raise
        # Update attributes (in case role/scope changed)
        try:
            cog.admin_update_user_attributes(
                UserPoolId=USER_POOL_ID,
                Username=email,
                UserAttributes=custom_attrs,
            )
        except ClientError:
            pass

    # Set permanent password
    try:
        cog.admin_set_user_password(
            UserPoolId=USER_POOL_ID,
            Username=email,
            Password=PASSWORD,
            Permanent=True,
        )
    except ClientError as exc:
        # Bail loud if the password policy rejects — script will need an update
        print(f"  ! admin_set_user_password failed for {email}: {exc}")

    # Read sub
    try:
        u = cog.admin_get_user(UserPoolId=USER_POOL_ID, Username=email)
        for a in u.get("UserAttributes", []):
            if a["Name"] == "sub":
                return a["Value"]
    except ClientError as exc:
        print(f"  ! admin_get_user failed for {email}: {exc}")
    return None


if __name__ == "__main__":
    sys.exit(main())
