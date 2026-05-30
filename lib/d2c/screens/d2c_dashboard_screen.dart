import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../theme/app_theme.dart';
import '../data/d2c_mock_data.dart';
import '../widgets/d2c_bottom_nav.dart';

/// D2C Home / Dashboard. Single household viewed by either an Admin
/// caregiver or the walker user themselves (`isWalkerUser=true`).
///
/// Design intent:
/// - **Person-centric, not device-centric.** The subject is Eleanor
///   (or "you"), not "the walker." App bar shows the person, not the
///   device. Greeting talks about activity, not connectivity.
/// - **Whoop/Strava-style contextualization.** Today's numbers always
///   land relative to a baseline ("strongest day this week", "3 days
///   above your pace"). Numbers without context are noise.
/// - **Role-conditional surfaces.** Walker user sees activity only —
///   device alerts + care note + device card are operational concerns
///   for the Admin, hidden from the walker user. Bottom nav swaps
///   "Care Team" for "History" in walker user mode.
class D2CDashboardScreen extends StatelessWidget {
  const D2CDashboardScreen({
    super.key,
    required this.snapshot,
    this.onSwitchViewer,
  });

  final D2CDashboardSnapshot snapshot;

  /// Dev-only affordance for the preview route — flips between the
  /// Admin caregiver view and the walker-user view so the user can
  /// see both copy variants in one session. Null in production.
  final VoidCallback? onSwitchViewer;

  bool get _isWalkerUser => snapshot.viewer.isWalkerUser;

  @override
  Widget build(BuildContext context) {
    if (snapshot.isPreActivation) {
      return Scaffold(
        backgroundColor: AppTheme.warmWhite,
        appBar: _buildAppBar(context),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 96),
              child: _PreActivationView(snapshot: snapshot),
            ),
          ),
        ),
        bottomNavigationBar: const D2CBottomNav(active: D2CTab.activity),
      );
    }
    return Scaffold(
      backgroundColor: AppTheme.warmWhite,
      appBar: _buildAppBar(context),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 96),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _GreetingCard(snapshot: snapshot),
                const SizedBox(height: 18),
                _StatRow(today: snapshot.today),
                const SizedBox(height: 12),
                _WeekContextLine(today: snapshot.today),
                const SizedBox(height: 22),
                _DayTrendCard(
                  days: snapshot.last7Days,
                  todayLabel: NumberFormat('#,##0').format(snapshot.today.steps),
                ),
                if (snapshot.recentWalks.isNotEmpty) ...[
                  const SizedBox(height: 26),
                  _RecentWalksSection(
                    walks: snapshot.recentWalks,
                    isWalkerUser: _isWalkerUser,
                  ),
                ],
                if (snapshot.openAlerts.isNotEmpty) ...[
                  const SizedBox(height: 26),
                  const _SectionLabel('Today\'s alerts'),
                  const SizedBox(height: 10),
                  for (final a in snapshot.openAlerts) ...[
                    _AlertCard(alert: a),
                    const SizedBox(height: 10),
                  ],
                ],
                if (snapshot.careNote != null) ...[
                  const SizedBox(height: 18),
                  _CareNoteCard(
                    note: snapshot.careNote!,
                    canEdit: snapshot.viewer.isAdmin,
                  ),
                ],
                const SizedBox(height: 22),
                _DeviceCard(device: snapshot.device),
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: const D2CBottomNav(active: D2CTab.activity),
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    final v = snapshot.viewer;
    final w = snapshot.walker;
    // Person-centric titles. No "walker" framing anywhere.
    // - Caregiver: the person's first name. Sets context for whose data this is.
    // - Walker user: today's date. Acts as a journal/log header rather than
    //   a tracking-dashboard header. Greeting hero IS the headline.
    final title = v.isWalkerUser
        ? DateFormat('EEEE, MMM d').format(DateTime.now())
        : w.firstName;
    return AppBar(
      backgroundColor: AppTheme.warmWhite,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      title: Text(
        title,
        style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontSize: v.isWalkerUser ? 16 : 20,
              fontWeight: v.isWalkerUser ? FontWeight.w500 : FontWeight.w600,
              color: v.isWalkerUser ? AppTheme.textSoft : AppTheme.textDark,
            ),
      ),
      actions: [
        if (onSwitchViewer != null)
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: IconButton(
              tooltip: v.isWalkerUser
                  ? 'Preview: switch to caregiver view'
                  : 'Preview: switch to walker-user view',
              onPressed: onSwitchViewer,
              icon: Icon(
                v.isWalkerUser
                    ? Icons.supervisor_account_outlined
                    : Icons.person_outline,
                color: AppTheme.textSoft,
              ),
            ),
          ),
        IconButton(
          tooltip: 'Settings',
          onPressed: () {},
          icon: const Icon(Icons.settings_outlined, color: AppTheme.textSoft),
        ),
        const SizedBox(width: 4),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Pre-activation hero — "your walker is on the way / powering on"
