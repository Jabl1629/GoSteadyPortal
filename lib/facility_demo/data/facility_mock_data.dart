import 'dart:math';

import '../../api/api_models.dart' as api;
import '../../data/facility_repository.dart';
import '../../models/activity.dart';
import '../../models/device.dart';
import '../models/facility.dart';
import '../models/notification.dart';
import '../models/patient.dart';
import '../models/unit.dart';
import 'facility_seed.dart';
import 'notification_engine.dart';

/// Mock data source for the facility demo. Implements [FacilityRepository]
/// so the live build's [LiveFacilityRepository] (added in 2B-0; wired in
/// 2B-FAC-R) is a drop-in alternative — screens depend only on the
/// abstraction.
///
/// Surface mirrors the eventual `ApiClient` (patient-centric methods,
/// hierarchy snapshot at query time) per facility-demo.md §6.2.
///
/// Determinism: each patient's data is seeded from `patientId.hashCode`, so
/// reloading the page or moving between dev machines produces identical
/// numbers — important for the conference where we want predictable demos.
class FacilityMockData implements FacilityRepository {
  FacilityMockData();

  // Cached generated data per patient. Lazy: filled on first access.
  final Map<String, _PatientGenerated> _cache = {};

  // ── Lifecycle (no-ops in demo) ──────────────────────────────────────────
  // Demo data is generated lazily on access; no need to prime or refresh.

  @override
  Future<void> primeAtSignIn() async {}

  @override
  Future<void> refreshCensus() async {}

  @override
  Future<void> refreshPatientDetail(String patientId) async {}

  @override
  void clearOnSignOut() {
    _cache.clear();
  }

  // ── Facility / unit / patient lookups (sync) ───────────────────────────

  @override
  List<Facility> allFacilities() => FacilitySeed.facilities;

  @override
  List<Unit> unitsForFacility(String facilityId) => FacilitySeed.units
      .where((u) => u.facilityId == facilityId)
      .toList(growable: false);

  /// All units across all facilities (helper for the selector dropdown).
  @override
  List<Unit> allUnits() => FacilitySeed.units;

  /// All patient summaries whose unit is in [selectedUnitIds]. Empty set
  /// returns no patients (UI default is "all selected").
  @override
  List<PatientSummary> patientsForSelection(Set<String> selectedUnitIds) {
    return FacilitySeed.patients
        .where((p) => selectedUnitIds.contains(p.unitId))
        .map(_summaryFor)
        .toList(growable: false);
  }

  @override
  Future<List<DiscontinuedSummary>> discontinuedPatients() async {
    // Demo has no discharged set — the toggle renders its empty state.
    return const [];
  }

  // ── Per-patient methods (async; demo wraps sync data in Future) ───────

  /// Lookup a single patient.
  @override
  Future<Patient> patientById(String patientId) async =>
      FacilitySeed.patients.firstWhere((p) => p.id == patientId);

  @override
  Future<DailyActivity> todayFor(String patientId) async =>
      _gen(patientId).today;

  /// 7 days of history, oldest-first.
  @override
  Future<List<DailyActivity>> last7DaysFor(String patientId) async {
    final all = _gen(patientId).last182Days;
    return all.sublist(all.length - 7);
  }

  /// 30 days of history, oldest-first.
  @override
  Future<List<DailyActivity>> last30DaysFor(String patientId) async {
    final all = _gen(patientId).last182Days;
    return all.sublist(all.length - 30);
  }

  /// 26 weeks of history, oldest-first.
  @override
  Future<List<WeeklyActivity>> last6MonthsFor(String patientId) async =>
      _gen(patientId).last6Months;

  @override
  Future<DeviceHealth> deviceFor(String patientId) async =>
      _gen(patientId).device;

