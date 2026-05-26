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

  // ── Per-patient (async; cache + fetch on miss) ───────────────

  @override
  Future<Patient> patientById(String patientId) async {
    final full = await _fetchPatientDetail(patientId);
    return Patient(
      id: full.patientId,
      displayName: full.displayName,
      facilityId: full.facilityId ?? '',
      unitId: full.censusId ?? '',
      room: '', // Patient.room isn't on the 2A-RD response yet;
                // V1 displays display-name + unit + censusName instead
      deviceSerial: full.currentDevice?.serialNumber,
      status: full.status == 'discharged'
          ? PatientStatus.discharged
          : PatientStatus.active,
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
    // Per phase-2b-fac-r Q5 lean: V1 surfaces what's on
    // /patients/{id}.currentDevice; firmware version + battery mV +
    // signal dBm + sensor model are 2A-RD-follow-up. Stub the missing
    // fields with reasonable defaults so the existing DeviceHealth
    // shape renders. Real values fill in if a future device-detail
    // endpoint ships.
    final full = await _fetchPatientDetail(patientId);
    final dev = full.currentDevice;

    // Cloud-side 2A-RD bug: `currentDevice.lastSeen` returns the value
    // of `Device Registry.firstHeartbeatAt` instead of the actual most-
    // recent payload timestamp. Workaround: also pull the 24h activity
    // (cached or fresh) and use the latest sessionEnd if it's more
    // recent. File: 2A-RD-follow-up to fix the response field. Until
    // then this client-side fallback keeps "last seen" accurate.
    final sessions = await _fetchActivity(patientId, ActivityRange.h24);
    DateTime? bestLastSeen = dev?.lastSeen;
    if (sessions.isNotEmpty) {
      final latest = sessions
          .map((s) => s.sessionEnd)
          .reduce((a, b) => a.isAfter(b) ? a : b);
      if (bestLastSeen == null || latest.isAfter(bestLastSeen)) {
        bestLastSeen = latest;
      }
    }

    return DeviceHealth(
      serialNumber: dev?.serialNumber ?? 'unassigned',
      firmwareVersion: '—',
      sensorModel: 'BMI270',
      batteryMv: 3600, // stub: shows full until a real value arrives
      signalDbm: -80, // stub: shows ~70% bar
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
