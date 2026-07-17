// Mock data for the D2C wireframe screens. Mirrors the shape we expect
// from the (future) D2CRepository: a single Walker + Care Circle +
// recent activity + recent alerts + device state.
//
// One D2C household, told from Sarah's (the daughter, Admin) point of
// view. Eleanor is the walker user, doesn't have her own account.
//
// Naming follows the d2c onboarding doc: Member + Admin flag + Walker-
// user property. "Self" → "Walker user" everywhere.

import 'package:flutter/material.dart';

/// Care Circle membership state for the signed-in viewer.
enum ViewerRole {
  admin,
  member, // read-only access
}

/// Walker (the device + its assigned person). 1:1 with a D2C household
/// in V1. `displayName` drives both the header copy and the "your" vs
/// "Mom's" decision when `isWalkerUser` flips.
class Walker {
  const Walker({
    required this.id,
    required this.displayName,
    required this.firstName,
    required this.relationshipToViewer,
    required this.deviceSerial,
  });

  final String id;
  final String displayName;     // "Eleanor Davis"
  final String firstName;       // "Eleanor"
  final String relationshipToViewer; // "Mom" | "Dad" | "Grandma" etc.
  final String deviceSerial;
}

/// A person with access to this walker's data.
class CareCircleMember {
  const CareCircleMember({
    required this.userId,
    required this.displayName,
    required this.relationship,
    required this.email,
    this.phoneE164,
    this.contactMask = '',        // •••-1234 (live roster; raw phone never crosses the API)
    this.isAdmin = false,
    this.isWalkerUser = false,
    this.isViewer = false,        // true for the signed-in user
    this.lastActiveAt,
    this.invitePending = false,   // sent but not yet claimed
  });

  final String userId;
  final String displayName;
  final String relationship;      // "Daughter", "Son", "Self", "Niece"
  final String email;
  final String? phoneE164;
  final String contactMask;
  final bool isAdmin;
  final bool isWalkerUser;
  final bool isViewer;
  final DateTime? lastActiveAt;
  final bool invitePending;
}

/// Today's activity summary + week-level context for Whoop-style
/// contextualized greetings ("Strongest day this week", "3 days above
/// your pace", etc.). Computed server-side eventually; mock-seeded here.
class TodayActivity {
  const TodayActivity({
    required this.steps,
    required this.distanceFt,
    required this.activeMinutes,
    required this.lastSessionEndedMinAgo,
    required this.percentChangeFromYesterday,
    required this.weeklyAverageSteps,
    required this.is7DayHigh,
    required this.streakDaysAboveAverage,
    this.gaitSpeedFts,
  });

  final int steps;
  final int distanceFt;
  final int activeMinutes;
  final int? lastSessionEndedMinAgo;
  final int percentChangeFromYesterday;
  /// Rolling 7-day mean of the **hero metric** (excluding today) — steps for a
  /// walker cap, active-minutes for a rollator (DT-4). Drives "above/below
  /// your pace". (Name kept for wireframe back-compat; holds the hero metric.)
  final int weeklyAverageSteps;
  /// True iff today's hero-metric total >= max(last 7 days). "Strongest day".
  final bool is7DayHigh;
  /// Session-average gait speed (ft/s), when the firmware reported it; null
  /// otherwise (confidence-gated). A rollator stat; unused by the walker view.
  final double? gaitSpeedFts;
  /// Number of consecutive days (ending today) at or above weekly average.
  /// 0 = today is the first time below average in a streak; 3 = today is
  /// the third day in a row above. Drives streak language.
  final int streakDaysAboveAverage;
}

/// 7-day history for the trend bar chart — carries both metrics; the registry
/// picks which to chart per deviceType (walker → steps, rollator → active-min).
class DayStep {
  const DayStep({
    required this.weekday,
    required this.steps,
    this.activeMinutes = 0,
  });
  final String weekday; // "Mon", "Tue", ...
  final int steps;
  final int activeMinutes;
}

/// One completed walking session (Strava-style activity feed row).
class WalkSession {
  const WalkSession({
    required this.startTimeOfDay,
    required this.durationMinutes,
    required this.steps,
    required this.distanceFt,
    this.activeMinutes = 0,
    this.gaitSpeedFts,
  });

  /// e.g. "7:42 AM" — local time-of-day; renders right-aligned.
  final String startTimeOfDay;
  final int durationMinutes;
  final int steps;
  final int distanceFt;

