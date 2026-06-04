import '../api/api_client.dart';
import '../api/api_models.dart';
import '../api/session_adapter.dart';
import '../facility_demo/data/facility_mock_data.dart' show PatientRowStats, Trend;
import '../facility_demo/data/notification_engine.dart';
import '../facility_demo/models/facility.dart';
import '../facility_demo/models/notification.dart';
import '../facility_demo/models/patient.dart';
import '../facility_demo/models/unit.dart';
import '../models/activity.dart';
import '../models/device.dart';
import 'facility_repository.dart';

/// `ApiClient`-backed implementation of [FacilityRepository].
///
/// Per phase-2b-fac-r-facility-reads.md:
///   - L2 hybrid sync/async: Census-level data served sync from the
///     `MePatientsResponse` cache populated by [primeAtSignIn]; per-
///     patient methods fetch + cache on demand.
///   - L7 client-side activity aggregation via [SessionAdapter].
///   - L13 polling refetches page 1 of `/me/patients` only.
///
/// **This first slice (2B-FAC-R Phase A) keeps the cache layer
/// simple** — no TTL eviction, no polling, no lazy-row throttle.
/// Subsequent commits add those per the spec L3 / L5 / L12.
class LiveFacilityRepository implements FacilityRepository {
  final ApiClient _api;

  LiveFacilityRepository({required ApiClient api}) : _api = api;

  // ── Caches ────────────────────────────────────────────────────

  /// All-pages concatenated `/me/patients` response. Populated by
  /// [primeAtSignIn]; cleared by [clearOnSignOut].
  List<MePatientSummary>? _mePatients;

  /// Per-patient detail caches with 30-second TTL + in-flight Future
  /// dedup per phase-2b-fac-r L12. Concurrent calls for the same key
  /// share one HTTP fetch; subsequent calls within the TTL window
  /// hit the cache (no HTTP). Entries are evicted by [_TimedCache.evict]
  /// from the explicit `refresh*()` methods and by [clearOnSignOut].
  final _TimedCache<String, PatientFull> _patientDetailCache = _TimedCache();
  final _TimedCache<String, List<ActivitySession>> _activity24hCache =
      _TimedCache();
  final _TimedCache<String, List<ActivitySession>> _activity7dCache =
      _TimedCache();
  final _TimedCache<String, List<ActivitySession>> _activity30dCache =
      _TimedCache();
  final _TimedCache<String, List<AlertRow>> _alertsCache = _TimedCache();

  // ── Lifecycle ─────────────────────────────────────────────────

  @override
  Future<void> primeAtSignIn() async {
    final all = <MePatientSummary>[];
    String? cursor;
    do {
      final page = await _api.getMyPatients(cursor: cursor);
      all.addAll(page.patients);
      cursor = page.nextCursor;
    } while (cursor != null && cursor.isNotEmpty);
    _mePatients = all;
  }

  @override
  Future<void> refreshCensus() async {
    // Per L13: refetch page 1 only on poll; replace the cache slice.
    final page = await _api.getMyPatients();
    // For now (no polling-driven refresh wired yet), just replace the
    // whole cache. When polling lands, this will splice page 1 only.
    _mePatients = page.patients;
  }

  @override
  Future<void> refreshPatientDetail(String patientId) async {
    // Evict the per-patient cache entries so the next fetch hits HTTP
    // instead of the now-stale TTL-cache value. In-flight fetches are
    // not cancelled — if a poll tick raced with an ongoing fetch, the
    // ongoing fetch completes and its result populates the cache; the
    // very next caller after this `evict` sees a miss and re-fetches.
    _patientDetailCache.evict(patientId);
    _activity24hCache.evict(patientId);
    _activity7dCache.evict(patientId);
    _activity30dCache.evict(patientId);
    _alertsCache.evict(patientId);
    // Eager refetch — caller awaits the parallel chain.
    await Future.wait([
      _fetchPatientDetail(patientId),
      _fetchActivity(patientId, ActivityRange.h24),
      _fetchAlerts(patientId, AlertStatus.unacknowledged),
    ]);
  }

  @override
  void clearOnSignOut() {
    _mePatients = null;
    _patientDetailCache.clear();
    _activity24hCache.clear();
    _activity7dCache.clear();
    _activity30dCache.clear();
    _alertsCache.clear();
  }

  // ── Census-level (sync; backed by _mePatients cache) ─────────

