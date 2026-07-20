#!/usr/bin/env python3
"""
Coach memory + transcript review — AI Coach C3 §5.5. CLI-grade daily-review
tool for the trial. Dumps one patient's CoachMemory (summary + facts + goals),
recent chat turns, and recent proactive notes for a human reviewer. Read-only;
run manually. Shows transcript content (PII) to the reviewer by design — it is
never written anywhere (unlike the PII-free Lambda logs).

Usage:
  python3 coach-memory-review.py --patient pat_d2c_xxx [--env dev] [--turns 40]
"""
from __future__ import annotations

import argparse

import boto3
from boto3.dynamodb.conditions import Key


def main() -> None:
    ap = argparse.ArgumentParser(description="AI Coach daily-review dump for one patient.")
    ap.add_argument("--patient", required=True, help="patientId, e.g. pat_d2c_xxx")
    ap.add_argument("--env", default="dev")
    ap.add_argument("--turns", type=int, default=40)
    ap.add_argument("--region", default="us-east-1")
    a = ap.parse_args()

    ddb = boto3.resource("dynamodb", region_name=a.region)
    mem = ddb.Table(f"gosteady-{a.env}-coach-memory")
    msgs = ddb.Table(f"gosteady-{a.env}-coach-messages")

    print(f"=== Coach memory — {a.patient} ({a.env}) ===")
    r = mem.query(KeyConditionExpression=Key("patientId").eq(a.patient))
    summary, facts, goals = "", [], []
    for it in r.get("Items", []):
        sk = str(it.get("itemId", ""))
        if sk == "SUMMARY":
            summary = it.get("text", "")
        elif sk.startswith("GOAL#"):
            goals.append(it)
        elif sk.startswith("PROFILE#"):
            facts.append(it)
    print(f"\nSUMMARY: {summary or '(none)'}")
    print("\nGOALS:")
    for g in goals:
        print(f"  - {g.get('text')}  [{g.get('source')}]")
    print("\nFACTS:")
    for f in facts:
        print(f"  - {f.get('text')}  [{f.get('source')}]")

    print(f"\n=== Recent chat turns (last {a.turns}) ===")
    r = msgs.query(
        KeyConditionExpression=Key("patientId").eq(a.patient) & Key("sk").begins_with("TURN#"),
        ScanIndexForward=False, Limit=a.turns,
    )
    for m in reversed(r.get("Items", [])):
        flags = m.get("flags") or []
        flag = f" [FLAGGED:{','.join(flags)}]" if flags else ""
        print(f"  [{m.get('role')}]{flag} {m.get('text')}")

    r = msgs.query(
        KeyConditionExpression=Key("patientId").eq(a.patient) & Key("sk").begins_with("INBOX#"),
        ScanIndexForward=False, Limit=10,
    )
    inbox = r.get("Items", [])
    if inbox:
        print("\n=== Recent proactive notes ===")
        for m in inbox:
            print(f"  [{m.get('sk')}] ({m.get('themeType')}) {m.get('text')}")


if __name__ == "__main__":
    main()