  /// Snapshot used by NotificationEngine. Median is computed over each
  /// window's totalSteps, sorted middle-element.
  @override
  Future<NotificationContext> notificationContextFor(String patientId) async {
    final gen = _gen(patientId);
    final allHistory = gen.last182Days;
    final last7Steps = allHistory
        .sublist(allHistory.length - 7)
        .map((d) => d.totalSteps)
        .toList()
      ..sort();
    final prior23Steps = allHistory
        .sublist(allHistory.length - 30, allHistory.length - 7)
        .map((d) => d.totalSteps)
        .toList()
      ..sort();
    final med7 = last7Steps.isEmpty ? 0 : last7Steps[last7Steps.length ~/ 2];
    final medPrior =
        prior23Steps.isEmpty ? 0 : prior23Steps[prior23Steps.length ~/ 2];
    final today = gen.today;
    final hasData = today.totalSteps > 0 || today.totalTimeInMotionMinutes > 0;
    return NotificationContext(
      stepsToday: today.totalSteps,
      activeMinutesToday: today.totalTimeInMotionMinutes,
      hasDataToday: hasData,
      median7Day: med7,
      medianPrior23Day: medPrior,
      lastDataAgo: DateTime.now().difference(gen.device.lastDataReceived),
    );
  }

  /// Demo notifications come from the local [NotificationEngine] —
  /// three rules evaluated against [notificationContextFor]. Per
  /// phase-2b-fac-r L6, this engine is bypassed entirely in the live
  /// build, where notifications come from the server's Alert History.
  @override
  Future<List<PatientNotification>> notificationsFor(String patientId) async {
    final ctx = await notificationContextFor(patientId);
    return const NotificationEngine().evaluate(patientId, ctx);
  }

  /// All stats the list-view table needs for one patient, derived from
  /// the same 182-day generated history that drives the tile view + charts.
  /// Trends compare last N days vs the immediately prior N days using
  /// `Trend.compute` (±5% threshold).
  @override
  Future<PatientRowStats> rowStatsFor(String patientId) async {
    final gen = _gen(patientId);
    final history = gen.last182Days;

    final last7 = history.sublist(history.length - 7);
    final prior7 = history.sublist(history.length - 14, history.length - 7);
    final last30 = history.sublist(history.length - 30);
    final last3 = history.sublist(history.length - 3);
    // Gait trend compares the 3-day average to the prior 30-day baseline
    // (days 4-33). Day-over-day noise in seeded gait data is too large
    // for a 3d-vs-3d comparison to catch real slow decline.
    final priorGaitWindow =
        history.sublist(history.length - 33, history.length - 3);

    double meanActiveMin(List<DailyActivity> days) {
      if (days.isEmpty) return 0;
      final total = days.fold<int>(0, (s, d) => s + d.totalTimeInMotionMinutes);
      return total / days.length;
    }

    double meanSteps(List<DailyActivity> days) {
      if (days.isEmpty) return 0;
      final total = days.fold<int>(0, (s, d) => s + d.totalSteps);
      return total / days.length;
    }

    double meanGait(List<DailyActivity> days) {
      final active = days.where((d) => d.avgGaitSpeedFts > 0).toList();
      if (active.isEmpty) return 0;
      final total = active.fold<double>(0, (s, d) => s + d.avgGaitSpeedFts);
      return total / active.length;
    }

    final activeMin7d = meanActiveMin(last7);
    final activeMinPrior7d = meanActiveMin(prior7);
    final activeMin30d = meanActiveMin(last30);
    final activeMinTrend = Trend.compute(activeMin7d, activeMinPrior7d);
    final stepsRecent = meanSteps(last7);
    final stepsPrior = meanSteps(prior7);
    final stepsTrend = Trend.compute(stepsRecent, stepsPrior);
    // Gait speed degrades slowly; small absolute changes are clinically
    // meaningful, so we use a tighter (3%) threshold than for step counts.
    final gaitRecent = meanGait(last3);
    final gaitPrior = meanGait(priorGaitWindow);
    final gaitTrend = Trend.compute(gaitRecent, gaitPrior, threshold: 0.03);

    return PatientRowStats(
      alertsThisWeek: _activitySpecs[patientId]?.alertsThisWeek ?? 0,
      activeMinutesToday: gen.today.totalTimeInMotionMinutes,
      activeMinutes7dAvg: activeMin7d,
      activeMinutesPrior7dAvg: activeMinPrior7d,
      activeMinutesTrend7d: activeMinTrend,
      activeMinutes30dAvg: activeMin30d,
      stepsToday: gen.today.totalSteps,
      stepsTrend7d: stepsTrend,
      stepsRecentAvg: stepsRecent,
      stepsPriorAvg: stepsPrior,
      gaitSpeed3dAvg: gaitRecent,
      gaitSpeedTrend: gaitTrend,
      gaitSpeedPriorAvg: gaitPrior,
    );
  }