// ─────────────────────────────────────────────────────────────────────

class _PreActivationView extends StatelessWidget {
  const _PreActivationView({required this.snapshot});
  final D2CDashboardSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final name = snapshot.walker.firstName;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 24),
        Center(
          child: Container(
            width: 84,
            height: 84,
            decoration: BoxDecoration(
              color: AppTheme.sage.withOpacity(0.10),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.cell_tower_rounded,
              size: 40,
              color: AppTheme.sage,
            ),
          ),
        ),
        const SizedBox(height: 24),
        Text(
          "$name's walker is getting set up",
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontSize: 24,
                height: 1.2,
              ),
        ),
        const SizedBox(height: 12),
        const Text(
          'Once the cap is clipped on and powered up, it connects on its '
          'own over cellular — no Wi-Fi or setup needed. The first check-in '
          'usually lands within about 10 minutes.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppTheme.textSoft,
            fontSize: 15,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 28),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(AppTheme.cardRadius),
            boxShadow: AppTheme.cardShadow,
          ),
          child: Column(
            children: const [
              _SetupStep(
                n: '1',
                text: 'Clip the GoSteady cap onto the walker frame.',
              ),
              SizedBox(height: 16),
              _SetupStep(
                n: '2',
                text: 'Press and hold the button until the light turns on.',
              ),
              SizedBox(height: 16),
              _SetupStep(
                n: '3',
                text: "We'll text you the moment it connects.",
                last: true,
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        Center(
          child: Text(
            'Waiting for first connection…',
            style: TextStyle(
              color: AppTheme.textSoft.withOpacity(0.9),
              fontSize: 13,
              fontStyle: FontStyle.italic,
            ),
          ),
        ),
      ],
    );
  }
}

