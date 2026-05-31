import 'dart:math';

import 'package:flutter/material.dart';

import '../../api/api_client.dart';
// `CareNote` is defined in both api_models and d2c_mock_data — we only
// reference the API one via its inferred type (`patient.careNote`), and
// construct the d2c_mock_data one, so hide the API name to disambiguate.
import '../../api/api_models.dart' hide CareNote;
import '../../api/d2c_api_models.dart';
import '../../auth/auth_service_interface.dart';
import '../../models/user.dart';
import 'd2c_mock_data.dart';
import 'd2c_repository.dart';

/// Live D2C repository: maps the deployed claim + 2A-RD read endpoints
/// into the wireframe screen models. The 2A-RD API returns raw walking
/// *sessions*; the rich dashboard contextualisation (today's totals,
/// 7-day trend, "above your usual" streaks) is aggregated **client-side**
/// here — the server doesn't pre-compute it (phase-2a-read.md §Response
/// shapes; d2c.md §4).
///
/// Phase-1 scope is the monitoring loop. Known data gaps, surfaced rather
/// than faked:
///   • Battery % / signal strength are NOT in the 2A-RD `currentDevice`
///     projection (only serial/status/lastSeen). The device card derives
///     battery from a low-battery alert if one is open, else shows full;
///     a dedicated device-health read (FAC-R Q5) would close this.
///   • 90-day history is unavailable — the activity range maxes at 30d.
///   • `isWalkerUser` on the viewer is hard-true for the Phase-1 solo
///     walker-user-as-admin household; Phase 5 (caregivers) must read the
///     `custom:isWalkerUser` claim to distinguish caregiver viewers.
class LiveD2CRepository implements D2CRepository {
  LiveD2CRepository({required ApiClient api, required AuthServiceInterface auth})
      : _api = api,
        _auth = auth;

  final ApiClient _api;
  final AuthServiceInterface _auth;

  @override
  Future<PublicWalkerLookup> lookupWalker(String walkerId) =>
      _api.publicWalkerLookup(walkerId);

  @override
  Future<ClaimResponse> claim(String walkerId, {String? displayName}) =>
      _api.claimDevice(walkerId, displayName: displayName);

  @override
  Future<String?> myWalkerPatientId() async {
    final resp = await _api.getMyPatients();
    if (resp.patients.isEmpty) return null;
    return resp.patients.first.patientId;
  }