  // ── Internals ──────────────────────────────────────────────────────────

  PatientSummary _summaryFor(Patient p) {
    // Read today's data directly from the cache (not via todayFor, which
    // is now async per phase-2b-fac-r L2). The mock data layer is
    // synchronous internally; the async wrappers are just for interface
    // parity with the live impl.
    final today = _gen(p.id).today;
    final hasData = today.totalSteps > 0 || today.totalTimeInMotionMinutes > 0;
    return PatientSummary(
      patient: p,
      stepsToday: today.totalSteps,
      activeMinutesToday: today.totalTimeInMotionMinutes,
      hasDataToday: hasData,
    );
  }

  // ── Writes (2B-FAC-W) — demo no-ops returning synthesized responses
  //
  // Each method returns a shape that matches the live API but doesn't
  // actually mutate the mock state. Per phase-2b-fac-w L2: marketing
  // demo is non-interactive at the data layer; what matters is that
  // the UI flows compile + run without exceptions. A future polish
  // pass could make these actually mutate the seed if demo
  // interactivity becomes important.

  @override
  Future<api.AckAlertResponse> ackAlert({
    required String patientId,
    required String sk,
    String? notes,
  }) async {
    return api.AckAlertResponse(
      alert: api.AlertRow(
        eventTimestamp: DateTime.now(),
        eventTimestampRaw: sk.split('#').first,
        alertType: sk.split('#').last,
        severity: 'standard',
        acknowledged: true,
      ),
      wasAlreadyAcknowledged: false,
    );
  }

  @override
  Future<api.PatientDetailResponse> createPatient({
    required String displayName,
    required String censusId,
    required String room,
    String? deviceSerial,
  }) async {
    final id = 'pat_demo_${DateTime.now().millisecondsSinceEpoch}';
    return api.PatientDetailResponse(
      patient: api.PatientFull(
        patientId: id,
        displayName: displayName,
        status: 'active',
        censusId: censusId,
        room: room,
        currentDevice: deviceSerial == null
            ? null
            : api.CurrentDevice(
                serialNumber: deviceSerial,
                status: 'provisioned',
              ),
      ),
    );
  }

  @override
  Future<api.PatientDetailResponse> updatePatient({
    required String patientId,
    String? displayName,
    String? censusId,
    String? room,
  }) async {
    return api.PatientDetailResponse(
      patient: api.PatientFull(
        patientId: patientId,
        displayName: displayName ?? '',
        status: 'active',
        censusId: censusId,
        room: room,
      ),
    );
  }

  @override
  Future<api.DischargeResponse> dischargePatient({
    required String patientId,
    String? reason,
    String? notes,
  }) async {
    return api.DischargeResponse(
      patient: api.PatientFull(
        patientId: patientId,
        displayName: '',
        status: 'discharged',
      ),
      cascade: const api.DischargeCascadeInfo(
        devicesEnded: 0,
        deviceSerials: [],
        wipeRequested: false,
      ),
    );
  }

  @override
  Future<api.PatientDetailResponse> resumeMonitoring({
    required String patientId,
    required String censusId,
    required String room,
    required String deviceSerial,
  }) async {
    // Demo: flip the (discharged) record back to active with the new device.
    return api.PatientDetailResponse(
      patient: api.PatientFull(
        patientId: patientId,
        displayName: '',
        status: 'active',
        censusId: censusId,
        room: room,
        currentDevice: api.CurrentDevice(
          serialNumber: deviceSerial,
          status: 'provisioned',
        ),
      ),
    );
  }

  @override
  Future<api.NotificationsPauseResponse> pauseNotifications({
    required String patientId,
    required int days,
    required String reason,
  }) async {
    return api.NotificationsPauseResponse(
      notificationsPaused: api.NotificationsPaused(
        until: DateTime.now().add(Duration(days: days)),
        reason: reason,
        pausedAt: DateTime.now(),
      ),
    );
  }