  /// Active-minutes for this session; the rollator recent-walk row shows this
  /// in place of steps. Gait speed (ft/s) when the firmware reported it.
  final int activeMinutes;
  final double? gaitSpeedFts;
}

/// An active (unacknowledged) alert.
class WalkerAlert {
  const WalkerAlert({
    required this.id,
    required this.icon,
    required this.title,
    required this.detail,
    required this.severity,
    required this.openedMinAgo,
  });

  final String id;
  final IconData icon;
  final String title;
  final String detail;
  final AlertSeverity severity;
  final int openedMinAgo;
}

enum AlertSeverity { critical, warning, info }

class CareNote {
  const CareNote({
    required this.text,
    required this.updatedByName,
    required this.updatedAt,
  });

  final String text;
  final String updatedByName;
  final DateTime updatedAt;
}

class DeviceHealth {
  const DeviceHealth({
    required this.connected,
    required this.batteryPct,
    required this.signalLabel, // "Excellent" | "Good" | "Weak" | "Lost"
    required this.lastSeenMinAgo,
  });

  final bool connected;
  final double batteryPct;
  final String signalLabel;
  final int lastSeenMinAgo;
}

/// Snapshot consumed by the Dashboard. Bundling here keeps the screen
/// constructor tight — one object, easy to swap in `D2CLiveRepository`
/// later by returning the same shape from the API layer.
class D2CDashboardSnapshot {
  const D2CDashboardSnapshot({
    required this.viewer,
    required this.walker,
    required this.today,
    required this.last7Days,
    required this.recentWalks,
    required this.openAlerts,
    required this.careNote,
    required this.device,
    this.isPreActivation = false,
    this.hasWalker = true,
    this.deviceType = 'walker_cap',
  });

  final CareCircleMember viewer;
  final Walker walker;

  /// Device type of the patient's current device (`walker_cap` |
  /// `rollator_platform`) — selects the per-type metric view (DT-4). Default
  /// walker_cap keeps every existing wireframe snapshot rendering unchanged.
  final String deviceType;
  final TodayActivity today;
  final List<DayStep> last7Days;
  /// Today's completed walking sessions, newest-first. Drives the
  /// "Today's walks" Strava-style activity feed.
  final List<WalkSession> recentWalks;
  final List<WalkerAlert> openAlerts;
  final CareNote? careNote;
  final DeviceHealth device;

  /// Device bound + shipped but never checked in. Drives the distinct
  /// "walker is on the way" first-run hero instead of the activity view.
  final bool isPreActivation;

  /// Whether this household currently has a walker at all. False when the
  /// device was never claimed or was rotated to another household — drives
  /// the "no walker connected" empty state instead of the pre-activation
  /// hero (which wrongly implied a walker was on its way).
  final bool hasWalker;
}

// ─────────────────────────────────────────────────────────────────────
// Care Circle + onboarding + account models
// ─────────────────────────────────────────────────────────────────────

/// A pending invitation (sent, not yet claimed).
class PendingInvite {
  const PendingInvite({
    this.id = '',                 // inviteId (live; drives resend/revoke)
    required this.name,
    required this.email,
    this.contactMask = '',        // •••-1234 (live phone-first invites)
    required this.relationship,
    required this.invitedByName,
    required this.sentAt,
    required this.asAdmin,
    required this.expiresInDays,
  });

  final String id;
  final String name;
  final String email;
  final String contactMask;
  final String relationship;
  final String invitedByName;
  final DateTime sentAt;
  final bool asAdmin;
  final int expiresInDays;
}

/// Everything the Care Team screen needs, from one repository call:
/// the confirmed roster, pending invites (Admins only), walk-up access
/// requests (mock/5b only — the live backend returns none until 5b
/// ships), and the viewer's own standing in the circle.
class CareCircleData {
  const CareCircleData({
    required this.members,
    required this.invites,
    this.requests = const [],
    required this.walkerName,
    required this.viewerIsAdmin,
    required this.viewerUserId,
  });

  final List<CareCircleMember> members;
  final List<PendingInvite> invites;
  final List<AccessRequest> requests;
  final String walkerName;
  final bool viewerIsAdmin;
  final String viewerUserId;
}

/// A walk-up access request awaiting Admin approval (from QR scan).
class AccessRequest {
  const AccessRequest({
    required this.name,
    required this.relationshipClaim,
    required this.note,
    required this.requestedAt,
    this.signedUpAt,
  });