  /// Derive unique facilities from the cached /me/patients response.
  @override
  List<Facility> allFacilities() {
    final patients = _mePatients ?? const [];
    final seen = <String, Facility>{};
    for (final p in patients) {
      final id = p.facilityId;
      if (id == null || id.isEmpty || seen.containsKey(id)) continue;
      seen[id] = Facility(id: id, displayName: p.facilityName ?? id);
    }
    return seen.values.toList(growable: false);
  }

  @override
  List<Unit> unitsForFacility(String facilityId) {
    return allUnits()
        .where((u) => u.facilityId == facilityId)
        .toList(growable: false);
  }

  @override
  List<Unit> allUnits() {
    final patients = _mePatients ?? const [];
    final seen = <String, Unit>{};
    for (final p in patients) {
      final cid = p.censusId;
      final fid = p.facilityId;
      if (cid == null || cid.isEmpty || seen.containsKey(cid)) continue;
      seen[cid] = Unit(
        id: cid,
        facilityId: fid ?? '',
        displayName: p.censusName ?? cid,
      );
    }
    return seen.values.toList(growable: false);
  }

  @override
  List<PatientSummary> patientsForSelection(Set<String> selectedUnitIds) {
    final patients = _mePatients ?? const [];
    return patients
        .where((p) =>
            p.censusId != null && selectedUnitIds.contains(p.censusId))
        .map(_mePatientToSummary)
        .toList(growable: false);
  }

  @override
  Future<List<DiscontinuedSummary>> discontinuedPatients() async {
    // `/me/patients?status=discontinued` — the discharged set, same GSI as the
    // active roster (status_patientId begins_with "discharged_"). Fetched on
    // demand; not part of the sign-in prime.
    final page = await _api.getMyPatients(status: 'discontinued');
    return page.patients
        .map((p) => DiscontinuedSummary(
              patientId: p.patientId,
              displayName: p.displayName,
              censusName: p.censusName,
              dischargedAt: p.dischargedAt,
            ))
        .toList(growable: false);
  }

  // ── Per-patient (async; cache + fetch on miss) ───────────────

  @override
  Future<Patient> patientById(String patientId) async {
    final full = await _fetchPatientDetail(patientId);
    return Patient(
      id: full.patientId,
      displayName: full.displayName,
      facilityId: full.facilityId ?? '',
      unitId: full.censusId ?? '',
      room: full.room ?? '',
      deviceSerial: full.currentDevice?.serialNumber,
      status: full.status == 'discharged'
          ? PatientStatus.discharged
          : PatientStatus.active,
      careNote: full.careNote,
      notificationsPaused: full.notificationsPaused,
    );
  }

  @override
  Future<DailyActivity> todayFor(String patientId) async {
    final sessions = await _fetchActivity(patientId, ActivityRange.h24);
    return SessionAdapter.toToday(sessions);
  }

  @override
  Future<List<DailyActivity>> last7DaysFor(String patientId) async {
    final sessions = await _fetchActivity(patientId, ActivityRange.d7);
    return SessionAdapter.toDailyList(sessions);
  }

  @override
  Future<List<DailyActivity>> last30DaysFor(String patientId) async {
    final sessions = await _fetchActivity(patientId, ActivityRange.d30);
    return SessionAdapter.toDailyList(sessions);
  }

  @override
  Future<List<WeeklyActivity>> last6MonthsFor(String patientId) async {
    // Live build hides the 6M tab per phase-2b-fac-r L4; this method
    // returns whatever 30D sessions we have, weekly-grouped, as a
    // best-effort fallback if the tab ever does render.
    final sessions = await _fetchActivity(patientId, ActivityRange.d30);
    return SessionAdapter.toWeeklyList(sessions);
  }

