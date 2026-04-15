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

  const HourlyActivity({
    required this.hour,
    required this.steps,
    required this.distanceFt,
    required this.timeInMotionMinutes,
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
}

/// Aggregate activity for a calendar week. Used in the 6-month view.
class WeeklyActivity {
  final DateTime weekStart;
  final int totalSteps;
  final double totalDistanceFt;
  final int totalTimeInMotionMinutes;

  const WeeklyActivity({
    required this.weekStart,
    required this.totalSteps,
    required this.totalDistanceFt,
    required this.totalTimeInMotionMinutes,
  });
}