  final String name;
  final String relationshipClaim;
  final String note;
  final DateTime requestedAt;
  final DateTime? signedUpAt;
}

/// One row in the notification-preferences matrix: an alert type the
/// user can route per channel. `deviceOperational` rows are only shown
/// to Admins (walker users / plain members don't manage the device).
class NotificationPref {
  NotificationPref({
    required this.alertType,
    required this.label,
    required this.description,
    required this.sms,
    required this.email,
    this.deviceOperational = false,
  });

  final String alertType;
  final String label;
  final String description;
  bool sms;
  bool email;
  final bool deviceOperational;
}

/// One day of activity for the 30/90-day History view.
class HistoryDay {
  const HistoryDay({
    required this.date,
    required this.steps,
    required this.activeMinutes,
    this.deviceType = 'walker_cap',
  });

  final DateTime date;
  final int steps;
  final int activeMinutes;
  final String deviceType;
}

/// One row in the customer-facing audit log ("who accessed Mom's data").
class AuditEntry {
  const AuditEntry({
    required this.actorName,
    required this.action,
    required this.at,
  });

  final String actorName;
  final String action; // "viewed activity", "acknowledged an alert", ...
  final DateTime at;
}

class D2CMockData {
  // ── Care Circle ─────────────────────────────────────────────────

  /// Members of Susan's Care Circle. Sarah (daughter, Admin + viewer),
  /// Michael (son, plain Member), Susan (walker user, no account yet).
  static List<CareCircleMember> careCircle() => [
        CareCircleMember(
          userId: 'user_sarah',
          displayName: 'Sarah Davis',
          relationship: 'Daughter',
          email: 'sarah.davis@gmail.com',
          phoneE164: '+14155551234',
          isAdmin: true,
          isWalkerUser: false,
          isViewer: true,
          lastActiveAt: DateTime.now().subtract(const Duration(minutes: 4)),
        ),
        CareCircleMember(
          userId: 'user_michael',
          displayName: 'Michael Davis',
          relationship: 'Son',
          email: 'mdavis84@outlook.com',
          phoneE164: '+12065559876',
          isAdmin: false,
          isWalkerUser: false,
          isViewer: false,
          lastActiveAt: DateTime.now().subtract(const Duration(hours: 19)),
        ),
        CareCircleMember(
          userId: 'user_susan',
          displayName: 'Susan Davis',
          relationship: 'Self',
          email: '',
          phoneE164: null,
          isAdmin: false,
          isWalkerUser: true,
          isViewer: false,
          lastActiveAt: null, // no account
        ),
      ];

  static List<PendingInvite> pendingInvites() => [
        PendingInvite(
          name: 'Karen Davis',
          email: 'karen.d.rn@gmail.com',
          relationship: 'Daughter-in-law',
          invitedByName: 'Sarah',
          sentAt: DateTime.now().subtract(const Duration(days: 2)),
          asAdmin: false,
          expiresInDays: 12,
        ),
      ];

  static List<AccessRequest> accessRequests() => [
        AccessRequest(
          name: 'Tom Davis',
          relationshipClaim: 'Grandson',
          note: "Hi Grandma, it's Tom — I scanned the code on your walker "
              'and would love to keep an eye on your walks while I\'m away '
              'at school.',
          requestedAt: DateTime.now().subtract(const Duration(hours: 3)),
          signedUpAt: DateTime.now().subtract(const Duration(hours: 3, minutes: 2)),
        ),
      ];

  // ── Notification preferences ────────────────────────────────────

  static List<NotificationPref> notificationPrefs() => [
        NotificationPref(
          alertType: 'no_activity_today',
          label: 'No activity today',
          description: 'No walks logged by mid-morning',
          sms: true,
          email: true,
        ),
        NotificationPref(
          alertType: 'below_typical_activity',
          label: 'Lower than usual',
          description: 'A noticeably quieter day than her norm',
          sms: false,
          email: true,
        ),
        NotificationPref(
          alertType: 'declining_trend',
          label: 'Declining trend',
          description: 'A downward trend over the past week',
          sms: false,
          email: true,
        ),
        NotificationPref(
          alertType: 'fall_impact',
          label: 'Possible fall',
          description: 'A sudden impact or tip-over detected',
          sms: true,
          email: true,
        ),
        NotificationPref(
          alertType: 'device_offline',
          label: 'Device offline',
          description: "The walker hasn't checked in for a while",
          sms: false,
          email: true,
          deviceOperational: true,
        ),
        NotificationPref(
          alertType: 'battery_low',
          label: 'Low battery',
          description: 'Time to replace the AA batteries',
          sms: false,
          email: true,
          deviceOperational: true,
        ),
      ];

