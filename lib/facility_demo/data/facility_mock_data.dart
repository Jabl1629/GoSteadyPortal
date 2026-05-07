import 'dart:math';

import '../../models/activity.dart';
import '../../models/device.dart';
import '../models/facility.dart';
import '../models/patient.dart';
import '../models/unit.dart';
import 'facility_seed.dart';

/// Mock data source for the facility demo. Surface mirrors the eventual
/// `ApiClient` (patient-centric methods, hierarchy snapshot at query time)
/// per spec §6.2 so swapping for the real API in Phase 2B is a constructor
/// change.
///
/// Determinism: each patient's data is seeded from `patientId.hashCode`, so
/// reloading the page or moving between dev machines produces identical
/// numbers — important for the conference where we want predictable demos.
class FacilityMockData {
  FacilityMockData();

  // Cached generated data per patient. Lazy: filled on first access.
  final Map<String, _PatientGenerated> _cache = {};

  // ── Facility / unit / patient lookups ───────────────────────────────────

  List<Facility> allFacilities() => FacilitySeed.facilities;

  List<Unit> unitsForFacility(String facilityId) => FacilitySeed.units
      .where((u) => u.facilityId == facilityId)
      .toList(growable: false);

  /// All units across all facilities (helper for the selector dropdown).
  List<Unit> allUnits() => FacilitySeed.units;

  /// All patient summaries whose unit is in [selectedUnitIds]. Empty set
  /// returns no patients (UI default is "all selected").
  List<PatientSummary> patientsForSelection(Set<String> selectedUnitIds) {
    return FacilitySeed.patients
        .where((p) => selectedUnitIds.contains(p.unitId))
        .map(_summaryFor)
        .toList(growable: false);
  }

  /// Lookup a single patient.
  Patient patientById(String patientId) =>
      FacilitySeed.patients.firstWhere((p) => p.id == patientId);

  // ── Detail-panel data (one patient) ────────────────────────────────────

  DailyActivity todayFor(String patientId) => _gen(patientId).today;

  /// 7 days of history, oldest-first.
  List<DailyActivity> last7DaysFor(String patientId) {
    final all = _gen(patientId).last182Days;
    return all.sublist(all.length - 7);
  }

  /// 30 days of history, oldest-first.
  List<DailyActivity> last30DaysFor(String patientId) {
    final all = _gen(patientId).last182Days;
    return all.sublist(all.length - 30);
  }

  /// 26 weeks of history, oldest-first.
  List<WeeklyActivity> last6MonthsFor(String patientId) =>
      _gen(patientId).last6Months;

  DeviceHealth deviceFor(String patientId) => _gen(patientId).device;

  // ── Internals ──────────────────────────────────────────────────────────

  PatientSummary _summaryFor(Patient p) {
    final today = todayFor(p.id);
    final hasData = today.totalSteps > 0 || today.totalTimeInMotionMinutes > 0;
    return PatientSummary(
      patient: p,
      stepsToday: today.totalSteps,
      activeMinutesToday: today.totalTimeInMotionMinutes,
      hasDataToday: hasData,
    );
  }

  _PatientGenerated _gen(String patientId) {
    return _cache.putIfAbsent(patientId, () => _generateFor(patientId));
  }