  @override
  Future<api.NotificationsPauseResponse> resumeNotifications(
    String patientId,
  ) async {
    return const api.NotificationsPauseResponse();
  }

  @override
  Future<api.CareNoteResponse> updateCareNote({
    required String patientId,
    required String text,
  }) async {
    if (text.isEmpty) return const api.CareNoteResponse();
    return api.CareNoteResponse(
      careNote: api.CareNote(
        text: text,
        updatedBy: 'demo_user',
        updatedByName: 'Demo Caregiver',
        updatedAt: DateTime.now(),
      ),
    );
  }

  @override
  Future<api.DeviceResponse> replaceDevice({
    required String patientId,
    required String? currentSerial,
    required String newSerial,
  }) async {
    return api.DeviceResponse(
      serialNumber: newSerial,
      status: 'provisioned',
    );
  }

  @override
  Future<List<api.MonitoringSession>> monitoringHistory(String patientId) async {
    // Demo: synthesize a small two-session timeline — one prior (ended) period
    // and the current (ongoing) one — so the history modal renders.
    final now = DateTime.now();
    final ongoingStart = now.subtract(const Duration(days: 5));
    final priorStart = now.subtract(const Duration(days: 40));
    final priorEnd = now.subtract(const Duration(days: 6));
    return [
      api.MonitoringSession(
        serialNumber: 'GS0000009001',
        startedAt: ongoingStart,
        endedAt: null,
        ongoing: true,
      ),
      api.MonitoringSession(
        serialNumber: 'GS0000009000',
        startedAt: priorStart,
        endedAt: priorEnd,
        ongoing: false,
        durationSeconds: priorEnd.difference(priorStart).inSeconds,
      ),
    ];
  }

  _PatientGenerated _gen(String patientId) {
    return _cache.putIfAbsent(patientId, () => _generateFor(patientId));
  }