  @override
  Future<DeviceHealth> deviceFor(String patientId) async {
    // Live battery / signal / firmware come from `GET /devices/{serial}`'s
    // Shadow-sourced telemetry (the device-detail endpoint shipped 2026-06-03,
    // coord §C41.4 — replaces the prior hardcoded stubs). The patient detail
    // gives the assigned serial + an assignment-time lastSeen fallback;
    // sensorModel stays static (not device-reported).
    final full = await _fetchPatientDetail(patientId);
    final serial = full.currentDevice?.serialNumber;

    if (serial == null || serial.isEmpty) {
      // No device assigned — placeholder the card renders as offline/empty.
      return DeviceHealth(
        serialNumber: 'unassigned',
        firmwareVersion: '—',
        sensorModel: 'BMI270',
        batteryMv: 0,
        signalDbm: -120,
        lastDataReceived: DateTime.fromMillisecondsSinceEpoch(0),
        heartbeatIntervalHours: 1,
      );
    }

    final device = await _api.getDevice(serial);

    // lastSeen: the device's last heartbeat (telemetry.lastSeen = the real
    // reported.ts) OR a more-recent activity uplink — a walk can post after
    // the last heartbeat — whichever is newer.
    DateTime? bestLastSeen = device.lastSeen ?? full.currentDevice?.lastSeen;
    final sessions = await _fetchActivity(patientId, ActivityRange.h24);
    if (sessions.isNotEmpty) {
      final latest = sessions
          .map((s) => s.sessionEnd)
          .reduce((a, b) => a.isAfter(b) ? a : b);
      if (bestLastSeen == null || latest.isAfter(bestLastSeen)) {
        bestLastSeen = latest;
      }
    }

    return DeviceHealth(
      serialNumber: device.serialNumber.isNotEmpty ? device.serialNumber : serial,
      firmwareVersion: device.firmwareVersion ?? '—',
      sensorModel: 'BMI270', // not device-reported; static for V1
      batteryMv: device.batteryMv ?? 0,
      batteryPct: device.batteryPct, // preferred — real fuel-gauge SoC
      signalDbm: device.rsrpDbm ?? -120,
      lastDataReceived: bestLastSeen ?? DateTime.now(),
      heartbeatIntervalHours: 1,
    );
  }

  /// Live notifications come from the server's Alert History — one
  /// [PatientNotification] per unacknowledged alert, with the rule-name
  /// label resolved from the `alertType` field per the L6 mapping. The
  /// demo's [NotificationEngine] is bypassed entirely; the portal is a
  /// thin renderer of server-authoritative state.
  ///
  /// Per phase-2b-fac-r-facility-reads.md L6.
  @override
  Future<List<PatientNotification>> notificationsFor(String patientId) async {
    final alerts = await _fetchAlerts(patientId, AlertStatus.unacknowledged);
    final now = DateTime.now();
    return [
      for (final a in alerts)
        PatientNotification(
          patientId: patientId,
          type: _mapAlertType(a.alertType),
          severity: _mapSeverity(a.alertType, a.severity),
          detail: _formatDetail(a, now),
          // 2B-FAC-W: preserve the SK so the Notification Review
          // panel's Acknowledge button can call PATCH /alerts/{id}/{sk}.
          // AlertRow's SK isn't currently exposed; reconstruct from
          // eventTimestamp + alertType. Mirrors the server-side
          // `{eventTs}#{alertType}` convention.
          // Preserves the server's exact SK (with original timezone
          // offset) for round-trip-safe PATCH /alerts/{id}/{sk} —
          // see AlertRow.sk.
          sk: a.sk,
        ),
    ];
  }

  @override
  Future<NotificationContext> notificationContextFor(String patientId) async {
    // Per phase-2b-fac-r L6: in live mode, screens bypass the demo's
    // notification engine + render alertType-mapped badges directly
    // from the /alerts response. This method is retained for interface
    // parity; we return a context with basic counts.
    final alerts = await _fetchAlerts(patientId, AlertStatus.unacknowledged);
    final summary = _findSummary(patientId);
    final lastSeen = summary?.lastActivityAt ?? DateTime.now();
    return NotificationContext(
      stepsToday: 0, // live impl provides this via todayFor; the engine
                     // shouldn't fire in live mode anyway
      activeMinutesToday: 0,
      hasDataToday: alerts.isNotEmpty || summary != null,
      median7Day: 0,
      medianPrior23Day: 0,
      lastDataAgo: DateTime.now().difference(lastSeen),
    );
  }

