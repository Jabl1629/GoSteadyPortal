"""
Unit tests for the analytics-api pure aggregation core (aggregate.py).

Covers the math worth testing per docs/specs/user-analytics.md T1-T3:
  T1 OTP funnel (requested/completed/abandoned/verifyFailed + resend-dedup)
  T2 active-time sessionization (idle-gap boundary, lone-event, all-in-one)
  T3 offload bucketing (per-day + per-hour-of-day + total)
  + index_events end-to-end reshape and parse_epoch tolerance.

aggregate.py is pure stdlib (no boto3, no Powertools) so these run offline:
    cd infra/lambda/analytics-api/tests && python3 -m unittest test_shaping
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

_AA_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(_AA_DIR))

import aggregate as ag  # noqa: E402


class TestParseEpoch(unittest.TestCase):
    def test_iso_z(self):
        self.assertAlmostEqual(ag.parse_epoch("1970-01-01T00:00:10Z"), 10.0)

    def test_iso_offset_and_fractional(self):
        self.assertAlmostEqual(ag.parse_epoch("1970-01-01T00:00:01.500+00:00"), 1.5)

    def test_insights_space_form(self):
        # Logs Insights @timestamp uses a space + no zone → treated as UTC.
        self.assertAlmostEqual(ag.parse_epoch("1970-01-01 00:01:00.000"), 60.0)

    def test_epoch_millis_heuristic(self):
        self.assertAlmostEqual(ag.parse_epoch(1_700_000_000_000), 1_700_000_000.0)

    def test_junk_is_none(self):
        self.assertIsNone(ag.parse_epoch("not-a-date"))
        self.assertIsNone(ag.parse_epoch(None))
        self.assertIsNone(ag.parse_epoch(""))


class TestSessionize(unittest.TestCase):
    def test_empty(self):
        self.assertEqual(ag.sessionize([]), (0, 0.0))

    def test_single_event_zero_duration(self):
        # A lone ping is one session of zero length (not a duration).
        self.assertEqual(ag.sessionize([1000.0]), (1, 0.0))

    def test_all_within_one_session(self):
        # 0, +10min, +20min — all within the 30-min gap → one 20-min session.
        epochs = [0.0, 600.0, 1200.0]
        sessions, seconds = ag.sessionize(epochs)
        self.assertEqual(sessions, 1)
        self.assertEqual(seconds, 1200.0)

    def test_gap_splits_sessions(self):
        # Two clusters separated by > 30 min → two sessions; active = sum of spans.
        epochs = [0.0, 300.0, 300.0 + 31 * 60, 300.0 + 31 * 60 + 120]
        sessions, seconds = ag.sessionize(epochs)
        self.assertEqual(sessions, 2)
        self.assertEqual(seconds, 300.0 + 120.0)

    def test_boundary_exactly_gap_is_same_session(self):
        # Exactly 30 min apart is NOT > gap → same session.
        epochs = [0.0, float(ag.ACTIVE_SESSION_GAP_SECONDS)]
        sessions, seconds = ag.sessionize(epochs)
        self.assertEqual(sessions, 1)
        self.assertEqual(seconds, float(ag.ACTIVE_SESSION_GAP_SECONDS))


class TestOtpFunnel(unittest.TestCase):
    def test_completed_within_window(self):
        pu = ag.otp_funnel_by_user(
            requested_by_user={"u1": [1000.0]},
            sms_login_by_user={"u1": [1000.0 + 60]},  # login 1 min later
            verify_failed_by_user={},
        )
        self.assertEqual(pu["u1"], {"requested": 1, "completed": 1, "abandoned": 0, "verifyFailed": 0})

    def test_abandoned_when_no_login(self):
        pu = ag.otp_funnel_by_user(
            requested_by_user={"u1": [1000.0]},
            sms_login_by_user={},
            verify_failed_by_user={"u1": [1000.0 + 30]},
        )
        self.assertEqual(pu["u1"], {"requested": 1, "completed": 0, "abandoned": 1, "verifyFailed": 1})

    def test_login_after_window_is_abandoned(self):
        # Login lands AFTER the 15-min window → the request is abandoned.
        pu = ag.otp_funnel_by_user(
            requested_by_user={"u1": [0.0]},
            sms_login_by_user={"u1": [ag.OTP_WINDOW_SECONDS + 60]},
            verify_failed_by_user={},
        )
        self.assertEqual(pu["u1"]["abandoned"], 1)
        self.assertEqual(pu["u1"]["completed"], 0)

    def test_resend_dedup_collapses_to_one_entry(self):
        # Two requests 2 min apart (< 15-min window) → ONE funnel entry.
        pu = ag.otp_funnel_by_user(
            requested_by_user={"u1": [0.0, 120.0]},
            sms_login_by_user={"u1": [180.0]},
            verify_failed_by_user={},
        )
        self.assertEqual(pu["u1"]["requested"], 1)
        self.assertEqual(pu["u1"]["completed"], 1)

    def test_two_separate_requests_are_two_entries(self):
        # Requests > 15 min apart are two distinct funnel entries.
        pu = ag.otp_funnel_by_user(
            requested_by_user={"u1": [0.0, ag.OTP_WINDOW_SECONDS + 600.0]},
            sms_login_by_user={"u1": [60.0]},  # only the first completes
            verify_failed_by_user={},
        )
        self.assertEqual(pu["u1"]["requested"], 2)
        self.assertEqual(pu["u1"]["completed"], 1)
        self.assertEqual(pu["u1"]["abandoned"], 1)

    def test_totals(self):
        pu = {
            "u1": {"requested": 2, "completed": 1, "abandoned": 1, "verifyFailed": 0},
            "u2": {"requested": 1, "completed": 1, "abandoned": 0, "verifyFailed": 3},
        }
        tot = ag.funnel_totals(pu)
        self.assertEqual(tot["requested"], 3)
        self.assertEqual(tot["completed"], 2)
        self.assertEqual(tot["abandoned"], 1)
        self.assertEqual(tot["verifyFailed"], 3)
        self.assertAlmostEqual(tot["abandonmentRate"], round(1 / 3, 4))

    def test_rate_none_when_no_requests(self):
        self.assertIsNone(ag.funnel_totals({})["abandonmentRate"])


class TestBucketOffloads(unittest.TestCase):
    def test_total_and_per_day(self):
        rows = [
            {"date": "2026-07-20", "timestamp": "2026-07-20T14:00:00Z"},
            {"date": "2026-07-20", "timestamp": "2026-07-20T15:30:00Z"},
            {"date": "2026-07-21", "timestamp": "2026-07-21T09:00:00Z"},
        ]
        out = ag.bucket_offloads(rows)
        self.assertEqual(out["total"], 3)
        per_day = {d["date"]: d["count"] for d in out["perDay"]}
        self.assertEqual(per_day, {"2026-07-20": 2, "2026-07-21": 1})

    def test_per_hour_histogram_has_24_buckets(self):
        rows = [{"date": "2026-07-20", "timestamp": "2026-07-20T14:00:00Z"}]
        out = ag.bucket_offloads(rows)
        self.assertEqual(len(out["perHour"]), 24)
        by_hour = {h["hour"]: h["count"] for h in out["perHour"]}
        self.assertEqual(by_hour[14], 1)
        self.assertEqual(by_hour[0], 0)

    def test_offloads_by_user_mapping_and_unattributed(self):
        rows = [
            {"patientId": "p1"}, {"patientId": "p1"}, {"patientId": "p2"},
            {"patientId": "p_orphan"},
        ]
        mapping = {"p1": "u1", "p2": "u2"}  # p_orphan has no user
        out = ag.offloads_by_user(rows, mapping)
        self.assertEqual(out["u1"], 2)
        self.assertEqual(out["u2"], 1)
        self.assertEqual(out[""], 1)  # unattributed sentinel


class TestIndexEvents(unittest.TestCase):
    def test_reshape_end_to_end(self):
        events = [
            {"event": "auth.otp_requested", "uid": "u1", "ts": 100.0},
            {"event": "auth.login", "uid": "u1", "ts": 160.0, "method": "sms_otp"},
            {"event": "patient.list.read", "uid": "u1", "ts": 200.0},
            {"event": "coach.chat.turn", "uid": "u1", "ts": 300.0},
            {"event": "coach.chat.turn", "uid": "u1", "ts": 360.0},
            {"event": "auth.login", "uid": "u2", "ts": 500.0, "method": "password"},
            {"event": "auth.otp_verify_failed", "uid": "u3", "ts": 50.0},
        ]
        idx = ag.index_events(events)
        self.assertEqual(idx["logins_by_method"], {"sms_otp": 1, "password": 1})
        self.assertEqual(idx["sms_login_by_user"]["u1"], [160.0])
        self.assertEqual(idx["requested_by_user"]["u1"], [100.0])
        self.assertEqual(idx["verify_failed_by_user"]["u3"], [50.0])
        self.assertEqual(idx["coach_by_user"]["u1"], 2)
        self.assertEqual(idx["users_seen"], {"u1", "u2", "u3"})
        # active signal events for u1: otp_requested is NOT active; login, read,
        # 2 coach turns ARE → 4 epochs.
        self.assertEqual(len(idx["active_epochs_by_user"]["u1"]), 4)

    def test_login_without_method_is_unknown(self):
        idx = ag.index_events([{"event": "auth.login", "uid": "u1", "ts": 1.0}])
        self.assertEqual(idx["logins_by_method"], {"unknown": 1})


if __name__ == "__main__":
    unittest.main()
