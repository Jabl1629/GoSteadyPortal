#!/usr/bin/env python3
"""
One-off cleanup for the signal-alerting shutoff (2026-07-28).

`signal_lost` / `signal_weak` were disabled at the detector
(`_shared/thresholds.SIGNAL_ALERTS_ENABLED`, default off). New rows stop
immediately, and threshold-detector auto-acks any OPEN slot on each
device's next shadow update — but that only reaches devices that still
report. This script closes the remainder:

  1. Acks every remaining unacknowledged `signal_lost` / `signal_weak`
     row as `system:signal_alerts_disabled`, so nothing is left sitting
     in a caregiver's Notification Review panel for a rule that no
     longer exists.
  2. Releases the matching `Patient.openAlerts` slots, so the recurrence
     state machine isn't left holding a claim for a disabled type.

Rows are ACKED, never deleted — the history of past signal conditions
stays queryable and the audit trail is intact.

Run:
    cd infra/scripts
    AWS_REGION=us-east-1 python3 ack-disabled-signal-alerts.py --env=dev
    AWS_REGION=us-east-1 python3 ack-disabled-signal-alerts.py --env=prod

Add --dry-run to report without writing.

Idempotent: safe to re-run. Already-acked rows are skipped; absent
openAlerts slots are a no-op.
"""

from __future__ import annotations

import argparse
import sys
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

SIGNAL_TYPES = ("signal_lost", "signal_weak")
ACTOR = "system:signal_alerts_disabled"


def _utc_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--env", required=True, choices=("dev", "prod"))
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    ddb = boto3.resource("dynamodb", region_name="us-east-1")
    alerts = ddb.Table(f"gosteady-{args.env}-alerts")
    patients = ddb.Table(f"gosteady-{args.env}-patients")

    mode = "DRY RUN" if args.dry_run else "APPLY"
    print(f"[{mode}] {args.env}: acking unacked {'/'.join(SIGNAL_TYPES)} rows\n")

    # ── 1. Ack unacked signal rows ────────────────────────────────────
    scanned = 0
    targets: list[tuple[str, str, str]] = []  # (patientId, sk, alertType)
    kwargs: dict = {}
    while True:
        res = alerts.scan(**kwargs)
        for row in res.get("Items", []):
            scanned += 1
            at = row.get("alertType")
            if at in SIGNAL_TYPES and not row.get("acknowledged", False):
                targets.append((row["patientId"], row["timestamp"], at))
        if "LastEvaluatedKey" not in res:
            break
        kwargs["ExclusiveStartKey"] = res["LastEvaluatedKey"]

    print(f"  scanned {scanned} alert rows; {len(targets)} unacked signal row(s)")
    acked = 0
    for pid, sk, at in targets:
        print(f"    {'would ack' if args.dry_run else 'ack'}  {pid}  {sk}")
        if args.dry_run:
            continue
        try:
            alerts.update_item(
                Key={"patientId": pid, "timestamp": sk},
                UpdateExpression=(
                    "SET acknowledged = :t, acknowledgedAt = :now, "
                    "acknowledgedBy = :who"
                ),
                ConditionExpression="attribute_exists(patientId)",
                ExpressionAttributeValues={
                    ":t": True, ":now": _utc_iso(), ":who": ACTOR,
                },
            )
            acked += 1
        except ClientError as exc:
            print(f"      ! failed: {exc.response['Error']['Code']}")

    # ── 2. Release openAlerts slots for the disabled types ────────────
    released = 0
    pkwargs: dict = {}
    while True:
        res = patients.scan(
            ProjectionExpression="patientId, openAlerts", **pkwargs
        )
        for p in res.get("Items", []):
            open_map = p.get("openAlerts") or {}
            stale = [t for t in SIGNAL_TYPES if t in open_map]
            if not stale:
                continue
            print(
                f"    {'would release' if args.dry_run else 'release'} "
                f"openAlerts{stale} on {p['patientId']}"
            )
            if args.dry_run:
                continue
            try:
                patients.update_item(
                    Key={"patientId": p["patientId"]},
                    UpdateExpression="REMOVE " + ", ".join(
                        f"openAlerts.#t{i}" for i in range(len(stale))
                    ),
                    ExpressionAttributeNames={
                        f"#t{i}": t for i, t in enumerate(stale)
                    },
                )
                released += len(stale)
            except ClientError as exc:
                print(f"      ! failed: {exc.response['Error']['Code']}")
        if "LastEvaluatedKey" not in res:
            break
        pkwargs["ExclusiveStartKey"] = res["LastEvaluatedKey"]

    print(
        f"\n[{mode}] {args.env}: "
        f"{acked} row(s) acked, {released} openAlerts slot(s) released"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