  @override
  Future<PatientRowStats> rowStatsFor(String patientId) async {
    // Per phase-2b-fac-r L5: List view's 11-column trend/avg/gait
    // metrics are derived from /activity?range=7d (+ 30d for 30-day
    // avg). Gait fields zero per L8.
    final last7Sessions = await _fetchActivity(patientId, ActivityRange.d7);
    final last30Sessions = await _fetchActivity(patientId, ActivityRange.d30);
    final last7 = SessionAdapter.toDailyList(last7Sessions);
    final last30 = SessionAdapter.toDailyList(last30Sessions);

    double meanActiveMin(List<DailyActivity> days) {
      if (days.isEmpty) return 0;
      return days.fold<int>(0, (s, d) => s + d.totalTimeInMotionMinutes) /
          days.length;
    }

    double meanSteps(List<DailyActivity> days) {
      if (days.isEmpty) return 0;
      return days.fold<int>(0, (s, d) => s + d.totalSteps) / days.length;
    }

    final activeMin7d = meanActiveMin(last7);
    final activeMin30d = meanActiveMin(last30);
    final activeMinTrend = Trend.compute(activeMin7d, activeMin30d);
    final stepsRecent = meanSteps(last7);
    final stepsPrior = meanSteps(last30);
    final stepsTrend = Trend.compute(stepsRecent, stepsPrior);

    final summary = _findSummary(patientId);

    return PatientRowStats(
      alertsThisWeek: summary?.openAlertCount ?? 0,
      activeMinutesToday: last7.isNotEmpty
          ? last7.last.totalTimeInMotionMinutes
          : 0,
      activeMinutes7dAvg: activeMin7d,
      activeMinutesPrior7dAvg: 0, // not derived in live (Phase 1C-full)
      activeMinutesTrend7d: activeMinTrend,
      activeMinutes30dAvg: activeMin30d,
      stepsToday: last7.isNotEmpty ? last7.last.totalSteps : 0,
      stepsTrend7d: stepsTrend,
      stepsRecentAvg: stepsRecent,
      stepsPriorAvg: stepsPrior,
      // Gait fields zero — phase-2b-fac-r L8 (gait UI hidden in live mode).
      gaitSpeed3dAvg: 0,
      gaitSpeedTrend: Trend.flat,
      gaitSpeedPriorAvg: 0,
    );
  }

  // ── Internals ─────────────────────────────────────────────────

  MePatientSummary? _findSummary(String patientId) {
    final patients = _mePatients;
    if (patients == null) return null;
    for (final p in patients) {
      if (p.patientId == patientId) return p;
    }
    return null;
  }

  /// PatientSummary derived from a MePatientSummary row. The
  /// `stepsToday` + `activeMinutesToday` aren't on the row — those
  /// would come from a per-patient 24h fetch. For initial Census
  /// render we leave them at 0 and let the row-loader fill in via
  /// lazy fetch (TBD — Phase B of FAC-R).
  PatientSummary _mePatientToSummary(MePatientSummary p) {
    return PatientSummary(
      patient: Patient(
        id: p.patientId,
        displayName: p.displayName,
        facilityId: p.facilityId ?? '',
        unitId: p.censusId ?? '',
        room: '', // not on /me/patients response
        deviceSerial: p.currentDeviceSerial,
        status: p.status == 'discharged'
            ? PatientStatus.discharged
            : PatientStatus.active,
        // US-31: paused-bell icon at Census tier sources from the same
        // server projection as Patient Detail. Active-only — server
        // returns null when pause has expired.
        notificationsPaused: p.notificationsPaused,
      ),
      stepsToday: 0,
      activeMinutesToday: 0,
      hasDataToday: p.lastActivityAt != null,
    );
  }

  Future<PatientFull> _fetchPatientDetail(String patientId) async {
    return _patientDetailCache.getOrFetch(patientId, () async {
      final resp = await _api.getPatient(patientId);
      return resp.patient;
    });
  }

  Future<List<ActivitySession>> _fetchActivity(
    String patientId,
    ActivityRange range,
  ) {
    final cache = switch (range) {
      ActivityRange.h24 => _activity24hCache,
      ActivityRange.d7 => _activity7dCache,
      ActivityRange.d30 => _activity30dCache,
    };
    return cache.getOrFetch(patientId, () async {
      // Paginate through all pages for the requested range.
      final all = <ActivitySession>[];
      String? cursor;
      do {
        final resp = await _api.getActivity(patientId, range, cursor: cursor);
        all.addAll(resp.sessions);
        cursor = resp.nextCursor;
      } while (cursor != null && cursor.isNotEmpty);
      return all;
    });
  }

  Future<List<AlertRow>> _fetchAlerts(
    String patientId,
    AlertStatus status,
  ) {
    return _alertsCache.getOrFetch(patientId, () async {
      final resp = await _api.getAlerts(patientId, status);
      return resp.alerts;
    });
  }