  _PatientGenerated _generateFor(String patientId) {
    final spec = _activitySpecs[patientId]!;
    final rng = Random(patientId.hashCode);
    final now = DateTime.now();
    final startOfToday = DateTime(now.year, now.month, now.day);

    // 182-day history, oldest first. Newest is yesterday (today is separate).
    final history = <DailyActivity>[];
    for (var dayOffset = 182; dayOffset >= 1; dayOffset--) {
      final date = startOfToday.subtract(Duration(days: dayOffset));
      final amplitude = _historicalAmplitude(spec, dayOffset);
      final dayVariance = 0.75 + rng.nextDouble() * 0.5; // 0.75–1.25
      final dailySteps = (amplitude * dayVariance).round();
      history.add(_buildDay(
        date: date,
        targetSteps: dailySteps,
        cadence: spec.stepsPerActiveMinute,
        rng: rng,
      ));
    }

    // Today: forced exactly to spec target so the tile values match §4.3.
    final today = _buildDay(
      date: startOfToday,
      targetSteps: spec.targetStepsToday,
      cadence: spec.stepsPerActiveMinute,
      targetActiveMin: spec.targetActiveMinToday,
      rng: rng,
    );

    // Aggregate history into 26 weeks (oldest first).
    final weeks = <WeeklyActivity>[];
    for (var i = 0; i < history.length; i += 7) {
      final chunk = history.sublist(i, min(i + 7, history.length));
      weeks.add(WeeklyActivity(
        weekStart: chunk.first.date,
        totalSteps: chunk.fold(0, (s, d) => s + d.totalSteps),
        totalDistanceFt: chunk.fold(0.0, (s, d) => s + d.totalDistanceFt),
        totalTimeInMotionMinutes:
            chunk.fold(0, (s, d) => s + d.totalTimeInMotionMinutes),
      ));
    }

    final device = _buildDevice(spec, patientId);

    return _PatientGenerated(
      today: today,
      last182Days: history,
      last6Months: weeks,
      device: device,
    );
  }

  /// For declining-trend patients (pt_006), historical amplitude scales
  /// linearly from `historicalPeakSteps` (182 days ago) down to
  /// `historicalBaselineSteps` (yesterday).
  /// For everyone else, just the baseline.
  double _historicalAmplitude(_ActivitySpec spec, int dayOffset) {
    if (!spec.hasDecayingTrend) {
      return spec.historicalBaselineSteps.toDouble();
    }
    // dayOffset goes 182 (oldest) → 1 (yesterday).
    final progress = (182 - dayOffset) / 181.0; // 0.0 → 1.0
    final peak = spec.historicalPeakSteps.toDouble();
    final base = spec.historicalBaselineSteps.toDouble();
    return peak + (base - peak) * progress;
  }

  /// Build a single 24-hour day, distributed by the intensity curve and
  /// (optionally) re-scaled so the day's totals exactly match the targets.
  DailyActivity _buildDay({
    required DateTime date,
    required int targetSteps,
    required double cadence,
    int? targetActiveMin,
    required Random rng,
  }) {
    if (targetSteps == 0) {
      return DailyActivity(
        date: date,
        hours: List.generate(
          24,
          (h) => HourlyActivity(
            hour: date.add(Duration(hours: h)),
            steps: 0,
            distanceFt: 0,
            timeInMotionMinutes: 0,
          ),
        ),
      );
    }

    // Stage 1: intensity-weighted raw steps per hour.
    final rawSteps = List<double>.generate(24, (h) {
      final intensity = _intensityCurve(h);
      if (intensity <= 0.001) return 0.0;
      final jitter = 0.75 + rng.nextDouble() * 0.5; // 0.75–1.25
      return intensity * jitter;
    });
    final rawSum = rawSteps.fold(0.0, (a, b) => a + b);
    final scale = rawSum > 0 ? targetSteps / rawSum : 0.0;

    // Stage 2: derived per-hour values.
    final hours = <HourlyActivity>[];
    var stepsAccum = 0;
    var minutesAccum = 0;
    final scaledSteps = List<int>.generate(
      24,
      (h) => (rawSteps[h] * scale).round(),
    );

    // Adjust for rounding so the total exactly matches targetSteps.
    final stepsDelta = targetSteps - scaledSteps.fold<int>(0, (a, b) => a + b);
    if (stepsDelta != 0) {
      // Apply the delta to whatever's the highest-activity hour to stay
      // realistic. If delta is negative (we overshot), pick the hour whose
      // value is largest enough to absorb the cut.
      final maxIdx = scaledSteps
          .asMap()
          .entries
          .reduce((a, b) => a.value >= b.value ? a : b)
          .key;
      scaledSteps[maxIdx] = (scaledSteps[maxIdx] + stepsDelta).clamp(0, 9999);
    }

    for (var h = 0; h < 24; h++) {
      final s = scaledSteps[h];
      final stride = 1.25 + rng.nextDouble() * 0.15;
      final distance = s * stride;
      var motionMin = (s / cadence).round();
      if (motionMin > 55) motionMin = 55;
      stepsAccum += s;
      minutesAccum += motionMin;
      hours.add(HourlyActivity(
        hour: date.add(Duration(hours: h)),
        steps: s,
        distanceFt: distance,
        timeInMotionMinutes: motionMin,
      ));
    }

    // Optional: clamp minutes to exactly targetActiveMin (today only).
    if (targetActiveMin != null && stepsAccum > 0) {
      final delta = targetActiveMin - minutesAccum;
      if (delta != 0) {
        // Distribute the delta across active hours.
        final activeIdxs =
            List.generate(24, (h) => h).where((h) => hours[h].steps > 0).toList();
        if (activeIdxs.isNotEmpty) {
          final perIdx = delta ~/ activeIdxs.length;
          var rem = delta - (perIdx * activeIdxs.length);
          for (var h in activeIdxs) {
            var newMin = hours[h].timeInMotionMinutes + perIdx;
            if (rem != 0) {
              final adj = rem > 0 ? 1 : -1;
              newMin += adj;
              rem -= adj;
            }
            newMin = newMin.clamp(0, 55);
            hours[h] = HourlyActivity(
              hour: hours[h].hour,
              steps: hours[h].steps,
              distanceFt: hours[h].distanceFt,
              timeInMotionMinutes: newMin,
            );
          }
        }
      }
    }

    return DailyActivity(date: date, hours: hours);
  }