  @override
  Future<D2CDashboardSnapshot> dashboard(String patientId) async {
    final now = DateTime.now();

    // Kick off all reads in parallel, then await (typed — no casts).
    final detailF = _api.getPatient(patientId);
    final todayF = _allSessions(patientId, ActivityRange.h24);
    final weekF = _allSessions(patientId, ActivityRange.d7);
    final alertsF = _api.getAlerts(patientId, AlertStatus.unacknowledged);

    final patient = (await detailF).patient;
    final todaySessions = await todayF;
    final weekSessions = await weekF;
    final openAlertRows = (await alertsF).alerts;

    // ── Daily step buckets (zero-filled 7-day window ending today) ──
    final stepsByDate = <String, int>{};
    for (final s in weekSessions) {
      stepsByDate[s.date] = (stepsByDate[s.date] ?? 0) + s.steps;
    }
    final today0 = DateTime(now.year, now.month, now.day);
    final last7Dates = [
      for (var i = 6; i >= 0; i--) today0.subtract(Duration(days: i)),
    ];

    final todaySteps = todaySessions.fold<int>(0, (a, s) => a + s.steps);
    final todayDistFt =
        todaySessions.fold<double>(0, (a, s) => a + s.distanceFt).round();
    final todayMinutes =
        todaySessions.fold<int>(0, (a, s) => a + s.activeMinutes);

    final last7Days = [
      for (final d in last7Dates)
        DayStep(
          weekday: _weekdayLabel(d.weekday),
          // Today's bucket uses the (more current) 24h total.
          steps: _isSameDay(d, today0)
              ? todaySteps
              : (stepsByDate[_ymd(d)] ?? 0),
        ),
    ];

    // Prior 6 days (excludes today) → rolling average for "above usual".
    final priorSteps = [
      for (final d in last7Dates.take(6)) stepsByDate[_ymd(d)] ?? 0,
    ];
    final weeklyAvg = priorSteps.isEmpty
        ? 0
        : (priorSteps.reduce((a, b) => a + b) / priorSteps.length).round();
    final priorMax = priorSteps.isEmpty ? 0 : priorSteps.reduce(max);
    final is7DayHigh = todaySteps > 0 && todaySteps >= priorMax;

    final yesterdaySteps =
        last7Dates.length >= 2 ? (stepsByDate[_ymd(last7Dates[5])] ?? 0) : 0;
    final pctChange = yesterdaySteps == 0
        ? 0
        : (((todaySteps - yesterdaySteps) / yesterdaySteps) * 100).round();

    // Streak of consecutive days (ending today) at/above the weekly avg.
    var streak = 0;
    if (weeklyAvg > 0) {
      for (var i = last7Days.length - 1; i >= 0; i--) {
        if (last7Days[i].steps >= weeklyAvg) {
          streak++;
        } else {
          break;
        }
      }
    }

    int? lastEndedMinAgo;
    if (todaySessions.isNotEmpty) {
      final lastEnd = todaySessions
          .map((s) => s.sessionEnd)
          .reduce((a, b) => a.isAfter(b) ? a : b)
          .toLocal();
      lastEndedMinAgo = now.difference(lastEnd).inMinutes;
      if (lastEndedMinAgo < 0) lastEndedMinAgo = 0;
    }

    // ── Recent walks (today, newest-first) ──
    final sortedToday = [...todaySessions]
      ..sort((a, b) => b.sessionStart.compareTo(a.sessionStart));
    final recentWalks = [
      for (final s in sortedToday)
        WalkSession(
          startTimeOfDay: _formatTimeOfDay(s.sessionStart.toLocal()),
          durationMinutes: s.activeMinutes > 0
              ? s.activeMinutes
              : s.sessionEnd.difference(s.sessionStart).inMinutes,
          steps: s.steps,
          distanceFt: s.distanceFt.round(),
        ),
    ];

    // ── Open alerts ──
    final openAlerts = [
      for (final a in openAlertRows)
        WalkerAlert(
          id: a.sk,
          icon: _alertIcon(a.alertType),
          title: _alertTitle(a.alertType),
          detail: _alertDetail(a),
          severity: _alertSeverity(a.severity),
          openedMinAgo:
              now.difference(a.eventTimestamp.toLocal()).inMinutes.clamp(0, 1 << 30),
        ),
    ];

    // ── Care note ──
    final apiNote = patient.careNote;
    final careNote = apiNote == null
        ? null
        : CareNote(
            text: apiNote.text,
            updatedByName: apiNote.updatedByName ?? 'Care Circle',
            updatedAt: apiNote.updatedAt,
          );

    // ── Device health (battery/signal are data gaps — see class doc) ──
    final dev = patient.currentDevice;
    final connected = dev != null && dev.status == 'active';
    final lastSeenMinAgo = dev?.lastSeen == null
        ? 0
        : now.difference(dev!.lastSeen!.toLocal()).inMinutes.clamp(0, 1 << 30);
    final device = DeviceHealth(
      connected: connected,
      batteryPct: _batteryFromAlerts(openAlertRows) ?? 1.0,
      signalLabel: connected ? 'Good' : 'Lost',
      lastSeenMinAgo: lastSeenMinAgo,
    );

    final isPreActivation = dev == null ||
        dev.status == 'provisioned' ||
        dev.status == 'ready_to_provision';

    // ── Viewer + walker ──
    final u = _auth.currentUser;
    final viewer = CareCircleMember(
      userId: u?.userId ?? '',
      displayName: u?.displayName ?? 'You',
      relationship: 'Self',
      email: u?.email ?? '',
      isAdmin: u?.role == UserRole.householdOwner,
      isWalkerUser: true, // Phase-1 solo walker-user-as-admin (see class doc)
      isViewer: true,
    );
    final walker = Walker(
      id: patient.patientId,
      displayName: patient.displayName,
      firstName: patient.displayName.trim().split(RegExp(r'\s+')).first,
      relationshipToViewer: 'You',
      deviceSerial: dev?.serialNumber ?? '',
    );

    return D2CDashboardSnapshot(
      viewer: viewer,
      walker: walker,
      today: TodayActivity(
        steps: todaySteps,
        distanceFt: todayDistFt,
        activeMinutes: todayMinutes,
        lastSessionEndedMinAgo: lastEndedMinAgo,
        percentChangeFromYesterday: pctChange,
        weeklyAverageSteps: weeklyAvg,
        is7DayHigh: is7DayHigh,
        streakDaysAboveAverage: streak,
      ),
      last7Days: last7Days,
      recentWalks: recentWalks,
      openAlerts: openAlerts,
      careNote: careNote,
      device: device,
      isPreActivation: isPreActivation,
    );
  }