  // ── Writes (2B-FAC-W) ─────────────────────────────────────────

  @override
  Future<AckAlertResponse> ackAlert({
    required String patientId,
    required String sk,
    String? notes,
  }) async {
    final resp = await _api.ackAlert(patientId, sk, notes: notes);
    // Evict the alerts cache so the next /alerts read reflects the
    // ack. Also clear the per-patient detail cache (currentDevice.
    // lastSeen / openAlertCount fields are influenced by this).
    _alertsCache.evict(patientId);
    _patientDetailCache.evict(patientId);
    return resp;
  }

  @override
  Future<PatientDetailResponse> createPatient({
    required String displayName,
    required String censusId,
    required String room,
    String? deviceSerial,
  }) async {
    final resp = await _api.createPatient(
      displayName: displayName,
      censusId: censusId,
      room: room,
      deviceSerial: deviceSerial,
    );
    // New patient → refresh the /me/patients slice so the Census
    // surfaces the new row on the next render tick.
    try {
      await refreshCensus();
    } catch (_) {/* non-fatal — next poll tick will catch up */}
    return resp;
  }

  @override
  Future<PatientDetailResponse> updatePatient({
    required String patientId,
    String? displayName,
    String? censusId,
    String? room,
  }) async {
    final resp = await _api.updatePatient(
      patientId,
      displayName: displayName,
      censusId: censusId,
      room: room,
    );
    // Evict per-patient caches and refresh the Census in case
    // cross-facility transfer moved the row.
    _patientDetailCache.evict(patientId);
    try {
      await refreshCensus();
    } catch (_) {/* non-fatal */}
    return resp;
  }

  @override
  Future<DischargeResponse> dischargePatient({
    required String patientId,
    String? reason,
    String? notes,
  }) async {
    final resp = await _api.dischargePatient(
      patientId,
      reason: reason,
      notes: notes,
    );
    // Discharged patient drops out of the active-census /me/patients
    // filter; evict + refresh so the Census re-renders without the row.
    _patientDetailCache.evict(patientId);
    _activity24hCache.evict(patientId);
    _activity7dCache.evict(patientId);
    _activity30dCache.evict(patientId);
    _alertsCache.evict(patientId);
    try {
      await refreshCensus();
    } catch (_) {/* non-fatal */}
    return resp;
  }

  @override
  Future<NotificationsPauseResponse> pauseNotifications({
    required String patientId,
    required int days,
    required String reason,
  }) async {
    final resp = await _api.pauseNotifications(
      patientId,
      days: days,
      reason: reason,
    );
    _patientDetailCache.evict(patientId);
    return resp;
  }

  @override
  Future<NotificationsPauseResponse> resumeNotifications(
    String patientId,
  ) async {
    final resp = await _api.resumeNotifications(patientId);
    _patientDetailCache.evict(patientId);
    return resp;
  }

  @override
  Future<CareNoteResponse> updateCareNote({
    required String patientId,
    required String text,
  }) async {
    final resp = await _api.updateCareNote(patientId, text);
    _patientDetailCache.evict(patientId);
    return resp;
  }

  @override
  Future<DeviceResponse> replaceDevice({
    required String patientId,
    required String? currentSerial,
    required String newSerial,
  }) async {
    if (currentSerial != null && currentSerial.isNotEmpty) {
      await _api.endAssignment(currentSerial);
    }
    final resp = await _api.provisionDevice(newSerial, patientId);
    _patientDetailCache.evict(patientId);
    try {
      await refreshCensus();
    } catch (_) {/* non-fatal */}
    return resp;
  }
}

/// In-memory cache with a 30 s TTL and in-flight Future dedup.
///
/// Two concurrent calls to [getOrFetch] for the same key share one
/// underlying fetch — the second caller awaits the same Future as
/// the first, instead of firing a duplicate HTTP request. Useful in
/// `Future.wait` fan-outs like Patient Detail's parallel detail
/// load, where multiple paths (`last30DaysFor`, `last6MonthsFor`)
/// would otherwise race on the same `?range=30d` request.
///
/// Per phase-2b-fac-r-facility-reads.md L12. The 30 s TTL aligns with
/// Patient Detail's polling interval — between two consecutive poll
/// ticks, any second consumer of the same data hits the cache and
/// avoids a redundant HTTP request.
class _TimedCache<K, V> {
  _TimedCache({this.ttl = const Duration(seconds: 30)});

