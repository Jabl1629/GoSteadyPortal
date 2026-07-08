// Per-device-type metric registry (DT-4 / device-types memo Q10).
//
// A rollator produces no `steps` (a frame-mount IMU has no lift-and-place
// impulses — coord §C52), so the D2C dashboard can't render steps for it.
// This lean map keys the per-type "which metric leads, which stats show, how
// to label them" off `deviceType` — the walker keeps its steps-led view; the
// rollator leads on active-minutes (the universal cross-type metric) with
// distance + gait as secondary. Absent/unknown deviceType → walker_cap (D9).
//
// It is deliberately a small declarative config that drives the EXISTING
// dashboard widgets (not a pluggable per-type widget system) — the right
// altitude for two device types today, trivially extensible to a third.

/// The metrics a D2C activity surface can present.
enum ActivityMetric { steps, activeMinutes, distanceFt, gaitSpeedFts }

/// The per-type presentation contract the dashboard reads.
class DeviceTypeView {
  const DeviceTypeView({
    required this.deviceType,
    required this.hero,
    required this.statRow,
  });

  /// Registry key (`walker_cap` | `rollator_platform`).
  final String deviceType;

  /// The primary/"hero" metric — the big greeting number, the "above your
  /// usual" context, and the 7-day trend-chart bars all key on this.
  final ActivityMetric hero;

  /// The stat-row metrics, in display order (hero first by convention).
  final List<ActivityMetric> statRow;
}

const DeviceTypeView _walkerView = DeviceTypeView(
  deviceType: 'walker_cap',
  hero: ActivityMetric.steps,
  statRow: [
    ActivityMetric.steps,
    ActivityMetric.distanceFt,
    ActivityMetric.activeMinutes,
  ],
);

const DeviceTypeView _rollatorView = DeviceTypeView(
  deviceType: 'rollator_platform',
  hero: ActivityMetric.activeMinutes,
  statRow: [
    ActivityMetric.activeMinutes,
    ActivityMetric.distanceFt,
    ActivityMetric.gaitSpeedFts,
  ],
);

/// Resolve the presentation contract for a device type. Null/empty/unknown →
/// walker_cap (DT-0 D9: absence reads as walker_cap).
DeviceTypeView deviceTypeView(String? deviceType) =>
    deviceType == 'rollator_platform' ? _rollatorView : _walkerView;

/// Short stat-row label (e.g. "Steps", "Active", "Distance", "Gait").
String metricLabelShort(ActivityMetric m) {
  switch (m) {
    case ActivityMetric.steps:
      return 'Steps';
    case ActivityMetric.activeMinutes:
      return 'Active';
    case ActivityMetric.distanceFt:
      return 'Distance';
    case ActivityMetric.gaitSpeedFts:
      return 'Gait';
  }
}

/// Longer label for the hero line / greeting (e.g. "active minutes").
String metricLabelLong(ActivityMetric m) {
  switch (m) {
    case ActivityMetric.steps:
      return 'steps';
    case ActivityMetric.activeMinutes:
      return 'active minutes';
    case ActivityMetric.distanceFt:
      return 'distance';
    case ActivityMetric.gaitSpeedFts:
      return 'gait speed';
  }
}

/// Unit suffix for a formatted value (e.g. "", "min", "ft", "ft/s").
String metricUnit(ActivityMetric m) {
  switch (m) {
    case ActivityMetric.steps:
      return '';
    case ActivityMetric.activeMinutes:
      return 'min';
    case ActivityMetric.distanceFt:
      return 'ft';
    case ActivityMetric.gaitSpeedFts:
      return 'ft/s';
  }
}

/// Format a metric value for display. `value` is null when the metric is
/// unavailable (rollator distance/gait are firmware confidence-gated — a
/// stationary session omits them) → render an em-dash, never "0".
String formatMetric(ActivityMetric m, num? value) {
  if (value == null) return '—';
  switch (m) {
    case ActivityMetric.steps:
    case ActivityMetric.activeMinutes:
    case ActivityMetric.distanceFt:
      return value.round().toString();
    case ActivityMetric.gaitSpeedFts:
      return value.toStringAsFixed(1);
  }
}