  DeviceHealth _buildDevice(_ActivitySpec spec, String patientId) {
    final patient = FacilitySeed.patients.firstWhere((p) => p.id == patientId);
    return DeviceHealth(
      serialNumber: patient.deviceSerial ?? 'GS0000000000',
      firmwareVersion: '0.9.0',
      sensorModel: 'BMI270',
      batteryMv: spec.batteryMv,
      signalDbm: spec.signalDbm,
      lastDataReceived:
          DateTime.now().subtract(spec.lastSeenAgo),
    );
  }

  // ── Curves ─────────────────────────────────────────────────────────────

  /// Older-adult walking rhythm. Same shape as the existing
  /// `MockDataSource._intensityCurve`; kept duplicated rather than imported
  /// so the demo data layer is independent of the legacy single-walker one.
  static double _intensityCurve(int hourOfDay) {
    switch (hourOfDay) {
      case 0:
      case 1:
      case 2:
      case 3:
      case 4:
      case 5:
        return 0.0;
      case 6:
        return 0.15;
      case 7:
        return 0.55;
      case 8:
        return 0.70;
      case 9:
        return 0.45;
      case 10:
        return 0.30;
      case 11:
        return 0.50;
      case 12:
        return 0.75;
      case 13:
        return 0.35;
      case 14:
        return 0.20;
      case 15:
        return 0.40;
      case 16:
        return 0.55;
      case 17:
        return 0.70;
      case 18:
        return 0.60;
      case 19:
        return 0.40;
      case 20:
        return 0.25;
      case 21:
        return 0.20;
      case 22:
        return 0.10;
      case 23:
        return 0.0;
      default:
        return 0.0;
    }
  }