  final Duration ttl;
  final Map<K, _TimedEntry<V>> _entries = {};
  final Map<K, Future<V>> _inFlight = {};

  /// Returns the cached value if fresh, otherwise calls [fetcher] and
  /// caches its result. Concurrent callers with the same [key] share
  /// the in-flight Future.
  Future<V> getOrFetch(K key, Future<V> Function() fetcher) {
    final entry = _entries[key];
    if (entry != null && !entry.isExpired(ttl)) {
      return Future.value(entry.value);
    }
    final pending = _inFlight[key];
    if (pending != null) return pending;

    final future = fetcher().then((value) {
      _entries[key] = _TimedEntry(value, DateTime.now());
      _inFlight.remove(key);
      return value;
    }, onError: (Object error, StackTrace stack) {
      _inFlight.remove(key);
      throw error;
    });
    _inFlight[key] = future;
    return future;
  }

  /// Drop the cached value for [key]. In-flight fetches are not
  /// cancelled — the next caller after this evict misses the cache
  /// and starts a fresh fetch.
  void evict(K key) {
    _entries.remove(key);
  }

  void clear() {
    _entries.clear();
    _inFlight.clear();
  }
}

class _TimedEntry<V> {
  _TimedEntry(this.value, this.fetchedAt);

  final V value;
  final DateTime fetchedAt;

  bool isExpired(Duration ttl) =>
      DateTime.now().difference(fetchedAt) > ttl;
}

/// Maps a server-side `alertType` string to the portal's
/// [NotificationType] enum per phase-2b-fac-r-facility-reads.md L6
/// (§Notification badge mapping). Unknown values land on
/// [NotificationType.other] — the badge still renders, labeled
/// "Alert", so a new server-side rule never silently disappears.
NotificationType _mapAlertType(String alertType) {
  switch (alertType) {
    // 1C-slim behavioral rules (deployed 2026-05-24)
    case 'no_activity_today':
      return NotificationType.noActivityToday;
    case 'below_typical_activity':
      return NotificationType.belowTypical;
    case 'declining_trend':
      return NotificationType.decliningTrend;
    // 1C-slim offline rules
    case 'device_offline':
      return NotificationType.deviceOffline;
    case 'device_silent':
      return NotificationType.deviceSilent;
    // 1B-rev Threshold Detector
    case 'battery_critical':
      return NotificationType.batteryCritical;
    case 'battery_low':
      return NotificationType.batteryLow;
    case 'signal_lost':
      return NotificationType.signalLost;
    case 'signal_weak':
      return NotificationType.signalWeak;
    default:
      return NotificationType.other;
  }
}

/// Resolves severity for live alerts. Prefers the L6 mapping (some
/// 1C-slim alert types are inherently critical regardless of the
/// server's tagged severity); falls back to the server's `severity`
/// string for everything else. The portal's two-tone severity model
/// (`critical` / `warning`) collapses the server's `standard` and
/// `info` levels into `warning`.
NotificationSeverity _mapSeverity(String alertType, String serverSeverity) {
  switch (alertType) {
    case 'no_activity_today':
    case 'device_silent':
    case 'battery_critical':
      return NotificationSeverity.critical;
    case 'below_typical_activity':
    case 'declining_trend':
    case 'device_offline':
    case 'battery_low':
    case 'signal_lost':
    case 'signal_weak':
      return NotificationSeverity.warning;
  }
  return serverSeverity.toLowerCase() == 'critical'
      ? NotificationSeverity.critical
      : NotificationSeverity.warning;
}

/// One-line context line ("Triggered 12 min ago") for the alert row.
/// Mirrors the demo engine's `detail` string shape so the Notification
/// Review panel renders consistently across modes.
String _formatDetail(AlertRow alert, DateTime now) {
  final d = now.difference(alert.eventTimestamp);
  final String age;
  if (d.inMinutes < 1) {
    age = 'just now';
  } else if (d.inMinutes < 60) {
    age = '${d.inMinutes} min ago';
  } else if (d.inHours < 24) {
    age = '${d.inHours}h ago';
  } else if (d.inDays == 1) {
    age = 'yesterday';
  } else {
    age = '${d.inDays}d ago';
  }
  return 'Triggered $age';
}
