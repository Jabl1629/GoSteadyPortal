import 'dart:math';

import '../models/activity.dart';
import '../models/device.dart';

/// Stand-in data source until the AWS ingestion pipeline is live. The
/// numbers here are scaled from the actual capture annotations in
/// `GoSteady_Capture_Annotations_v1.xlsx` — real step counts observed
/// during hallway, living room, and kitchen runs on a standard walker
/// with the tacky cap.
///
/// Swap this class for a real API client (e.g. `ApiClient`) once the
/// AWS endpoints exist. The model shapes are deliberately identical to
/// what the firmware payload will deserialize into.
class MockDataSource {
  MockDataSource({int seed = 42}) : _rng = Random(seed);

  final Random _rng;

  DeviceHealth currentDevice() {
    return DeviceHealth(
      serialNumber: 'GS-00042801',
      firmwareVersion: '0.1.0-dev',
      sensorModel: 'BMI270',
      // ~93% battery — device has been in service for a few weeks on the
      // single-use cell.
      batteryMv: 3555,
      // -84 dBm: solid LTE-M signal, nothing to worry about.
      signalDbm: -84,
      // Most recent heartbeat arrived ~1.5 hours ago, well within the 4h
      // expected interval.
      lastDataReceived:
          DateTime.now().subtract(const Duration(hours: 1, minutes: 32)),
    );
  }

  /// 24 hours of activity for today, with realistic walking rhythm for
  /// an older adult: morning activity, light lunchtime movement, a bit
  /// of afternoon walking, and quiet evening/overnight hours.
  DailyActivity today() {
    final now = DateTime.now();
    final startOfDay = DateTime(now.year, now.month, now.day);
    final currentHour = now.hour;
    final hours = <HourlyActivity>[];

    for (var h = 0; h <= currentHour; h++) {
      final bucket = startOfDay.add(Duration(hours: h));
      hours.add(_syntheticHour(bucket, h));
    }
    return DailyActivity(date: startOfDay, hours: hours);
  }

  /// Last 7 days (not including today) of daily aggregates.
  List<DailyActivity> last7Days() => _generateDays(7);

  /// Last 30 days (not including today) of daily aggregates.
  List<DailyActivity> last30Days() => _generateDays(30);

  /// Last ~26 weeks (6 months) of weekly aggregates.
  List<WeeklyActivity> last6Months() {
    final days = _generateDays(182);
    final weeks = <WeeklyActivity>[];

    // Group into 7-day chunks starting from the oldest day.
    for (var i = 0; i < days.length; i += 7) {
      final chunk = days.sublist(i, min(i + 7, days.length));
      weeks.add(WeeklyActivity(
        weekStart: chunk.first.date,
        totalSteps: chunk.fold(0, (s, d) => s + d.totalSteps),
        totalDistanceFt: chunk.fold(0.0, (s, d) => s + d.totalDistanceFt),
        totalTimeInMotionMinutes:
            chunk.fold(0, (s, d) => s + d.totalTimeInMotionMinutes),
      ));
    }
    return weeks;
  }

  List<DailyActivity> _generateDays(int count) {
    final now = DateTime.now();
    final startOfToday = DateTime(now.year, now.month, now.day);
    final days = <DailyActivity>[];

    for (var d = count; d >= 1; d--) {
      final date = startOfToday.subtract(Duration(days: d));
      final hours = <HourlyActivity>[];
      for (var h = 0; h < 24; h++) {
        hours.add(_syntheticHour(date.add(Duration(hours: h)), h));
      }
      days.add(DailyActivity(date: date, hours: hours));
    }
    return days;
  }

  /// Generate a single hour of activity with a realistic daily pattern.
  HourlyActivity _syntheticHour(DateTime hour, int hourOfDay) {
    // Baseline walking intensity by time of day (0.0 = none, 1.0 = peak).
    // Tuned to match an older adult's typical rhythm: morning rise,
    // meal-time trips, quiet afternoon, light evening, nothing overnight.
    final intensity = _intensityCurve(hourOfDay);
    if (intensity < 0.01) {
      return HourlyActivity(
        hour: hour,
        steps: 0,
        distanceFt: 0,
        timeInMotionMinutes: 0,
      );
    }

    // Peak hour is ~120 steps. Scale by intensity, add some day-to-day
    // variance so the charts don't look artificial.
    final peakSteps = 120;
    final noise = 0.75 + _rng.nextDouble() * 0.5; // 0.75 - 1.25 multiplier
    final steps = (peakSteps * intensity * noise).round();

    // From firmware_algo_dev: stride length roughly 1.3 ft/step on hard
    // floors at normal pace. Add a little per-hour jitter.
    final stride = 1.25 + _rng.nextDouble() * 0.15;
    final distanceFt = steps * stride;

    // Roughly 1 minute of motion per 15 steps, capped at 55 min/hr.
    final motionMinutes = min((steps / 15).round(), 55);

    return HourlyActivity(
      hour: hour,
      steps: steps,
      distanceFt: distanceFt,
      timeInMotionMinutes: motionMinutes,
    );
  }

  double _intensityCurve(int hourOfDay) {
    switch (hourOfDay) {
      case 0: case 1: case 2: case 3: case 4: case 5:
        return 0.0;
      case 6: return 0.15;
      case 7: return 0.55; // morning bathroom + breakfast
      case 8: return 0.70;
      case 9: return 0.45;
      case 10: return 0.30;
      case 11: return 0.50;
      case 12: return 0.75; // lunch
      case 13: return 0.35;
      case 14: return 0.20;
      case 15: return 0.40;
      case 16: return 0.55;
      case 17: return 0.70; // dinner prep
      case 18: return 0.60;
      case 19: return 0.40;
      case 20: return 0.25;
      case 21: return 0.20;
      case 22: return 0.10;
      case 23: return 0.0;
      default: return 0.0;
    }
  }
}