  /// Per-patient activity profile and device defaults.
  /// Targets come from spec §4.3.
  static final Map<String, _ActivitySpec> _activitySpecs = {
    'pt_001': _ActivitySpec(
      targetStepsToday: 387,
      targetActiveMinToday: 24,
      historicalBaselineSteps: 410,
      stepsPerActiveMinute: 16.1,
      batteryMv: 3550,
      signalDbm: -82,
      lastSeenAgo: const Duration(minutes: 47),
    ),
    'pt_002': _ActivitySpec(
      targetStepsToday: 142,
      targetActiveMinToday: 11,
      historicalBaselineSteps: 220,
      stepsPerActiveMinute: 12.9,
      batteryMv: 3520,
      signalDbm: -91,
      lastSeenAgo: const Duration(hours: 1, minutes: 12),
    ),
    'pt_003': _ActivitySpec(
      targetStepsToday: 0,
      targetActiveMinToday: 0,
      historicalBaselineSteps: 250,
      stepsPerActiveMinute: 14.5,
      batteryMv: 3120, // low — offline-y
      signalDbm: -108,
      lastSeenAgo: const Duration(hours: 9, minutes: 22),
    ),
    'pt_004': _ActivitySpec(
      targetStepsToday: 894,
      targetActiveMinToday: 47,
      historicalBaselineSteps: 920,
      stepsPerActiveMinute: 19.0,
      batteryMv: 3580,
      signalDbm: -75,
      lastSeenAgo: const Duration(minutes: 31),
    ),
    'pt_005': _ActivitySpec(
      targetStepsToday: 521,
      targetActiveMinToday: 32,
      historicalBaselineSteps: 540,
      stepsPerActiveMinute: 16.3,
      batteryMv: 3540,
      signalDbm: -84,
      lastSeenAgo: const Duration(minutes: 58),
    ),
    'pt_006': _ActivitySpec(
      targetStepsToday: 198,
      targetActiveMinToday: 14,
      historicalBaselineSteps: 210,
      historicalPeakSteps: 620,
      hasDecayingTrend: true,
      stepsPerActiveMinute: 14.1,
      batteryMv: 3470,
      signalDbm: -97,
      lastSeenAgo: const Duration(hours: 2, minutes: 5),
    ),
    'pt_007': _ActivitySpec(
      targetStepsToday: 612,
      targetActiveMinToday: 38,
      historicalBaselineSteps: 580,
      stepsPerActiveMinute: 16.1,
      batteryMv: 3560,
      signalDbm: -80,
      lastSeenAgo: const Duration(minutes: 22),
    ),
    'pt_008': _ActivitySpec(
      targetStepsToday: 445,
      targetActiveMinToday: 28,
      historicalBaselineSteps: 460,
      stepsPerActiveMinute: 15.9,
      batteryMv: 3540,
      signalDbm: -86,
      lastSeenAgo: const Duration(minutes: 39),
    ),
    'pt_009': _ActivitySpec(
      targetStepsToday: 234,
      targetActiveMinToday: 18,
      historicalBaselineSteps: 245,
      stepsPerActiveMinute: 13.0,
      batteryMv: 3500,
      signalDbm: -89,
      lastSeenAgo: const Duration(hours: 1, minutes: 4),
    ),
    'pt_010': _ActivitySpec(
      targetStepsToday: 156,
      targetActiveMinToday: 12,
      historicalBaselineSteps: 170,
      stepsPerActiveMinute: 13.0,
      batteryMv: 3490,
      signalDbm: -94,
      lastSeenAgo: const Duration(hours: 1, minutes: 38),
    ),
  };
}

class _ActivitySpec {
  final int targetStepsToday;
  final int targetActiveMinToday;
  final int historicalBaselineSteps;
  final int historicalPeakSteps;
  final bool hasDecayingTrend;
  final double stepsPerActiveMinute;
  final int batteryMv;
  final int signalDbm;
  final Duration lastSeenAgo;

  _ActivitySpec({
    required this.targetStepsToday,
    required this.targetActiveMinToday,
    required this.historicalBaselineSteps,
    this.historicalPeakSteps = 0,
    this.hasDecayingTrend = false,
    required this.stepsPerActiveMinute,
    required this.batteryMv,
    required this.signalDbm,
    required this.lastSeenAgo,
  });
}

class _PatientGenerated {
  final DailyActivity today;
  final List<DailyActivity> last182Days;
  final List<WeeklyActivity> last6Months;
  final DeviceHealth device;

  _PatientGenerated({
    required this.today,
    required this.last182Days,
    required this.last6Months,
    required this.device,
  });
}
