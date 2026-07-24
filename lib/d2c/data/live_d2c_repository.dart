import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../api/api_client.dart';
// `CareNote` is defined in both api_models and d2c_mock_data — we only
// reference the API one via its inferred type (`patient.careNote`), and
// construct the d2c_mock_data one, so hide the API name to disambiguate.
import '../../api/api_models.dart' hide CareNote;
import '../../api/d2c_api_models.dart';
import '../../auth/auth_service_interface.dart';
import '../../config/d2c_legal.dart';
import '../../models/user.dart';
import '../../util/timezone.dart';
import '../rendering/metric_registry.dart';
import 'd2c_mock_data.dart';
import 'd2c_repository.dart';

/// The ONLY alert types a WALKER user sees on their own dashboard: battery (the
/// one thing they can act on). Kept in sync with the backend allow-list
/// (`patient-api/queries.py :: WALKER_VISIBLE_ALERT_TYPES`). The backend already
/// strips non-battery alerts for a walker token; this mirror is defense-in-depth
/// against an older backend. Activity, signal, offline, and safety alerts are
/// the caregiver's concern — hidden from the walker (2026-07-20 "only battery").
const _walkerVisibleAlertTypes = <String>{
  'battery_low',
  'battery_critical',
  'low_battery',
  'battery',
};

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
///   • `isWalkerUser` on the viewer is read from the `custom:isWalkerUser`
///     JWT claim (falling back to the role proxy — owner ⇒ walker — only when
///     the claim is absent, e.g. the mock/demo session). It drives the
///     viewer framing copy AND the walker-only alert suppression below
///     (activity-judgment alerts are hidden from the walker's own view;
///     device-health alerts stay).
class LiveD2CRepository implements D2CRepository {
  LiveD2CRepository({required ApiClient api, required AuthServiceInterface auth})
      : _api = api,
        _auth = auth;

  final ApiClient _api;
  final AuthServiceInterface _auth;

  @override
  Future<PublicWalkerLookup> lookupWalker(String walkerId) =>
      _api.publicWalkerLookup(walkerId);

  // ── QR re-login (d2c-qr-relogin) ───────────────────────────────

  @override
  Future<List<WalkerRecipient>> walkerLoginRecipients(String walkerId) =>
      _api.getWalkerRecipients(walkerId);

  @override
  Future<LoginCodeChallenge> sendWalkerLoginCode(
          String walkerId, String recipientId) =>
      _api.sendWalkerLoginCode(walkerId, recipientId);

  @override
  Future<LoginCodeVerifyResult> verifyWalkerLoginCode(
          String walkerId, String recipientId, String session, String code) =>
      _api.verifyWalkerLoginCode(walkerId, recipientId, session, code);

  @override
  Future<ClaimResponse> claim(String walkerId, {String? displayName}) async {
    // Reaching claim means the walker passed the setup agreement gate
    // (D2CAgreementPanel); record the acknowledged version server-side. Also
    // capture the browser's IANA timezone (d2c-timezone-capture.md) so the new
    // Patient buckets days locally, not UTC.
    final resp = await _api.claimDevice(walkerId,
        displayName: displayName,
        agreementVersion: D2CLegal.agreementVersion,
        timeZone: detectIanaTimeZone());
    // The household clientId is now persisted server-side; force a token
    // refresh so custom:clientId reflects the new household (dtc_{householdId})
    // before the dashboard reads — the pre-claim bootstrap token carried
    // dtc_{sub}, which would scope /me/patients to an empty client (DT-5).
    await _auth.refreshClaims();
    return resp;
  }

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
    // 30d (the 2A-RD cap), not 7d: the trend charts derive all three zooms
    // (30-day weekly averages / 7-day daily / intra-day) from this one window,
    // so it replaces the old 7d read rather than adding a request.
    final monthF = _allSessions(patientId, ActivityRange.d30);
    final alertsF = _api.getAlerts(patientId, AlertStatus.unacknowledged);

    final patient = (await detailF).patient;
    // `range=h24` is a rolling 24-hour window; "Today's walks" (and the today
    // totals derived from it) want the CALENDAR day the viewer sees. Row times
    // below render via `.toLocal()`, so bucket "today" the same way — filter to
    // sessions whose local start is today. Without this, last night's late
    // sessions (still inside the 24h window, and stamped as today's date when
    // the patient timezone is unset → UTC) wrongly appear under today.
    final todaySessions = [
      for (final s in await todayF)
        if (_isSameDay(s.sessionStart.toLocal(), now)) s,
    ];
    final monthSessions = await monthF;
    final openAlertRows = (await alertsF).alerts;

