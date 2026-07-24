import '../api/api_client.dart';
import '../api/api_models.dart';

/// Internal user-analytics data access — backs the internal_admin/_support
/// analytics screen (docs/specs/user-analytics.md).
///
/// Standalone (like [FleetRepository]): the dashboard is internal-only,
/// cross-tenant, and read-only. The live impl is a thin wrapper over
/// [ApiClient]; the mock backs demo-mode rendering with no backend.
abstract class AnalyticsRepository {
  /// `GET /admin/analytics/overview?range=` — population KPIs.
  Future<AnalyticsOverview> overview(String range);

  /// `GET /admin/analytics/users?range=` — per-user table.
  Future<AnalyticsUsersResponse> users(String range);
}

/// Live impl over the authenticated [ApiClient].
class LiveAnalyticsRepository implements AnalyticsRepository {
  final ApiClient _api;
  LiveAnalyticsRepository(this._api);

  @override
  Future<AnalyticsOverview> overview(String range) =>
      _api.getAnalyticsOverview(range: range);

  @override
  Future<AnalyticsUsersResponse> users(String range) =>
      _api.getAnalyticsUsers(range: range);
}

/// In-memory mock for demo mode (no backend). Shaped to look like real
/// aggregated output so the screen renders + charts without an API.
class MockAnalyticsRepository implements AnalyticsRepository {
  @override
  Future<AnalyticsOverview> overview(String range) async {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    // A believable pilot week: sparse mornings + afternoons.
    const perDay = [
      AnalyticsBucket(label: '2026-07-15', count: 6),
      AnalyticsBucket(label: '2026-07-16', count: 9),
      AnalyticsBucket(label: '2026-07-17', count: 4),
      AnalyticsBucket(label: '2026-07-18', count: 11),
      AnalyticsBucket(label: '2026-07-19', count: 7),
      AnalyticsBucket(label: '2026-07-20', count: 10),
      AnalyticsBucket(label: '2026-07-21', count: 5),
    ];
    final perHour = List.generate(24, (h) {
      // Two humps: ~9am and ~4pm walks.
      final morning = (h >= 8 && h <= 11) ? 5 - (h - 9).abs() : 0;
      final afternoon = (h >= 15 && h <= 18) ? 4 - (h - 16).abs() : 0;
      final c = (morning + afternoon).clamp(0, 6);
      return AnalyticsBucket(label: '$h', count: c);
    });
    return AnalyticsOverview(
      range: range,
      loginsTotal: 34,
      loginsByMethod: const {'sms_otp': 22, 'qr_relogin': 7, 'password': 5},
      otp: const OtpFunnel(
          requested: 29, completed: 22, abandoned: 7, verifyFailed: 4,
          abandonmentRate: 0.2414),
      activeUsers: 18,
      avgSessionMinutes: 4.6,
      offloads: OffloadBuckets(total: 52, perDay: perDay, perHour: perHour),
      coachTurns: 63,
      coachActiveUsers: 8,
      insightsStatus: 'Complete',
      offloadTruncated: false,
    );
  }

  @override
  Future<AnalyticsUsersResponse> users(String range) async {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    final rows = <AnalyticsUserRow>[
      AnalyticsUserRow(
        userId: 'u_demo_jane', clientId: 'dtc_demo01', role: 'household_owner',
        isWalkerUser: true,
        deviceSerial: 'GS0002000001',
        deviceLastSeen: DateTime.now().subtract(const Duration(minutes: 8)),
        logins: 6, otpAbandoned: 0, otpVerifyFailed: 1, activeMinutes: 24,
        offloads: 14, coachTurns: 19,
        lastActive: DateTime.now().subtract(const Duration(minutes: 22)),
      ),
      AnalyticsUserRow(
        userId: 'u_demo_bob', clientId: 'dtc_demo03', role: 'household_owner',
        isWalkerUser: true,
        deviceSerial: 'GS0002000004',
        // Device online (heartbeating) but the user hasn't opened the app in
        // 30h — the exact case that confused the operator.
        deviceLastSeen: DateTime.now().subtract(const Duration(minutes: 14)),
        logins: 3, otpAbandoned: 2, otpVerifyFailed: 3, activeMinutes: 8,
        offloads: 5, coachTurns: 2,
        lastActive: DateTime.now().subtract(const Duration(hours: 30)),
      ),
      AnalyticsUserRow(
        userId: 'u_demo_carol', clientId: 'dtc_demo01', role: 'family_viewer',
        deviceSerial: '', // family viewer — no device of their own
        deviceLastSeen: null,
        logins: 9, otpAbandoned: 1, otpVerifyFailed: 0, activeMinutes: 31,
        offloads: 0, coachTurns: 0,
        lastActive: DateTime.now().subtract(const Duration(hours: 1)),
      ),
    ];
    return AnalyticsUsersResponse(
      users: rows, count: rows.length, unattributedOffloads: 3,
      insightsStatus: 'Complete',
    );
  }
}
