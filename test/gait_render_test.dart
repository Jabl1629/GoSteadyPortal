// Verifies gait survives the full live read path: API JSON (string-serialized
// Decimals, exactly as the deployed patient-api returns) → ActivitySession
// .fromJson → SessionAdapter (today + multi-day buckets) → DailyActivity →
// the hideGait gate. Regression for the _bucketByLocalHour gait gap + the
// short-walk daily-average floor. Times are anchored at local noon to avoid a
// UTC-rollover edge that's orthogonal to gait.
import 'package:flutter_test/flutter_test.dart';
import 'package:gosteady_portal/api/api_models.dart';
import 'package:gosteady_portal/api/session_adapter.dart';

void main() {
  final today = DateTime.now();
  final noon = DateTime(today.year, today.month, today.day, 12, 0);

  // Build an ActivitySession exactly as the deployed API delivers it:
  // every numeric value is a STRING. `end` is a local DateTime.
  ActivitySession walk(DateTime end, int steps, double dist, int active,
      double? gait) {
    final start = end.subtract(const Duration(seconds: 20));
    return ActivitySession.fromJson({
      'sessionStart': start.toIso8601String(),
      'sessionEnd': end.toIso8601String(),
      'date':
          '${end.year}-${end.month.toString().padLeft(2, '0')}-${end.day.toString().padLeft(2, '0')}',
      'steps': '$steps',
      'distanceFt': '$dist',
      'activeMinutes': '$active',
      'deviceSerial': 'GS0000000001',
      if (gait != null) 'gaitSpeedFts': '$gait',
    });
  }

  test('fromJson parses string gaitSpeedFts', () {
    final s = ActivitySession.fromJson({
      'sessionStart': '2026-06-08T03:16:00Z',
      'sessionEnd': '2026-06-08T03:16:16Z',
      'date': '2026-06-08',
      'steps': '9',
      'distanceFt': '13.84',
      'activeMinutes': '1',
      'gaitSpeedFts': '1.23',
    });
    expect(s.gaitSpeedFts, 1.23);
    expect(s.distanceFt, 13.84);
    expect(s.steps, 9);
  });

  test('today (24h / _bucketByLocalHour) carries gait', () {
    final sessions = [
      walk(noon.subtract(const Duration(minutes: 5)), 18, 17.45, 1, 0.77),
      walk(noon.subtract(const Duration(minutes: 12)), 22, 34.65, 1, 1.12),
    ];
    final d = SessionAdapter.toToday(sessions, referenceDate: noon);
    expect(d.totalSteps, greaterThan(0), reason: 'sanity: sessions bucketed');
    expect(d.hours.any((h) => h.avgGaitSpeedFts > 0), isTrue,
        reason: 'today 24h view must carry gait');
    expect(d.avgGaitSpeedFts, greaterThan(0));
  });

  test('multi-day (30d / _bucketByHour) carries gait + un-hides the chart', () {
    final sessions = [
      walk(noon.subtract(const Duration(minutes: 5)), 18, 17.45, 1, 0.77),
      walk(noon.subtract(const Duration(minutes: 12)), 22, 34.65, 0, 1.12),
      walk(noon.subtract(const Duration(minutes: 30)), 7, 7.09, 0, 0.84),
    ];
    final daily = SessionAdapter.toDailyList(sessions);
    expect(daily, isNotEmpty);
    expect(daily.first.totalSteps, greaterThan(0),
        reason: 'sanity: sessions bucketed (steps work → gait must too)');
    expect(daily.any((d) => d.avgGaitSpeedFts > 0), isTrue,
        reason: 'hideGait gates on last30.any(avg>0)');
  });

  test('toToday is the calendar day, not the rolling 24h window', () {
    // The range=24h fetch includes last night; those must NOT show as today.
    final yesterday9pm =
        DateTime(today.year, today.month, today.day, 21, 0)
            .subtract(const Duration(days: 1));
    final sessions = [
      walk(noon.subtract(const Duration(minutes: 5)), 18, 17.45, 1, 0.77),
      walk(yesterday9pm, 30, 40.0, 2, 0.90), // yesterday 9pm — must drop
    ];
    final d = SessionAdapter.toToday(sessions, referenceDate: noon);
    expect(d.totalSteps, 18,
        reason: "yesterday's evening session must not count as today");
    expect(d.hours[21].steps, 0,
        reason: 'no 9pm bar on the today clock when it is midday');
  });

  test('short-walk-only day still averages non-zero (floor weight)', () {
    final sessions = [
      walk(noon.subtract(const Duration(minutes: 5)), 7, 7.0, 0, 0.84),
      walk(noon.subtract(const Duration(minutes: 10)), 8, 11.2, 0, 1.21),
    ];
    final daily = SessionAdapter.toDailyList(sessions);
    expect(daily.first.totalSteps, greaterThan(0), reason: 'sanity');
    expect(daily.first.avgGaitSpeedFts, greaterThan(0),
        reason: 'activeMinutes=0 must not zero the daily gait average');
  });
}