  @override
  Future<List<HistoryDay>> history(
    String patientId, {
    required int days,
  }) async {
    // 2A-RD activity windows max out at 30 days, so 90-day history is not
    // available from Phase-1 reads — we return up to 30 days regardless.
    final sessions = await _allSessions(patientId, ActivityRange.d30);
    final agg = <String, List<int>>{}; // date -> [steps, minutes]
    for (final s in sessions) {
      final e = agg.putIfAbsent(s.date, () => [0, 0]);
      e[0] += s.steps;
      e[1] += s.activeMinutes;
    }
    final out = [
      for (final entry in agg.entries)
        HistoryDay(
          date: DateTime.tryParse(entry.key) ?? DateTime.now(),
          steps: entry.value[0],
          activeMinutes: entry.value[1],
        ),
    ]..sort((a, b) => a.date.compareTo(b.date));
    return out;
  }

  // ── Internals ─────────────────────────────────────────────────

  /// Drain all pages of an activity window (guarded at 20 pages).
  Future<List<ActivitySession>> _allSessions(
    String patientId,
    ActivityRange range,
  ) async {
    final out = <ActivitySession>[];
    String? cursor;
    var guard = 0;
    do {
      final resp = await _api.getActivity(patientId, range, cursor: cursor);
      out.addAll(resp.sessions);
      cursor = resp.nextCursor;
      guard++;
    } while (cursor != null && cursor.isNotEmpty && guard < 20);
    return out;
  }

  double? _batteryFromAlerts(List<AlertRow> alerts) {
    for (final a in alerts) {
      if (a.alertType.contains('battery')) {
        final p = a.data?['batteryPct'] ?? a.data?['battery_pct'];
        if (p is num) return p > 1 ? p / 100.0 : p.toDouble();
      }
    }
    return null;
  }

  String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  String _weekdayLabel(int weekday) =>
      const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][weekday - 1];

  String _formatTimeOfDay(DateTime d) {
    final ampm = d.hour < 12 ? 'AM' : 'PM';
    var h = d.hour % 12;
    if (h == 0) h = 12;
    return '$h:${d.minute.toString().padLeft(2, '0')} $ampm';
  }

  IconData _alertIcon(String type) {
    switch (type) {
      case 'low_battery':
      case 'battery':
        return Icons.battery_alert_outlined;
      case 'offline':
      case 'device_offline':
        return Icons.wifi_off_outlined;
      case 'no_activity':
      case 'low_activity':
        return Icons.directions_walk_outlined;
      case 'decline':
      case 'declining':
        return Icons.trending_down;
      case 'fall':
      case 'impact':
        return Icons.warning_amber_rounded;
      default:
        return Icons.notifications_outlined;
    }
  }

  String _alertTitle(String type) {
    switch (type) {
      case 'low_battery':
      case 'battery':
        return 'Battery is getting low';
      case 'offline':
      case 'device_offline':
        return 'Device is offline';
      case 'no_activity':
        return 'No activity yet';
      case 'low_activity':
        return 'Quieter than usual';
      case 'decline':
      case 'declining':
        return 'Activity is trending down';
      case 'fall':
      case 'impact':
        return 'Possible fall detected';
      default:
        return 'Notice';
    }
  }

  /// Prefer a server-provided human message in `data`, else derive a
  /// friendly default from the alert type.
  String _alertDetail(AlertRow a) {
    final msg = a.data?['message'] ?? a.data?['detail'];
    if (msg is String && msg.isNotEmpty) return msg;
    switch (a.alertType) {
      case 'low_battery':
      case 'battery':
        return 'Replace the AA batteries in the next day or two.';
      case 'offline':
      case 'device_offline':
        return "The cap hasn't checked in recently.";
      default:
        return '';
    }
  }

  AlertSeverity _alertSeverity(String severity) {
    switch (severity) {
      case 'critical':
        return AlertSeverity.critical;
      case 'warning':
        return AlertSeverity.warning;
      default:
        return AlertSeverity.info;
    }
  }
}