  // ── Activity history (30 / 90-day view) ─────────────────────────

  /// Deterministic daily history, newest-last. Gentle weekly rhythm
  /// (weekends lighter) + a slow upward trend so the longer view tells
  /// an encouraging "improving over time" story. Seeded so the mock is
  /// stable across reloads.
  static List<HistoryDay> history({int days = 90}) {
    final out = <HistoryDay>[];
    final today = DateTime.now();
    final start = DateTime(today.year, today.month, today.day)
        .subtract(Duration(days: days - 1));
    for (var i = 0; i < days; i++) {
      final date = start.add(Duration(days: i));
      // Base trend: ramps from ~700 up to ~1,250 across the window.
      final trend = 700 + (550 * (i / (days - 1)));
      // Weekly rhythm: weekends (Sat=6, Sun=7) a bit lighter.
      final wd = date.weekday;
      final weekend = (wd == DateTime.saturday || wd == DateTime.sunday);
      final rhythm = weekend ? 0.72 : 1.0;
      // Deterministic wobble from the day-of-year.
      final wobble = 0.85 + ((date.day * 37 + date.month * 13) % 30) / 100.0;
      var steps = (trend * rhythm * wobble).round();
      // A couple of seeded "rest days" near zero for realism.
      if (i == days - 12 || i == days - 27) steps = (steps * 0.12).round();
      final activeMin = (steps / 39).round();
      out.add(HistoryDay(date: date, steps: steps, activeMinutes: activeMin));
    }
    return out;
  }

  // ── Customer audit log ──────────────────────────────────────────

  static List<AuditEntry> auditLog() => [
        AuditEntry(
          actorName: 'You',
          action: 'viewed activity',
          at: DateTime.now().subtract(const Duration(minutes: 4)),
        ),
        AuditEntry(
          actorName: 'Michael Davis',
          action: 'viewed activity',
          at: DateTime.now().subtract(const Duration(hours: 19)),
        ),
        AuditEntry(
          actorName: 'Sarah Davis',
          action: 'acknowledged a low-battery alert',
          at: DateTime.now().subtract(const Duration(days: 1, hours: 2)),
        ),
        AuditEntry(
          actorName: 'Sarah Davis',
          action: 'updated the care note',
          at: DateTime.now().subtract(const Duration(days: 2)),
        ),
        AuditEntry(
          actorName: 'Michael Davis',
          action: 'joined the Care Circle',
          at: DateTime.now().subtract(const Duration(days: 9)),
        ),
      ];

  // ── Dashboard snapshots ─────────────────────────────────────────