class _SetupStep extends StatelessWidget {
  const _SetupStep({required this.n, required this.text, this.last = false});
  final String n;
  final String text;
  final bool last;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            color: AppTheme.sage.withOpacity(0.12),
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Text(
            n,
            style: const TextStyle(
              color: AppTheme.sage,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(
              text,
              style: const TextStyle(
                color: AppTheme.textDark,
                fontSize: 14.5,
                height: 1.4,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Greeting hero — Whoop-style data-driven copy
// ─────────────────────────────────────────────────────────────────────
//
// Rules of thumb (from looking at how Whoop / Strava / Apple Fitness
// frame their morning summaries):
//   - Lead with a concrete number or status, not a generic affirmation
//   - Add one contextualizing comparison ("strongest day this week",
//     "3 days above your pace", "trending up")
//   - Keep it tight — 1 short line + optional sub-line
//   - Use streak / personal-best language when the data supports it
//   - Walker user is the subject ("you"); caregiver gets the person's
//     name as the subject ("Eleanor")
//
// Copy precedence (most specific wins):
//   1. is7DayHigh (best day this week)
//   2. streakDaysAboveAverage >= 3 (three-day streak)
//   3. above weeklyAverageSteps (above pace)
//   4. below weeklyAverageSteps but > 0 (lighter day, no judgment)
//   5. steps == 0 + morning (no activity yet, neutral)
//   6. steps == 0 + afternoon (resting day, neutral)

class _GreetingCard extends StatelessWidget {
  const _GreetingCard({required this.snapshot});

  final D2CDashboardSnapshot snapshot;

  ({String headline, String? subhead}) _copy() {
    final t = snapshot.today;
    final w = snapshot.walker;
    final isYou = snapshot.viewer.isWalkerUser;
    final theirs = isYou ? 'your' : '${w.firstName}\'s';

    // 1. Personal best — strongest day this week
    if (t.is7DayHigh && t.steps > 0) {
      return (
        headline: isYou
            ? 'Your most active day this week.'
            : "${w.firstName}'s most active day this week.",
        subhead:
            '${NumberFormat('#,##0').format(t.steps)} steps · ${t.percentChangeFromYesterday}% above yesterday.',
      );
    }

    // 2. Three-day streak above pace
    if (t.streakDaysAboveAverage >= 3 && t.steps >= t.weeklyAverageSteps) {
      return (
        headline: isYou
            ? '${t.streakDaysAboveAverage} steady days in a row.'
            : '${w.firstName} — ${t.streakDaysAboveAverage} steady days in a row.',
        subhead:
            '${NumberFormat('#,##0').format(t.steps)} steps so far, above $theirs usual again. Nice and steady.',
      );
    }

    // 3. Above weekly pace (less than 3-day streak)
    if (t.steps >= t.weeklyAverageSteps && t.weeklyAverageSteps > 0) {
      final pct =
          (((t.steps - t.weeklyAverageSteps) / t.weeklyAverageSteps) * 100)
              .round();
      return (
        headline: isYou
            ? "You're ahead of your usual today."
            : '${w.firstName} is ahead of her usual today.',
        subhead:
            '${NumberFormat('#,##0').format(t.steps)} steps so far · $pct% above a typical day.',
      );
    }

    // 4. Lighter than usual but still some movement
    if (t.steps > 0 && t.steps < t.weeklyAverageSteps) {
      final pct =
          (((t.weeklyAverageSteps - t.steps) / t.weeklyAverageSteps) * 100)
              .round();
      return (
        headline: isYou
            ? 'A quieter day so far.'
            : 'A quieter day for ${w.firstName} so far.',
        subhead: '${NumberFormat('#,##0').format(t.steps)} steps · $pct% '
            'below a typical day.',
      );
    }

    // 5/6. No activity yet today — time-of-day-aware framing
    final hour = DateTime.now().hour;
    if (hour < 12) {
      return (
        headline: isYou
            ? 'Quiet morning so far.'
            : 'Quiet morning for ${w.firstName}.',
        subhead: 'No walks logged yet.',
      );
    }
    return (
      headline: isYou
          ? 'A restful day so far.'
          : 'A restful day for ${w.firstName} so far.',
      subhead: 'No activity logged today.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = _copy();
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 26, 24, 22),
      decoration: BoxDecoration(
        color: AppTheme.sage.withOpacity(0.06),
        borderRadius: BorderRadius.circular(AppTheme.cardRadius),
        border: Border.all(color: AppTheme.sage.withOpacity(0.18), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            c.headline,
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontSize: 26,
                  height: 1.15,
                ),
          ),
          if (c.subhead != null) ...[
            const SizedBox(height: 8),
            Text(
              c.subhead!,
              style: const TextStyle(
                color: AppTheme.textSoft,
                fontSize: 15,
                height: 1.45,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Stat row: steps / distance / active min
// ─────────────────────────────────────────────────────────────────────

class _StatRow extends StatelessWidget {
  const _StatRow({required this.today});
  final TodayActivity today;

  @override
  Widget build(BuildContext context) {
    final stepsFmt = NumberFormat('#,##0').format(today.steps);
    final distFmt = NumberFormat('#,##0').format(today.distanceFt);
    return Row(
      children: [
        Expanded(
          child: _StatTile(
            value: stepsFmt,
            unit: 'steps',
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _StatTile(
            value: distFmt,
            unit: 'feet',
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _StatTile(
            value: today.activeMinutes.toString(),
            unit: 'active min',
          ),
        ),
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({required this.value, required this.unit});

  final String value;
  final String unit;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: AppTheme.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: const TextStyle(
              color: AppTheme.textDark,
              fontSize: 26,
              fontWeight: FontWeight.w700,
              height: 1.0,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            unit,
            style: const TextStyle(
              color: AppTheme.textSoft,
              fontSize: 12.5,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Week context line — single-line takeaway under the stat row
// ─────────────────────────────────────────────────────────────────────

class _WeekContextLine extends StatelessWidget {
  const _WeekContextLine({required this.today});
  final TodayActivity today;

  String? _line() {
    final delta = today.steps - today.weeklyAverageSteps;
    final pct = today.weeklyAverageSteps == 0
        ? 0
        : ((delta / today.weeklyAverageSteps) * 100).round();
    if (today.is7DayHigh && today.steps > 0) {
      return 'Personal best this week';
    }
    if (today.streakDaysAboveAverage >= 3) {
      return '${today.streakDaysAboveAverage} days in a row above weekly average';
    }
    if (delta > 0) return '$pct% above weekly average';
    if (delta < 0 && today.steps > 0) {
      return '${pct.abs()}% below weekly average';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final line = _line();
    if (line == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          Icon(Icons.bolt_rounded, size: 14, color: AppTheme.sage),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              line,
              style: const TextStyle(
                color: AppTheme.sage,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.1,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// 7-day trend bar chart strip with today annotation
// ─────────────────────────────────────────────────────────────────────

class _DayTrendCard extends StatelessWidget {
  const _DayTrendCard({required this.days, required this.todayLabel});
  final List<DayStep> days;
  final String todayLabel;

  @override
  Widget build(BuildContext context) {
    final maxSteps =
        days.map((d) => d.steps).fold<int>(0, (a, b) => a > b ? a : b);
    final maxBarHeight = 70.0;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppTheme.cardRadius),
        boxShadow: AppTheme.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Last 7 days',
                style: TextStyle(
                  color: AppTheme.textDark,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                'See more',
                style: TextStyle(
                  color: AppTheme.sage,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 28),
          SizedBox(
            height: maxBarHeight + 40,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (var i = 0; i < days.length; i++) ...[
                  Expanded(
                    child: _DayBar(
                      day: days[i],
                      maxSteps: maxSteps,
                      maxHeight: maxBarHeight,
                      isToday: i == days.length - 1,
                      todayLabel: i == days.length - 1 ? todayLabel : null,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DayBar extends StatelessWidget {
  const _DayBar({
    required this.day,
    required this.maxSteps,
    required this.maxHeight,
    required this.isToday,
    this.todayLabel,
  });

  final DayStep day;
  final int maxSteps;
  final double maxHeight;
  final bool isToday;
  final String? todayLabel;

  @override
  Widget build(BuildContext context) {
    final h = maxSteps == 0 ? 0.0 : (day.steps / maxSteps) * maxHeight;
    final color = isToday ? AppTheme.sage : AppTheme.sage.withOpacity(0.32);
    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        SizedBox(
          height: 16,
          child: isToday && todayLabel != null
              ? Text(
                  todayLabel!,
                  style: const TextStyle(
                    color: AppTheme.textDark,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                  ),
                )
              : null,
        ),
        Container(
          width: 24,
          height: h,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(7),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          day.weekday,
          style: TextStyle(
            color: isToday ? AppTheme.textDark : AppTheme.textSoft,
            fontSize: 11,
            fontWeight: isToday ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Section label
// ─────────────────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        text.toUpperCase(),
        style: const TextStyle(
          color: AppTheme.textSoft,
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.0,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Recent walks — Strava-style activity feed
// ─────────────────────────────────────────────────────────────────────
//
// Shows today's completed walking sessions, newest first. Each row is
// a compact summary: time of day · duration · step count. Intent is
// the same satisfaction loop Strava + Whoop nail — "here's the thing
// you did, here's what it counted for."

class _RecentWalksSection extends StatelessWidget {
  const _RecentWalksSection({
    required this.walks,
    required this.isWalkerUser,
  });

  final List<WalkSession> walks;
  final bool isWalkerUser;

  @override
  Widget build(BuildContext context) {
    final shown = walks.take(4).toList();
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppTheme.cardRadius),
        boxShadow: AppTheme.cardShadow,
      ),
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                "Today's walks",
                style: TextStyle(
                  color: AppTheme.textDark,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                '${walks.length} session${walks.length == 1 ? '' : 's'}',
                style: const TextStyle(
                  color: AppTheme.textSoft,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < shown.length; i++) ...[
            _WalkRow(walk: shown[i]),
            if (i < shown.length - 1)
              Divider(
                height: 1,
                color: AppTheme.border.withOpacity(0.5),
              ),
          ],
        ],
      ),
    );
  }
}

class _WalkRow extends StatelessWidget {
  const _WalkRow({required this.walk});
  final WalkSession walk;

  @override
  Widget build(BuildContext context) {
    final stepsFmt = NumberFormat('#,##0').format(walk.steps);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: AppTheme.sage.withOpacity(0.10),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Icons.directions_walk_rounded,
              size: 18,
              color: AppTheme.sage,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  walk.startTimeOfDay,
                  style: const TextStyle(
                    color: AppTheme.textDark,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                    height: 1.1,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '${walk.durationMinutes} min · ${walk.distanceFt} ft',
                  style: const TextStyle(
                    color: AppTheme.textSoft,
                    fontSize: 12.5,
                  ),
                ),
              ],
            ),
          ),
          Text(
            stepsFmt,
            style: const TextStyle(
              color: AppTheme.textDark,
              fontSize: 16,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
            ),
          ),
          const SizedBox(width: 4),
          const Text(
            'steps',
            style: TextStyle(
              color: AppTheme.textSoft,
              fontSize: 11.5,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Alert card
// ─────────────────────────────────────────────────────────────────────

class _AlertCard extends StatelessWidget {
  const _AlertCard({required this.alert});
  final WalkerAlert alert;

  Color _severityColor() {
    switch (alert.severity) {
      case AlertSeverity.critical:
        return AppTheme.statusAlert;
      case AlertSeverity.warning:
        return AppTheme.statusWarn;
      case AlertSeverity.info:
        return AppTheme.sage;
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = _severityColor();
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 16, 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withOpacity(0.35), width: 1),
        boxShadow: AppTheme.cardShadow,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: color.withOpacity(0.12),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(alert.icon, size: 20, color: color),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  alert.title,
                  style: const TextStyle(
                    color: AppTheme.textDark,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  alert.detail,
                  style: const TextStyle(
                    color: AppTheme.textSoft,
                    fontSize: 13.5,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Text(
                      '${alert.openedMinAgo} min ago',
                      style: TextStyle(
                        color: AppTheme.textSoft.withOpacity(0.8),
                        fontSize: 12,
                      ),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: () {},
                      style: TextButton.styleFrom(
                        foregroundColor: color,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text(
                        'Acknowledge',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Care note
// ─────────────────────────────────────────────────────────────────────

class _CareNoteCard extends StatelessWidget {
  const _CareNoteCard({required this.note, required this.canEdit});
  final CareNote note;
  final bool canEdit;

  @override
  Widget build(BuildContext context) {
    final ago = _ago(note.updatedAt);
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 16, 16),
      decoration: BoxDecoration(
        color: AppTheme.sage.withOpacity(0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.sage.withOpacity(0.18), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.sticky_note_2_outlined,
                size: 16,
                color: AppTheme.sage,
              ),
              const SizedBox(width: 6),
              const Text(
                'Care note',
                style: TextStyle(
                  color: AppTheme.sage,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
              const Spacer(),
              if (canEdit)
                IconButton(
                  onPressed: () {},
                  icon: const Icon(Icons.edit_outlined, size: 16),
                  visualDensity: VisualDensity.compact,
                  style:
                      IconButton.styleFrom(foregroundColor: AppTheme.textSoft),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            note.text,
            style: const TextStyle(
              color: AppTheme.textDark,
              fontSize: 14.5,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Updated by ${note.updatedByName} · $ago',
            style: TextStyle(
              color: AppTheme.textSoft,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inDays >= 1) return '${d.inDays} day${d.inDays == 1 ? '' : 's'} ago';
  if (d.inHours >= 1) return '${d.inHours}h ago';
  if (d.inMinutes >= 1) return '${d.inMinutes} min ago';
  return 'just now';
}

// ─────────────────────────────────────────────────────────────────────
// Device card (caregiver-only)
// ─────────────────────────────────────────────────────────────────────

class _DeviceCard extends StatelessWidget {
  const _DeviceCard({required this.device});
  final DeviceHealth device;

  @override
  Widget build(BuildContext context) {
    final batteryPct = (device.batteryPct * 100).round();
    final batteryColor = device.batteryPct < 0.15
        ? AppTheme.statusWarn
        : (device.batteryPct < 0.3 ? AppTheme.statusWarn : AppTheme.sage);
    final dotColor =
        device.connected ? AppTheme.statusOk : AppTheme.statusOffline;

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppTheme.cardRadius),
        boxShadow: AppTheme.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: dotColor,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                device.connected ? 'Device connected' : 'Device offline',
                style: const TextStyle(
                  color: AppTheme.textDark,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '·  ${device.signalLabel} signal',
                style: const TextStyle(
                  color: AppTheme.textSoft,
                  fontSize: 13,
                ),
              ),
              const Spacer(),
              Text(
                'Last checked in ${device.lastSeenMinAgo} min ago',
                style: const TextStyle(
                  color: AppTheme.textSoft,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Icon(
                batteryPct < 15
                    ? Icons.battery_2_bar_rounded
                    : Icons.battery_5_bar_rounded,
                color: batteryColor,
                size: 18,
              ),
              const SizedBox(width: 8),
              Text(
                'Battery $batteryPct%',
                style: TextStyle(
                  color: batteryColor,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (batteryPct < 15) ...[
                const SizedBox(width: 6),
                const Text(
                  '— replace AAs soon',
                  style: TextStyle(
                    color: AppTheme.textSoft,
                    fontSize: 13,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

