#!/usr/bin/env python3
"""
One-off migration script for the alert recurrence policy
(docs/specs/2026-05-26-alert-recurrence-policy.md).

Before the policy deployed, threshold-detector + behavioral-detector
were writing a new continuous-condition alert (battery_critical,
battery_low, signal_lost, signal_weak, device_offline, device_silent)
on every detector firing while the condition persisted. This left a
backlog of duplicate unacked rows — most prominently 45 unacked
`battery_critical` rows on pt_bench_98 driven by the bench unit's
no-SoC-fuel-gauge AAs reporting `battery_pct=0`.

This script:

  1. Scans Alert History (PK=patientId) for every patient. For each
     continuous-condition alert type, **acks all rows except the most
     recent** (by `eventTimestamp`) as `system:migration_2026_05_26`.
     The most-recent row is left unacked so it can either be (a)
     acked by the caregiver via the portal, or (b) auto-acked by
     the detector on the next clear-condition observation.

  2. For each patient with any remaining unacked continuous-condition
     alert, sets `Patient.openAlerts[alertType] = {sk, openedAt}` so
     the post-deploy detector path treats that row as the current
     open slot.

  3. For all patients without any remaining unacked continuous-
     condition alerts, initializes `Patient.openAlerts = {}` so the
     attribute exists on every active patient (defensive — the claim
     helper's `if_not_exists(openAlerts, :empty)` handles missing
     field, but pre-initializing makes inspection easier).

Run:
    cd infra/scripts
    AWS_REGION=us-east-1 python3 ack-pre-recurrence-policy-alerts.py --env=dev

Idempotent: safe to re-run. Already-acked rows are not touched. Patient
openAlerts entries already pointing at the most-recent unacked row are
left alone.
"""

from __future__ import annotations

import argparse
import sys
from datetime import datetime, timezone
from typing import Any, Iterable

import boto3
from botocore.exceptions import ClientError

CONTINUOUS_ALERT_TYPES = frozenset({
    "battery_critical",
    "battery_low",
    "signal_lost",
    "signal_weak",
    "device_offline",
    "device_silent",
})

MIGRATION_ACTOR = "system:migration_2026_05_26"


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _scan_all(table) -> Iterable[dict[str, Any]]:
    last_key: dict | None = None
    while True:
        kwargs: dict[str, Any] = {}
        if last_key:
            kwargs["ExclusiveStartKey"] = last_key
        resp = table.scan(**kwargs)
        yield from resp.get("Items", [])
        last_key = resp.get("LastEvaluatedKey")
        if not last_key:
            break


def main(env: str, dry_run: bool) -> int:
    ddb = boto3.resource("dynamodb")
    patients_tbl = ddb.Table(f"gosteady-{env}-patients")
    alerts_tbl = ddb.Table(f"gosteady-{env}-alerts")

    now_iso = _now_iso()

    print(f"▸ Scanning Patients (env={env})…")
    patient_ids: list[str] = []
    for row in _scan_all(patients_tbl):
        pid = row.get("patientId")
        if isinstance(pid, str):
            patient_ids.append(pid)
    print(f"  {len(patient_ids)} patient rows")

    open_alerts_to_set: dict[str, dict[str, dict]] = {}  # patientId -> {alertType -> {sk, openedAt}}
    ack_count = 0

    for pid in patient_ids:
        # Query alerts by patientId, descending by SK.
        resp = alerts_tbl.query(
            KeyConditionExpression="patientId = :p",
            ExpressionAttributeValues={":p": pid},
            ScanIndexForward=False,  # newest first
        )
        rows = resp.get("Items", [])

        # Group by alertType, keep the most-recent unacked per type.
        most_recent_unacked: dict[str, dict] = {}
        for row in rows:
            atype = row.get("alertType")
            if not isinstance(atype, str) or atype not in CONTINUOUS_ALERT_TYPES:
                continue
            if row.get("acknowledged") is True:
                continue
            if atype not in most_recent_unacked:
                most_recent_unacked[atype] = row

        # Ack everything OTHER than the most-recent per type.
        for row in rows:
            atype = row.get("alertType")
            if not isinstance(atype, str) or atype not in CONTINUOUS_ALERT_TYPES:
                continue
            if row.get("acknowledged") is True:
                continue
            keeper = most_recent_unacked.get(atype)
            sk = row.get("timestamp")
            if keeper is not None and keeper.get("timestamp") == sk:
                continue
            if dry_run:
                print(f"  [DRY] would ack {pid} / {sk} (type={atype})")
                ack_count += 1
                continue
            try:
                alerts_tbl.update_item(
                    Key={"patientId": pid, "timestamp": sk},
                    UpdateExpression=(
                        "SET acknowledged = :true, "
                        "acknowledgedBy = :who, "
                        "acknowledgedAt = :now"
                    ),
                    ConditionExpression="acknowledged = :false",
                    ExpressionAttributeValues={
                        ":true": True,
                        ":false": False,
                        ":who": MIGRATION_ACTOR,
                        ":now": now_iso,
                    },
                )
                ack_count += 1
            except ClientError as exc:
                if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
                    # Already acked between our read and write — fine.
                    continue
                raise

        # Capture the kept-unacked rows so we can populate Patient.openAlerts.
        if most_recent_unacked:
            per_type: dict[str, dict] = {}
            for atype, row in most_recent_unacked.items():
                sk = row.get("timestamp")
                opened_at = row.get("eventTimestamp") or row.get("createdAt") or now_iso
                if isinstance(sk, str) and isinstance(opened_at, str):
                    per_type[atype] = {"sk": sk, "openedAt": opened_at}
            if per_type:
                open_alerts_to_set[pid] = per_type

    print(f"  acked {ack_count} duplicate alerts (kept most-recent per type)")
    print(f"  initializing Patient.openAlerts for {len(patient_ids)} patient rows…")

    for pid in patient_ids:
        record = open_alerts_to_set.get(pid, {})
        if dry_run:
            print(f"  [DRY] would SET {pid}.openAlerts = {record}")
            continue
        try:
            # Always set; overrides any stale map. Safe for first-run + re-run.
            patients_tbl.update_item(
                Key={"patientId": pid},
                UpdateExpression="SET openAlerts = :v",
                ExpressionAttributeValues={":v": record},
            )
        except ClientError:
            print(f"  ! failed to set openAlerts on {pid}", file=sys.stderr)
            raise

    if not dry_run:
        print("✓ migration complete")
    else:
        print("✓ dry-run complete (no writes performed)")
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--env", default="dev", help="Environment (dev|prod). Default: dev")
    parser.add_argument("--dry-run", action="store_true", help="Print actions; don't write")
    args = parser.parse_args()
    sys.exit(main(args.env, args.dry_run))