  _PatientGenerated _generateFor(String patientId) {
    final spec = _activitySpecs[patientId]!;
    // Two independent seeded streams — keeping gait-speed RNG separate
    // means adding/changing the gait-speed feature doesn't shift
    // step/distance/minutes generation, which would otherwise reshuffle
    // which patients trigger which notifications (the demo cases are
    // tuned around specific seeded outputs).
    final rng = Random(patientId.hashCode);
    final gaitRng = Random(patientId.hashCode ^ 0x7AE8D);
    final now = DateTime.now();
    final startOfToday = DateTime(now.year, now.month, now.day);

    // 182-day history, oldest first. Newest is yesterday (today is separate).
    final history = <DailyActivity>[];
    for (var dayOffset = 182; dayOffset >= 1; dayOffset--) {
      final date = startOfToday.subtract(Duration(days: dayOffset));
      final amplitude = _historicalAmplitude(spec, dayOffset);
      final dayVariance = 0.75 + rng.nextDouble() * 0.5; // 0.75–1.25
      final dailySteps = (amplitude * dayVariance).round();
      final dayGait = _historicalGaitSpeed(spec, dayOffset);
      history.add(_buildDay(
        date: date,
        targetSteps: dailySteps,
        cadence: spec.stepsPerActiveMinute,
        baselineGaitSpeedFts: dayGait,
        rng: rng,
        gaitRng: gaitRng,
      ));
    }

    // Today: forced exactly to spec target so the tile values match §4.3.
    final today = _buildDay(
      date: startOfToday,
      targetSteps: spec.targetStepsToday,
      cadence: spec.stepsPerActiveMinute,
      baselineGaitSpeedFts: spec.baselineGaitSpeedFts,
      targetActiveMin: spec.targetActiveMinToday,
      rng: rng,
      gaitRng: gaitRng,
    );

    // Aggregate history into 26 weeks (oldest first).
    final weeks = <WeeklyActivity>[];
    for (var i = 0; i < history.length; i += 7) {
      final chunk = history.sublist(i, min(i + 7, history.length));
      var weightedNum = 0.0;
      var weightedDen = 0;
      var weekMin = double.infinity;
      var weekMax = 0.0;
      for (final d in chunk) {
        if (d.totalTimeInMotionMinutes <= 0) continue;
        final dayAvg = d.avgGaitSpeedFts;
        if (dayAvg <= 0) continue;
        weightedNum += dayAvg * d.totalTimeInMotionMinutes;
        weightedDen += d.totalTimeInMotionMinutes;
        if (d.minGaitSpeedFts > 0 && d.minGaitSpeedFts < weekMin) {
          weekMin = d.minGaitSpeedFts;
        }
        if (d.maxGaitSpeedFts > weekMax) weekMax = d.maxGaitSpeedFts;
      }
      final weekAvg = weightedDen == 0 ? 0.0 : weightedNum / weightedDen;
      weeks.add(WeeklyActivity(
        weekStart: chunk.first.date,
        totalSteps: chunk.fold(0, (s, d) => s + d.totalSteps),
        totalDistanceFt: chunk.fold(0.0, (s, d) => s + d.totalDistanceFt),
        totalTimeInMotionMinutes:
            chunk.fold(0, (s, d) => s + d.totalTimeInMotionMinutes),
        avgGaitSpeedFts: weekAvg,
        minGaitSpeedFts: weekMin == double.infinity ? 0 : weekMin,
        maxGaitSpeedFts: weekMax,
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

  /// Gait speed counterpart of [_historicalAmplitude]. For a declining
  /// patient, gait speed slopes from `historicalPeakGaitSpeedFts` down to
  /// `baselineGaitSpeedFts` over the 182-day window.
  double _historicalGaitSpeed(_ActivitySpec spec, int dayOffset) {
    if (!spec.hasDecayingTrend || spec.historicalPeakGaitSpeedFts <= 0) {
      return spec.baselineGaitSpeedFts;
    }
    final progress = (182 - dayOffset) / 181.0;
    final peak = spec.historicalPeakGaitSpeedFts;
    final base = spec.baselineGaitSpeedFts;
    return peak + (base - peak) * progress;
  }

  /// Build a single 24-hour day, distributed by the intensity curve and
  /// (optionally) re-scaled so the day's totals exactly match the targets.
  DailyActivity _buildDay({
    required DateTime date,
    required int targetSteps,
    required double cadence,
    required double baselineGaitSpeedFts,
    int? targetActiveMin,
    required Random rng,
    required Random gaitRng,
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
      // Gait speed only when the patient walked this hour. Modulate by
      // intensity so peak hours show stronger pace, plus jitter. Uses an
      // isolated RNG stream so this never shifts step/distance generation.
      double avgSpeed = 0;
      double minSpeed = 0;
      double maxSpeed = 0;
      if (s > 0) {
        final intensity = _intensityCurve(h);
        final paceJitter = 0.90 + gaitRng.nextDouble() * 0.20;
        avgSpeed = baselineGaitSpeedFts * (0.85 + intensity * 0.30) * paceJitter;
        minSpeed = avgSpeed * (0.65 + gaitRng.nextDouble() * 0.10);
        maxSpeed = avgSpeed * (1.20 + gaitRng.nextDouble() * 0.20);
      }
      hours.add(HourlyActivity(
        hour: date.add(Duration(hours: h)),
        steps: s,
        distanceFt: distance,
        timeInMotionMinutes: motionMin,
        avgGaitSpeedFts: avgSpeed,
        minGaitSpeedFts: minSpeed,
        maxGaitSpeedFts: maxSpeed,
      ));
    }

    // Optional: clamp minutes to exactly targetActiveMin (today only).
    if (targetActiveMin != null && stepsAccum > 0) {
      final delta = targetActiveMin - minutesAccum;
      if (delta != 0) {
        // Distribute the delta across active hours.
        final activeIdxs = List.generate(24, (h) => h)
            .where((h) => hours[h].steps > 0)
            .toList();
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
              avgGaitSpeedFts: hours[h].avgGaitSpeedFts,
              minGaitSpeedFts: hours[h].minGaitSpeedFts,
              maxGaitSpeedFts: hours[h].maxGaitSpeedFts,
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
      lastDataReceived: DateTime.now().subtract(spec.lastSeenAgo),
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
      baselineGaitSpeedFts: 2.13,
      alertsThisWeek: 1,
    ),
    'pt_002': _ActivitySpec(
      // Robert Chen — "below typical activity" demo case. Today drops
      // further from 142/11 to 78/6 so the daily values land in the
      // rust tier; baseline 280 keeps the 7d/30d averages mid-range and
      // the contrast obvious.
      targetStepsToday: 78,
      targetActiveMinToday: 6,
      historicalBaselineSteps: 280,
      stepsPerActiveMinute: 12.9,
      batteryMv: 3520,
      signalDbm: -91,
      lastSeenAgo: const Duration(hours: 1, minutes: 12),
      baselineGaitSpeedFts: 1.80,
      alertsThisWeek: 3,
    ),
    'pt_003': _ActivitySpec(
      targetStepsToday: 0,
      targetActiveMinToday: 0,
      historicalBaselineSteps: 250,
      stepsPerActiveMinute: 14.5,
      batteryMv: 3120, // low — offline-y
      signalDbm: -108,
      lastSeenAgo: const Duration(hours: 9, minutes: 22),
      baselineGaitSpeedFts: 2.03,
      alertsThisWeek: 2,
    ),
    'pt_004': _ActivitySpec(
      // Eleanor Park — the facility's most active resident. Today and
      // baselines both pushed higher (1240 / 68 vs 894 / 47) so her row
      // anchors the sage / high-tier end of the variance demo.
      targetStepsToday: 1240,
      targetActiveMinToday: 68,
      historicalBaselineSteps: 1100,
      stepsPerActiveMinute: 19.0,
      batteryMv: 3580,
      signalDbm: -75,
      lastSeenAgo: const Duration(minutes: 31),
      baselineGaitSpeedFts: 2.79,
      alertsThisWeek: 0,
    ),
    'pt_005': _ActivitySpec(
      targetStepsToday: 521,
      targetActiveMinToday: 32,
      historicalBaselineSteps: 540,
      stepsPerActiveMinute: 16.3,
      batteryMv: 3540,
      signalDbm: -84,
      lastSeenAgo: const Duration(minutes: 58),
      baselineGaitSpeedFts: 2.30,
      alertsThisWeek: 1,
    ),
    'pt_006': _ActivitySpec(
      // Frank Kowalski — "declining trend" demo case. Peak bumped from
      // 620 -> 950 so the slope across the comparison windows lands
      // unambiguously below the 85% threshold. Gait speed also declines
      // (0.78 -> 0.50 m/s over 6 months) so the new gait-speed chart
      // visibly tells the same story.
      targetStepsToday: 198,
      targetActiveMinToday: 14,
      historicalBaselineSteps: 210,
      historicalPeakSteps: 950,
      hasDecayingTrend: true,
      stepsPerActiveMinute: 14.1,
      batteryMv: 3470,
      signalDbm: -97,
      lastSeenAgo: const Duration(hours: 2, minutes: 5),
      baselineGaitSpeedFts: 1.64,
      historicalPeakGaitSpeedFts: 2.56,
      alertsThisWeek: 5,
    ),
    'pt_007': _ActivitySpec(
      // Dorothy Williams — strong rehab recovery. Pushed up to 720 / 51
      // (was 612 / 38) so she pairs with Eleanor at the high-activity
      // end of the color-tier spread.
      targetStepsToday: 720,
      targetActiveMinToday: 51,
      historicalBaselineSteps: 720,
      stepsPerActiveMinute: 16.1,
      batteryMv: 3560,
      signalDbm: -80,
      lastSeenAgo: const Duration(minutes: 22),
      baselineGaitSpeedFts: 2.46,
      alertsThisWeek: 1,
    ),
    'pt_008': _ActivitySpec(
      targetStepsToday: 445,
      targetActiveMinToday: 28,
      historicalBaselineSteps: 460,
      stepsPerActiveMinute: 15.9,
      batteryMv: 3540,
      signalDbm: -86,
      lastSeenAgo: const Duration(minutes: 39),
      baselineGaitSpeedFts: 2.13,
      alertsThisWeek: 0,
    ),
    'pt_009': _ActivitySpec(
      // Ruth Patel — low-baseline long-term resident. Pulled down to
      // 145 / 11 (was 234 / 18) so she lands in the amber tier alongside
      // George + Frank rather than mid-range.
      targetStepsToday: 145,
      targetActiveMinToday: 11,
      historicalBaselineSteps: 145,
      stepsPerActiveMinute: 13.0,
      batteryMv: 3500,
      signalDbm: -89,
      lastSeenAgo: const Duration(hours: 1, minutes: 4),
      baselineGaitSpeedFts: 1.80,
      alertsThisWeek: 1,
    ),
    'pt_010': _ActivitySpec(
      targetStepsToday: 156,
      targetActiveMinToday: 12,
      historicalBaselineSteps: 170,
      stepsPerActiveMinute: 13.0,
      batteryMv: 3490,
      signalDbm: -94,
      lastSeenAgo: const Duration(hours: 1, minutes: 38),
      baselineGaitSpeedFts: 1.64,
      alertsThisWeek: 2,
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

  /// Today / recent-baseline average gait speed in m/s. Walker users
  /// typically span ~0.4–0.9 m/s.
  final double baselineGaitSpeedFts;

  /// 6-months-ago peak gait speed for patients with `hasDecayingTrend`.
  /// Ignored otherwise.
  final double historicalPeakGaitSpeedFts;

  /// Total alerts fired for this patient over the last 7 days. Pre-baked
  /// per-patient so the list view's "Alerts (7d)" column shows a
  /// plausible, deterministic count. Higher for patients with current
  /// active notifications.
  final int alertsThisWeek;

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
    required this.baselineGaitSpeedFts,
    this.historicalPeakGaitSpeedFts = 0,
    this.alertsThisWeek = 0,
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

/// Direction of a derived trend. Threshold of ±5% by default — anything
/// inside the band is treated as "flat" so we don't show meaningless
/// up/down indicators on noise.
enum Trend {
  up,
  down,
  flat;

  static const double defaultThreshold = 0.05;

  /// Compare a recent-period mean to a prior-period mean. Returns
  /// `Trend.flat` if either input is zero (no signal).
  static Trend compute(double recent, double prior,
      {double threshold = defaultThreshold}) {
    if (prior <= 0 || recent <= 0) return Trend.flat;
    final delta = (recent - prior) / prior;
    if (delta > threshold) return Trend.up;
    if (delta < -threshold) return Trend.down;
    return Trend.flat;
  }

  /// Percent delta from prior → recent, e.g. -12 means "12% lower."
  /// Returns 0 if either input is zero.
  static double percentDelta(double recent, double prior) {
    if (prior <= 0 || recent <= 0) return 0;
    return ((recent - prior) / prior) * 100;
  }
}

/// Pre-computed per-patient stats consumed by the list view. Built once
/// per patient by `FacilityMockData.rowStatsFor`.
class PatientRowStats {
  final int alertsThisWeek;
  final int activeMinutesToday;
  final double activeMinutes7dAvg;          // mean of last 7 days
  final double activeMinutesPrior7dAvg;     // mean of days 8-14
  final Trend activeMinutesTrend7d;         // 7d vs prior 7d, ±5% threshold
  final double activeMinutes30dAvg;         // still computed; not surfaced
  final int stepsToday;
  final Trend stepsTrend7d;
  final double stepsRecentAvg;              // mean of last 7 days
  final double stepsPriorAvg;               // mean of days 8-14
  final double gaitSpeed3dAvg;              // ft/s, last 3 days
  final Trend gaitSpeedTrend;
  final double gaitSpeedPriorAvg;

  const PatientRowStats({
    required this.alertsThisWeek,
    required this.activeMinutesToday,
    required this.activeMinutes7dAvg,
    required this.activeMinutesPrior7dAvg,
    required this.activeMinutesTrend7d,
    required this.activeMinutes30dAvg,
    required this.stepsToday,
    required this.stepsTrend7d,
    required this.stepsRecentAvg,
    required this.stepsPriorAvg,
    required this.gaitSpeed3dAvg,
    required this.gaitSpeedTrend,
    required this.gaitSpeedPriorAvg,
  });
}