  /// Default: Sarah (Admin, walker's daughter) viewing Susan's data.
  /// Use this for the initial wireframe screens.
  static D2CDashboardSnapshot susanViewedBySarah() {
    final susan = Walker(
      id: 'pat_d2c_susan',
      displayName: 'Susan Davis',
      firstName: 'Susan',
      relationshipToViewer: 'Mom',
      deviceSerial: 'GS0000004421',
    );
    final sarah = CareCircleMember(
      userId: 'user_sarah',
      displayName: 'Sarah Davis',
      relationship: 'Daughter',
      email: 'sarah.davis@gmail.com',
      phoneE164: '+14155551234',
      isAdmin: true,
      isWalkerUser: false,
      isViewer: true,
      lastActiveAt: DateTime.now(),
    );
    return D2CDashboardSnapshot(
      viewer: sarah,
      walker: susan,
      today: const TodayActivity(
        steps: 1247,
        distanceFt: 942,
        activeMinutes: 32,
        lastSessionEndedMinAgo: 18,
        percentChangeFromYesterday: 12,
        weeklyAverageSteps: 976, // mean of the 7 history days below
        is7DayHigh: false,        // Thu was higher (1,310)
        streakDaysAboveAverage: 3, // Sun/Mon/Tue above 976
      ),
      last7Days: const [
        DayStep(weekday: 'Wed', steps: 980),
        DayStep(weekday: 'Thu', steps: 1310),
        DayStep(weekday: 'Fri', steps: 850),
        DayStep(weekday: 'Sat', steps: 410),
        DayStep(weekday: 'Sun', steps: 1180),
        DayStep(weekday: 'Mon', steps: 1102),
        DayStep(weekday: 'Tue', steps: 1247),
      ],
      recentWalks: const [
        // Newest first; today's sessions only.
        WalkSession(
          startTimeOfDay: '2:18 PM',
          durationMinutes: 8,
          steps: 412,
          distanceFt: 310,
        ),
        WalkSession(
          startTimeOfDay: '11:04 AM',
          durationMinutes: 14,
          steps: 583,
          distanceFt: 441,
        ),
        WalkSession(
          startTimeOfDay: '7:42 AM',
          durationMinutes: 10,
          steps: 252,
          distanceFt: 191,
        ),
      ],
      openAlerts: const [
        WalkerAlert(
          id: 'alert_1',
          icon: Icons.battery_alert_outlined,
          title: 'Battery is getting low',
          detail: 'Battery at 12% — replace the AAs in the next day or two.',
          severity: AlertSeverity.warning,
          openedMinAgo: 47,
        ),
      ],
      careNote: CareNote(
        text: 'Started a new walking routine after PT — aiming for two laps around the building every morning.',
        updatedByName: 'Sarah',
        updatedAt: DateTime.now().subtract(const Duration(days: 2)),
      ),
      device: const DeviceHealth(
        connected: true,
        batteryPct: 0.12,
        signalLabel: 'Good',
        lastSeenMinAgo: 18,
      ),
    );
  }

  /// Empty state — device connected + activated, but no activity logged
  /// yet today (e.g. early morning, or first day on the cap).
  static D2CDashboardSnapshot susanEmptyToday() {
    final base = susanViewedBySarah();
    return D2CDashboardSnapshot(
      viewer: base.viewer,
      walker: base.walker,
      today: const TodayActivity(
        steps: 0,
        distanceFt: 0,
        activeMinutes: 0,
        lastSessionEndedMinAgo: null,
        percentChangeFromYesterday: 0,
        weeklyAverageSteps: 976,
        is7DayHigh: false,
        streakDaysAboveAverage: 0,
      ),
      last7Days: base.last7Days,
      recentWalks: const [],
      openAlerts: const [],
      careNote: base.careNote,
      device: const DeviceHealth(
        connected: true,
        batteryPct: 0.74,
        signalLabel: 'Good',
        lastSeenMinAgo: 6,
      ),
    );
  }

  /// Pre-activation — device shipped + bound but hasn't powered on /
  /// checked in yet. The "your walker is on the way" first-run state.
  static D2CDashboardSnapshot susanPreActivation() {
    final base = susanViewedBySarah();
    return D2CDashboardSnapshot(
      viewer: base.viewer,
      walker: base.walker,
      today: const TodayActivity(
        steps: 0,
        distanceFt: 0,
        activeMinutes: 0,
        lastSessionEndedMinAgo: null,
        percentChangeFromYesterday: 0,
        weeklyAverageSteps: 0,
        is7DayHigh: false,
        streakDaysAboveAverage: 0,
      ),
      last7Days: const [],
      recentWalks: const [],
      openAlerts: const [],
      careNote: null,
      device: const DeviceHealth(
        connected: false,
        batteryPct: 0,
        signalLabel: 'Lost',
        lastSeenMinAgo: 0,
      ),
      isPreActivation: true,
    );
  }

  /// Same household, told from Susan's POV (she signed up + has
  /// `isWalkerUser=true`). Drives the walker-user copy variant.
  static D2CDashboardSnapshot susanViewedBySelf() {
    final base = susanViewedBySarah();
    return D2CDashboardSnapshot(
      viewer: CareCircleMember(
        userId: 'user_susan',
        displayName: 'Susan Davis',
        relationship: 'Self',
        email: 'susan.davis@gmail.com',
        phoneE164: '+14155557890',
        isAdmin: false,
        isWalkerUser: true,
        isViewer: true,
        lastActiveAt: DateTime.now(),
      ),
      walker: base.walker,
      today: base.today,
      last7Days: base.last7Days,
      recentWalks: base.recentWalks,
      openAlerts: base.openAlerts,
      careNote: base.careNote,
      device: base.device,
    );
  }
}
