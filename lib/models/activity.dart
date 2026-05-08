/// Selectable time window for the dashboard charts and summary stats.
enum TimeRange { day, week, month, sixMonth }

/// One hour of activity data, as offloaded by the device (REQ-FW-06).
/// Produced by the firmware's step detection and distance estimation
/// algorithms (REQ-FW-04, REQ-FW-05).
class HourlyActivity {
  /// Hour boundary (floored). Activity in this bucket was captured during
  /// the hour starting at this timestamp.
  final DateTime hour;

  /// Steps detected during this hour.
  final int steps;

  /// Estimated distance traveled in feet, from the stride-regression
  /// distance algorithm (12.4% MAPE on V1 calibration set).
  final double distanceFt;

  /// Minutes the user was actively in motion during this hour.
  final int timeInMotionMinutes;

  /// Average gait speed in m/s during walking bouts in this hour.
  /// Zero when the user did not walk this hour.
  final double avgGaitSpeedMs;

  /// Slowest sustained walking-bout speed observed in this hour, m/s.
  final double minGaitSpeedMs;

  /// Fastest sustained walking-bout speed observed in this hour, m/s.
  final double maxGaitSpeedMs;

  const HourlyActivity({
    required this.hour,
    required this.steps,
    required this.distanceFt,
    required this.timeInMotionMinutes,
    this.avgGaitSpeedMs = 0,
    this.minGaitSpeedMs = 0,
    this.maxGaitSpeedMs = 0,
  });
}

/// Aggregate activity for a single day. Derived from the hourly buckets.
class DailyActivity {
  final DateTime date;
  final List<HourlyActivity> hours;

  const DailyActivity({required this.date, required this.hours});

  int get totalSteps => hours.fold(0, (sum, h) => sum + h.steps);

  double get totalDistanceFt =>
      hours.fold(0.0, (sum, h) => sum + h.distanceFt);

  int get totalTimeInMotionMinutes =>
      hours.fold(0, (sum, h) => sum + h.timeInMotionMinutes);

  /// Number of hours with any walking activity recorded.
  int get activeHourCount => hours.where((h) => h.steps > 0).length;

  /// Time-weighted average gait speed across active hours. Zero if there
  /// was no walking today (avoids divide-by-zero).
  double get avgGaitSpeedMs {
    var num = 0.0;
    var den = 0;
    for (final h in hours) {
      if (h.timeInMotionMinutes <= 0 || h.avgGaitSpeedMs <= 0) continue;
      num += h.avgGaitSpeedMs * h.timeInMotionMinutes;
      den += h.timeInMotionMinutes;
    }
    return den == 0 ? 0 : num / den;
  }

  /// Slowest sustained speed across the day's active hours.
  double get minGaitSpeedMs {
    final active = hours.where((h) => h.minGaitSpeedMs > 0);
    if (active.isEmpty) return 0;
    return active
        .map((h) => h.minGaitSpeedMs)
        .reduce((a, b) => a < b ? a : b);
  }

  /// Fastest sustained speed across the day's active hours.
  double get maxGaitSpeedMs {
    final active = hours.where((h) => h.maxGaitSpeedMs > 0);
    if (active.isEmpty) return 0;
    return active
        .map((h) => h.maxGaitSpeedMs)
        .reduce((a, b) => a > b ? a : b);
  }
}

/// Aggregate activity for a calendar week. Used in the 6-month view.
class WeeklyActivity {
  final DateTime weekStart;
  final int totalSteps;
  final double totalDistanceFt;
  final int totalTimeInMotionMinutes;

  /// Time-weighted average gait speed (m/s) across the week.
  final double avgGaitSpeedMs;

  /// Slowest sustained gait speed observed in the week (m/s).
  final double minGaitSpeedMs;

  /// Fastest sustained gait speed observed in the week (m/s).
  final double maxGaitSpeedMs;

  const WeeklyActivity({
    required this.weekStart,
    required this.totalSteps,
    required this.totalDistanceFt,
    required this.totalTimeInMotionMinutes,
    this.avgGaitSpeedMs = 0,
    this.minGaitSpeedMs = 0,
    this.maxGaitSpeedMs = 0,
  });
}