    // ── Per-device-type view (DT-4). Prefer the current device's type (known
    // even before the first session); else the newest session's type; else
    // walker_cap (D9). The registry decides which metric leads. ──
    final deviceType = patient.currentDevice?.deviceType ??
        _mostRecentDeviceType(monthSessions) ??
        _mostRecentDeviceType(todaySessions) ??
        'walker_cap';
    final heroIsActiveMin =
        deviceTypeView(deviceType).hero == ActivityMetric.activeMinutes;

    // ── Daily buckets (zero-filled 30-day window). Carry every metric the trend
    // cards plot (active minutes + distance, and steps for the hero stat), plus
    // the day's own sessions so a tapped day can show its intra-day detail. ──
    final stepsByDate = <String, int>{};
    final activeMinByDate = <String, int>{};
    final distanceByDate = <String, double>{};
    final sessionsByDate = <String, List<ActivitySession>>{};
    for (final s in monthSessions) {
      stepsByDate[s.date] = (stepsByDate[s.date] ?? 0) + s.steps;
      activeMinByDate[s.date] = (activeMinByDate[s.date] ?? 0) + s.activeMinutes;
      distanceByDate[s.date] = (distanceByDate[s.date] ?? 0) + s.distanceFt;
      (sessionsByDate[s.date] ??= []).add(s);
    }
    final today0 = DateTime(now.year, now.month, now.day);
    final last30Dates = [
      for (var i = 29; i >= 0; i--) today0.subtract(Duration(days: i)),
    ];
    final last7Dates = last30Dates.sublist(23);

    final todaySteps = todaySessions.fold<int>(0, (a, s) => a + s.steps);
    final todayDistFt =
        todaySessions.fold<double>(0, (a, s) => a + s.distanceFt).round();
    final todayMinutes =
        todaySessions.fold<int>(0, (a, s) => a + s.activeMinutes);
    final todayGait = _avgGait(todaySessions);

    // Hero-metric daily total (today prefers the more-current 24h total).
    int heroForYmd(String ymd) =>
        heroIsActiveMin ? (activeMinByDate[ymd] ?? 0) : (stepsByDate[ymd] ?? 0);
    final todayHero = heroIsActiveMin ? todayMinutes : todaySteps;

    // Today's bucket uses the (more current) 24h totals + the calendar-day
    // filtered session list, so today's detail matches the live 24h numbers.
    // `last7Days` is simply the trailing slice — one computation, one source.
    final last30Days = <DayStep>[];
    for (final d in last30Dates) {
      final isToday = _isSameDay(d, today0);
      final ymd = _ymd(d);
      last30Days.add(DayStep(
        weekday: _weekdayLabel(d.weekday),
        dateLabel: isToday ? 'Today' : _dateLabel(d),
        date: d,
        steps: isToday ? todaySteps : (stepsByDate[ymd] ?? 0),
        activeMinutes: isToday ? todayMinutes : (activeMinByDate[ymd] ?? 0),
        distanceFt:
            isToday ? todayDistFt : (distanceByDate[ymd] ?? 0).round(),
        sessions: _toWalkSessions(
          isToday ? todaySessions : (sessionsByDate[ymd] ?? const []),
        ),
      ));
    }
    final last7Days = last30Days.sublist(23);

    // Prior 6 days (excludes today) → rolling average of the HERO metric for
    // the "above/below your usual" context.
    final priorHero = [
      for (final d in last7Dates.take(6)) heroForYmd(_ymd(d)),
    ];
    final weeklyAvgHero = priorHero.isEmpty
        ? 0
        : (priorHero.reduce((a, b) => a + b) / priorHero.length).round();
    final priorMax = priorHero.isEmpty ? 0 : priorHero.reduce(max);
    final is7DayHigh = todayHero > 0 && todayHero >= priorMax;

    final yesterdayHero =
        last7Dates.length >= 2 ? heroForYmd(_ymd(last7Dates[5])) : 0;
    final pctChange = yesterdayHero == 0
        ? 0
        : (((todayHero - yesterdayHero) / yesterdayHero) * 100).round();

