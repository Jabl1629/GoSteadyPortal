// Internal user-analytics (docs/specs/user-analytics.md) — the /analytics route
// is internal-auth-gated, so it can't be driven headlessly (same as /fleet; see
// fleet_rotation_render_test.dart). This locks the piece with untested value:
// the analytics-api JSON → model parse the screen renders from. The server side
// of the same contract is covered by infra/lambda/analytics-api/tests/
// test_shaping.py; live visual proof comes from a dev deploy E2E.
import 'package:flutter_test/flutter_test.dart';
import 'package:gosteady_portal/api/api_models.dart';

void main() {
  group('AnalyticsOverview.fromJson', () {
    final body = {
      'range': '7d',
      'since': '2026-07-14T00:00:00Z',
      'until': '2026-07-21T00:00:00Z',
      'logins': {
        'total': 34,
        'byMethod': {'sms_otp': 22, 'qr_relogin': 7, 'password': 5},
      },
      'otp': {
        'requested': 29,
        'completed': 22,
        'abandoned': 7,
        'verifyFailed': 4,
        'abandonmentRate': 0.2414,
      },
      'activeUsers': 18,
      'avgSessionMinutes': 4.6,
      'offloads': {
        'total': 52,
        'perDay': [
          {'date': '2026-07-20', 'count': 10},
          {'date': '2026-07-21', 'count': 5},
        ],
        'perHour': [
          {'hour': 9, 'count': 4},
          {'hour': 16, 'count': 3},
        ],
      },
      'coach': {'turns': 63, 'activeUsers': 8},
      'meta': {'insightsStatus': 'Complete', 'offloadTruncated': false},
    };

    test('parses logins + method breakdown', () {
      final o = AnalyticsOverview.fromJson(body);
      expect(o.range, '7d');
      expect(o.loginsTotal, 34);
      expect(o.loginsByMethod['sms_otp'], 22);
      expect(o.loginsByMethod['qr_relogin'], 7);
    });

    test('parses OTP funnel + offloads + coach', () {
      final o = AnalyticsOverview.fromJson(body);
      expect(o.otp.abandoned, 7);
      expect(o.otp.abandonmentRate, closeTo(0.2414, 1e-9));
      expect(o.offloads.total, 52);
      expect(o.offloads.perDay.first.label, '2026-07-20');
      expect(o.offloads.perDay.first.count, 10);
      expect(o.offloads.perHour.first.label, '9');
      expect(o.coachTurns, 63);
      expect(o.coachActiveUsers, 8);
      expect(o.insightsStatus, 'Complete');
      expect(o.offloadTruncated, isFalse);
    });

    test('null abandonmentRate (no requests) survives parse', () {
      final o = AnalyticsOverview.fromJson({
        ...body,
        'otp': {'requested': 0, 'completed': 0, 'abandoned': 0, 'verifyFailed': 0},
      });
      expect(o.otp.abandonmentRate, isNull);
    });

    test('DDB-style numeric strings coerce (Decimal-as-string tolerance)', () {
      // patient-api ranges show DDB can surface numbers as strings; the shared
      // _parseInt/_parseDouble must coerce them.
      final o = AnalyticsOverview.fromJson({
        ...body,
        'logins': {'total': '34', 'byMethod': {'sms_otp': '22'}},
        'avgSessionMinutes': '4.6',
      });
      expect(o.loginsTotal, 34);
      expect(o.loginsByMethod['sms_otp'], 22);
      expect(o.avgSessionMinutes, closeTo(4.6, 1e-9));
    });
  });

  group('AnalyticsUsersResponse.fromJson', () {
    test('parses rows + meta', () {
      final r = AnalyticsUsersResponse.fromJson({
        'range': '7d',
        'users': [
          {
            'userId': 'u_jane',
            'clientId': 'dtc_demo01',
            'role': 'household_owner',
            'isWalkerUser': true,
            'deviceSerial': 'GS0002000001',
            'deviceLastSeen': '2026-07-21T20:56:00Z',
            'logins': 6,
            'otpAbandoned': 1,
            'otpVerifyFailed': 0,
            'activeMinutes': 24,
            'offloads': 14,
            'coachTurns': 19,
            'lastActive': '2026-07-20T13:30:00Z',
          },
        ],
        'count': 1,
        'nextCursor': null,
        'meta': {'insightsStatus': 'Complete', 'unattributedOffloads': 3},
      });
      expect(r.count, 1);
      expect(r.unattributedOffloads, 3);
      expect(r.users.single.userId, 'u_jane');
      expect(r.users.single.isWalkerUser, isTrue); // walker segment
      expect(r.users.single.deviceSerial, 'GS0002000001');
      expect(r.users.single.otpAbandoned, 1);
      expect(r.users.single.offloads, 14);
      expect(r.users.single.lastActive, isNotNull);
      // deviceLastSeen (device heartbeat) is parsed + distinct from lastActive
      // (user in-app activity) — the whole point of the two columns.
      expect(r.users.single.deviceLastSeen, isNotNull);
      expect(r.users.single.deviceLastSeen!.isAfter(r.users.single.lastActive!),
          isTrue);
    });

    test('missing deviceSerial → empty string (no device)', () {
      final r = AnalyticsUsersResponse.fromJson({
        'users': [
          {'userId': 'u_nodev', 'clientId': 'dtc_x', 'role': 'family_viewer'},
        ],
        'meta': {'insightsStatus': 'Complete'},
      });
      expect(r.users.single.deviceSerial, '');
      expect(r.users.single.isWalkerUser, isFalse); // absent → care circle
    });

    test('empty users list → empty table, count 0', () {
      final r = AnalyticsUsersResponse.fromJson({
        'users': <dynamic>[],
        'meta': {'insightsStatus': 'Complete'},
      });
      expect(r.users, isEmpty);
      expect(r.count, 0);
      expect(r.unattributedOffloads, 0);
    });
  });

  group('ResidentsResponse.fromJson', () {
    test('parses roster rows + device/activity timestamps', () {
      final r = ResidentsResponse.fromJson({
        'residents': [
          {
            'patientId': 'pat_d2c_1',
            'displayName': 'Dorothy Iupert',
            'clientId': 'dtc_5e125b4b',
            'status': 'active',
            'deviceSerial': 'GS0002000002',
            'deviceStatus': 'active_monitoring',
            'deviceLastSeen': '2026-07-21T20:56:00Z',
            'lastActivityAt': '2026-07-20T20:57:00Z',
          },
        ],
        'count': 1,
        'truncated': false,
      });
      expect(r.count, 1);
      expect(r.truncated, isFalse);
      final row = r.residents.single;
      expect(row.displayName, 'Dorothy Iupert');
      expect(row.deviceSerial, 'GS0002000002');
      expect(row.deviceLastSeen, isNotNull);
      expect(row.lastActivityAt, isNotNull);
    });

    test('no device / no activity → empty serial + null timestamps', () {
      final r = ResidentsResponse.fromJson({
        'residents': [
          {'patientId': 'pat_x', 'displayName': 'Jo', 'clientId': 'dtc_y', 'status': 'active'},
        ],
      });
      final row = r.residents.single;
      expect(row.deviceSerial, '');
      expect(row.deviceLastSeen, isNull);
      expect(row.lastActivityAt, isNull);
      expect(r.count, 1); // count falls back to residents.length
    });
  });
}