    // Streak of consecutive days (ending today) at/above the weekly avg.
    var streak = 0;
    if (weeklyAvgHero > 0) {
      for (var i = last7Days.length - 1; i >= 0; i--) {
        final v =
            heroIsActiveMin ? last7Days[i].activeMinutes : last7Days[i].steps;
        if (v >= weeklyAvgHero) {
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
    // Same mapping the per-day trend detail uses, so the two always agree.
    final recentWalks = _toWalkSessions(todaySessions);

    // ── Open alerts ──
    // Walker-only suppression (mirrors the backend read filter keyed on
    // custom:isWalkerUser): the walker/device user does not see the behavioral
    // activity-judgment alerts about themselves. Device-health alerts pass
    // through. Reused below for the viewer framing copy.
    final viewerIsWalker = _auth.currentUser?.isWalkerUser ?? false;

    // Best-effort timezone self-heal (d2c-timezone-capture.md §4.5): if the
    // viewer IS the walker and this Patient's stored zone is still unset, fill
    // it from the browser so days bucket locally. Fire-and-forget.
    _maybeHealTimezone(patientId, patient.timezone, viewerIsWalker);

    final openAlerts = [
      for (final a in openAlertRows)
        // Non-walker viewers see every alert; the walker sees ONLY battery.
        if (!viewerIsWalker || _walkerVisibleAlertTypes.contains(a.alertType))
          WalkerAlert(
            id: a.sk,
            icon: _alertIcon(a.alertType),
            title: _alertTitle(a.alertType),
            detail: _alertDetail(a),
            severity: _alertSeverity(a.severity),
            openedMinAgo: now
                .difference(a.eventTimestamp.toLocal())
                .inMinutes
                .clamp(0, 1 << 30),
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
    final lastSeenMinAgo = dev?.lastSeen == null
        ? null
        : now.difference(dev!.lastSeen!.toLocal()).inMinutes.clamp(0, 1 << 30);
    // "Connected" = device is live (`active_monitoring`) AND has phoned home
    // within the offline window. The lifecycle state is `active_monitoring`,
    // NOT `active` — the old `== 'active'` check never matched, so this card
    // always read "Device offline · Lost signal" for a perfectly healthy
    // device. Heartbeats are hourly, so we mirror the behavioral-detector
    // `device_offline` threshold (2h) — that way a healthy device stays green
    // between heartbeats, and the dot agrees with the offline alert.
    const offlineThresholdMin = 120;
    final connected = dev?.status == 'active_monitoring' &&
        lastSeenMinAgo != null &&
        lastSeenMinAgo <= offlineThresholdMin;
    final device = DeviceHealth(
      connected: connected,
      batteryPct: _batteryFromAlerts(openAlertRows) ?? 1.0,
      signalLabel: connected ? 'Good' : 'Lost',
      lastSeenMinAgo: lastSeenMinAgo ?? 0,
    );

    // A device-less household (no current device — never claimed, or the
    // device was rotated to another household) has NO walker; it is NOT
    // "getting set up". Only a present-but-not-yet-active device is
    // pre-activation (claimed, awaiting its first check-in).
    final hasWalker = dev != null;
    final isPreActivation = dev != null &&
        (dev.status == 'provisioned' || dev.status == 'ready_to_provision');

    // ── Viewer + walker ──
    // A family_viewer is a Care Circle member looking at someone ELSE's
    // walker (d2c-care-circle.md) — drives the "Susan's activity" (vs
    // "your activity") copy. `viewerIsWalker` (computed above from the real
    // custom:isWalkerUser claim) now distinguishes the walker-user from a
    // caregiver-owner directly, rather than assuming every household_owner is
    // the walker.
    final u = _auth.currentUser;
    final viewerIsMember = u?.role == UserRole.familyViewer;
    final viewer = CareCircleMember(
      userId: u?.userId ?? '',
      displayName: u?.displayName ?? 'You',
      relationship: viewerIsMember ? 'Member' : 'Self',
      email: u?.email ?? '',
      isAdmin: u?.role == UserRole.householdOwner,
      isWalkerUser: viewerIsWalker,
      isViewer: true,
    );
    final walker = Walker(
      id: patient.patientId,
      displayName: patient.displayName,
      firstName: patient.displayName.trim().split(RegExp(r'\s+')).first,
      relationshipToViewer: viewerIsMember ? '' : 'You',
      deviceSerial: dev?.serialNumber ?? '',
    );

    return D2CDashboardSnapshot(
      viewer: viewer,
      walker: walker,
      deviceType: deviceType,
      today: TodayActivity(
        steps: todaySteps,
        distanceFt: todayDistFt,
        activeMinutes: todayMinutes,
        lastSessionEndedMinAgo: lastEndedMinAgo,
        percentChangeFromYesterday: pctChange,
        weeklyAverageSteps: weeklyAvgHero,
        is7DayHigh: is7DayHigh,
        streakDaysAboveAverage: streak,
        gaitSpeedFts: todayGait,
      ),
      last7Days: last7Days,
      last30Days: last30Days,
      recentWalks: recentWalks,
      openAlerts: openAlerts,
      careNote: careNote,
      device: device,
      isPreActivation: isPreActivation,
      hasWalker: hasWalker,
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
    final deviceType = _mostRecentDeviceType(sessions) ?? 'walker_cap';
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
          deviceType: deviceType,
        ),
    ]..sort((a, b) => a.date.compareTo(b.date));
    return out;
  }

  // ── Care Circle (d2c-care-circle.md §5.9) ──────────────────────

  @override
  Future<CareCircleData> careCircle() async {
    final roster = await _api.getCareCircle();
    final members = [
      for (final m in roster.members)
        CareCircleMember(
          userId: m.userId ?? '',
          displayName: m.displayName,
          relationship: m.relationship,
          email: '',
          contactMask: m.contactMask,
          isAdmin: m.role == 'household_owner',
          isWalkerUser: m.isWalkerUser,
          isViewer: m.isViewer,
          // lastActiveAt isn't tracked in V1; null renders as the
          // contact mask / walker copy in the card subtitle.
          lastActiveAt: null,
        ),
    ];
    final self = members.where((m) => m.isViewer).toList();
    final walkerEntries = members.where((m) => m.isWalkerUser).toList();
    return CareCircleData(
      members: members,
      invites: [for (final i in roster.pendingInvites) _inviteView(i)],
      requests: const [], // walk-up access requests are 5b (deferred)
      walkerName: walkerEntries.isEmpty
          ? 'your walker'
          : walkerEntries.first.displayName.trim().split(RegExp(r'\s+')).first,
      viewerIsAdmin: self.isNotEmpty
          ? self.first.isAdmin
          : _auth.currentUser?.role == UserRole.householdOwner,
      viewerUserId: _auth.currentUser?.userId ?? '',
    );
  }

  @override
  Future<PendingInvite> sendInvite({
    required String name,
    required String phone,
    String relationship = '',
    bool asAdmin = false,
    bool isWalkerUser = false,
  }) async {
    final created = await _api.sendCareInvite(
      name: name,
      phone: phone,
      relationship: relationship,
      asAdmin: asAdmin,
      isWalkerUser: isWalkerUser,
    );
    return _inviteView(created);
  }

  @override
  Future<void> resendInvite(String inviteId) => _api.resendCareInvite(inviteId);

  @override
  Future<void> revokeInvite(String inviteId) => _api.revokeCareInvite(inviteId);

  @override
  Future<void> setMemberAdmin(String userId, {required bool admin}) =>
      _api.setCareMemberRole(userId, admin: admin);

  @override
  Future<void> removeMember(String userId) => _api.removeCareMember(userId);

  @override
  Future<List<JoinableInvite>> pendingInvitesForMe() =>
      _api.getPendingInvitesForMe();

  @override
  Future<AcceptInviteResult> acceptInvite(String inviteId) async {
    // Reaching accept means the caregiver passed the join agreement gate
    // (D2CAgreementPanel); record the acknowledged version server-side.
    final result = await _api.acceptCareInvite(inviteId,
        agreementVersion: D2CLegal.agreementVersion);
    // The membership row is persisted server-side; refresh the token so
    // custom:clientId/custom:role reflect the joined household before the
    // dashboard reads — same pattern as post-claim (§C56).
    await _auth.refreshClaims();
    return result;
  }

  @override
  Future<void> ackAlert(String patientId, String alertId, {String? notes}) =>
      _api.ackAlert(patientId, alertId, notes: notes);

  @override
  Future<void> setPatientTimezone(String patientId, String timeZone) =>
      _api.setPatientTimezone(patientId, timeZone);

  // ── Coach "Steady" (ai-coach-c1-text-chat.md §5.7) ─────────────

  @override
  Future<List<CoachMessage>> getCoachThread() async {
    final dto = await _api.getCoachThread();
    return [for (final m in dto.messages) _coachMessageView(m)];
  }

  @override
  Future<CoachMessage> sendCoachMessage(String text) async {
    final reply = await _api.sendCoachMessage(text);
    // POST /chat returns only {reply, flagged} — the server assigns the turn
    // id/timestamp but doesn't echo them, so synthesize a local coach turn
    // (the user turn is rendered optimistically client-side).
    return CoachMessage(
      id: 'coach_reply_${DateTime.now().microsecondsSinceEpoch}',
      role: CoachRole.coach,
      text: reply.reply,
      createdAt: DateTime.now(),
      flagged: reply.flagged,
    );
  }

  @override
  Future<CoachMemory> getCoachMemory() async {
    final dto = await _api.getCoachMemory();
    return CoachMemory(
      facts: [for (final f in dto.facts) _coachFactView(f)],
      summary: dto.summary,
    );
  }

  @override
  Future<CoachMemoryFact> addCoachFact(String text) async =>
      _coachFactView(await _api.addCoachFact(text));

  @override
  Future<CoachMemoryFact> addCoachGoal(String text) async =>
      _coachFactView(await _api.addCoachFact(text, kind: 'goal'));

  @override
  Future<CoachMemoryFact> updateCoachFact(String factId, String text) async =>
      _coachFactView(await _api.updateCoachFact(factId, text));

  @override
  Future<void> deleteCoachFact(String factId) => _api.deleteCoachFact(factId);

  @override
  Future<CoachNote?> getCoachInbox() async {
    final dto = await _api.getCoachInbox();
    return dto == null ? null : _coachNoteView(dto);
  }

  @override
  Future<CoachPrefs> getCoachPrefs() async =>
      _coachPrefsView(await _api.getCoachPrefs());

  @override
  Future<CoachPrefs> updateCoachPrefs({String? tone, bool? smsTeaser}) async {
    await _api.updateCoachPrefs(tone: tone, smsTeaser: smsTeaser);
    // The PATCH echo may omit the unchanged key, so re-read for the
    // authoritative tone + SMS pair rather than trusting a partial response.
    return getCoachPrefs();
  }

  // C1 re-engagement nudge is a client-side session flag (there is no server
  // unread state until C2's proactive inbox). Instance-scoped to the signed-in
  // user; resets on app relaunch, which is the right "welcome back" behavior.
  bool _coachOpened = false;

  @override
  Future<bool> coachHasUnread() async => !_coachOpened;

  @override
  Future<void> markCoachOpened() async {
    _coachOpened = true;
  }

  CoachMessage _coachMessageView(CoachTurnDto m) => CoachMessage(
        id: m.id,
        role: m.role == CoachTurnRoleWire.user
            ? CoachRole.user
            : CoachRole.coach,
        text: m.text,
        createdAt: m.createdAt ?? DateTime.now(),
        flagged: m.flagged,
      );

  CoachMemoryFact _coachFactView(CoachFactDto f) => CoachMemoryFact(
        factId: f.factId,
        text: f.text,
        source: f.source == CoachFactSourceWire.user
            ? CoachFactSource.user
            : CoachFactSource.extracted,
        kind: f.kind == CoachFactKindWire.goal
            ? CoachFactKind.goal
            : CoachFactKind.profile,
      );

  CoachNote _coachNoteView(CoachNoteDto n) => CoachNote(
        id: n.id,
        date: n.date,
        text: n.text,
        themeType: n.themeType,
        createdAt: n.createdAt ?? DateTime.now(),
      );

  CoachPrefs _coachPrefsView(CoachPrefsDto p) => CoachPrefs(
        tone: CoachTone.fromWire(p.tone),
        smsTeaser: p.coachSmsTeaser,
      );

  PendingInvite _inviteView(RosterInvite i) {
    final now = DateTime.now();
    final expiresIn = i.expiresAt == null
        ? 0
        : i.expiresAt!.difference(now).inDays.clamp(0, 365);
    return PendingInvite(
      id: i.inviteId,
      name: i.displayName,
      email: '',
      contactMask: i.contactMask,
      relationship: i.relationship,
      invitedByName: '',
      sentAt: i.createdAt ?? now,
      asAdmin: i.role == 'household_owner',
      expiresInDays: expiresIn,
    );
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

  /// The `deviceType` of the newest session (by end time), or null if none of
  /// the rows carry one (all pre-DT-0). Used as the fallback framing source
  /// when the current-device projection has no type yet.
  String? _mostRecentDeviceType(List<ActivitySession> sessions) {
    ActivitySession? newest;
    for (final s in sessions) {
      if (s.deviceType == null) continue;
      if (newest == null || s.sessionEnd.isAfter(newest.sessionEnd)) newest = s;
    }
    return newest?.deviceType;
  }

  /// Mean of the sessions' gait speed (ft/s) over those that reported one;
  /// null when none did (firmware confidence-gates it) → renders as "—".
  double? _avgGait(List<ActivitySession> sessions) {
    var sum = 0.0;
    var n = 0;
    for (final s in sessions) {
      final g = s.gaitSpeedFts;
      if (g != null) {
        sum += g;
        n++;
      }
    }
    return n == 0 ? null : sum / n;
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

  /// Fire-and-forget timezone self-heal (d2c-timezone-capture.md §4.5). Only
  /// the walker heals their own patient, and only when the stored zone is still
  /// unset (null/empty/`UTC`); the server re-checks all of this and only fills
  /// an unset zone, so this is a best-effort nudge. Swallows every error — a
  /// tz write must never surface on, or block, the dashboard.
  void _maybeHealTimezone(String patientId, String? storedTz, bool viewerIsWalker) {
    if (!viewerIsWalker) return;
    final stored = storedTz?.trim();
    final isUnset = stored == null || stored.isEmpty || stored == 'UTC';
    if (!isUnset) return;
    final detected = detectIanaTimeZone();
    if (detected == null || detected == stored) return;
    unawaited(_api.setPatientTimezone(patientId, detected).catchError((_) {}));
  }

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  String _weekdayLabel(int weekday) =>
      const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][weekday - 1];

  static const _monthLabels = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  /// "Mon, Jul 14" — the header of a tapped day's detail panel.
  String _dateLabel(DateTime d) =>
      '${_weekdayLabel(d.weekday)}, ${_monthLabels[d.month - 1]} ${d.day}';

  /// Map raw activity rows → display sessions, newest-first. Shared by
  /// "Today's walks" and each trend card's tapped-day detail so the two
  /// renderings of the same session can never drift.
  List<WalkSession> _toWalkSessions(List<ActivitySession> sessions) {
    final sorted = [...sessions]
      ..sort((a, b) => b.sessionStart.compareTo(a.sessionStart));
    return [
      for (final s in sorted)
        WalkSession(
          startTimeOfDay: _formatTimeOfDay(s.sessionStart.toLocal()),
          startHour: s.sessionStart.toLocal().hour,
          durationMinutes: s.activeMinutes > 0
              ? s.activeMinutes
              : s.sessionEnd.difference(s.sessionStart).inMinutes,
          steps: s.steps,
          distanceFt: s.distanceFt.round(),
          activeMinutes: s.activeMinutes,
          gaitSpeedFts: s.gaitSpeedFts,
        ),
    ];
  }

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
      case 'battery_low':
      case 'battery_critical':
        return Icons.battery_alert_outlined;
      case 'offline':
      case 'device_offline':
      case 'device_silent':
        return Icons.wifi_off_outlined;
      case 'signal_lost':
      case 'signal_weak':
        return Icons.signal_cellular_off_outlined;
      case 'no_activity':
      case 'no_activity_today':
      case 'low_activity':
      case 'below_typical_activity':
        return Icons.directions_walk_outlined;
      case 'decline':
      case 'declining':
      case 'declining_trend':
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
      case 'battery_low':
        return 'Battery is getting low';
      case 'battery_critical':
        return 'Battery is critically low';
      case 'offline':
      case 'device_offline':
        return 'Device is offline';
      case 'device_silent':
        return 'Device has gone quiet';
      case 'signal_lost':
        return 'Signal lost';
      case 'signal_weak':
        return 'Weak signal';
      case 'no_activity':
      case 'no_activity_today':
        return 'No activity yet';
      case 'low_activity':
      case 'below_typical_activity':
        return 'Quieter than usual';
      case 'decline':
      case 'declining':
      case 'declining_trend':
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
      case 'battery_low':
        return 'Replace the AA batteries in the next day or two.';
      case 'battery_critical':
        return 'Replace the AA batteries now to avoid a gap in monitoring.';
      case 'offline':
      case 'device_offline':
        return "The device hasn't checked in for a couple of hours.";
      case 'device_silent':
        return "The device hasn't sent an update in over a day.";
      case 'signal_lost':
        return "The device can't reach the cellular network right now.";
      case 'signal_weak':
        return "The device's cellular signal is weak; readings may be delayed.";
      case 'no_activity':
      case 'no_activity_today':
        return 'No walking recorded yet today.';
      case 'low_activity':
      case 'below_typical_activity':
        return 'Less walking than a typical day.';
      case 'decline':
      case 'declining':
      case 'declining_trend':
        return 'Walking has been decreasing over recent days.';
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
