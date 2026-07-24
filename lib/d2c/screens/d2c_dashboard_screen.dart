import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../theme/app_theme.dart';
import '../data/d2c_mock_data.dart';
import '../rendering/metric_registry.dart';
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
/// - **Role-conditional surfaces.** The walker/device user sees their own
///   activity and device-health status, but NOT the behavioral
///   activity-judgment alerts about themselves (no-activity / below-typical /
///   declining-trend) — those read as clinical to the person being monitored
///   and are the caregiver's concern, so they're filtered server-side for a
///   walker token (patient-api `hide_walker_alerts`) with a mirror on the
///   alert list here. Device-health alerts (offline / battery) stay visible so
///   the walker can act on their own device.
class D2CDashboardScreen extends StatelessWidget {
  const D2CDashboardScreen({
    super.key,
    required this.snapshot,
    this.onSwitchViewer,
    this.onAckAlert,
    this.coachUnread = false,
    this.onOpenCoach,
  });

  final D2CDashboardSnapshot snapshot;

  /// Dev-only affordance for the preview route — flips between the
  /// Admin caregiver view and the walker-user view so the user can
  /// see both copy variants in one session. Null in production.
  final VoidCallback? onSwitchViewer;

  /// Live alert acknowledge ("I called Mom") — 2A-AA first-write-wins,
  /// permitted for owners AND Care Circle members (d2c-care-circle.md D3).
  /// Null in the preview build (button stays visual-only).
  final void Function(WalkerAlert alert)? onAckAlert;

  /// When true (and the viewer is the walker user), a "new message from
  /// Steady" nudge appears near the top of the activity feed to pull the
  /// user into the Coach tab — the re-engagement hook (umbrella's Whoop
  /// lesson: the morning message is the pull). Cleared once Coach opens.
  final bool coachUnread;

  /// Tapping the coach nudge → open the Coach tab (the host marks it read).
  final VoidCallback? onOpenCoach;

  bool get _isWalkerUser => snapshot.viewer.isWalkerUser;

  @override
  Widget build(BuildContext context) {
    // Per-device-type metric view (DT-4): walker leads on steps, rollator on
    // active-minutes (no steps). Drives the stat row, trend chart, context
    // line, greeting, and recent-walks rendering below.
    final view = deviceTypeView(snapshot.deviceType);
    // No walker on this account (never claimed, or the device was rotated to
    // another household) → a distinct empty state, NOT the "getting set up"
    // hero (which wrongly implied a walker was on its way).
    if (!snapshot.hasWalker) {
      return Scaffold(
        backgroundColor: AppTheme.warmWhite,
        appBar: _buildAppBar(context),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 96),
              child: const _NoWalkerView(),
            ),
          ),
        ),
        bottomNavigationBar: const D2CBottomNav(active: D2CTab.activity),
      );
    }
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
                if (coachUnread && _isWalkerUser && onOpenCoach != null) ...[
                  _CoachNudge(onTap: onOpenCoach!),
                  const SizedBox(height: 18),
                ],
                _StatRow(today: snapshot.today, view: view),
                const SizedBox(height: 12),
                _WeekContextLine(today: snapshot.today, view: view),
                const SizedBox(height: 22),
                // Two explicit, self-labelled trend cards (was one ambiguous
                // hero-metric chart). Each is tappable per-day and expands that
                // day's sessions inline.
                _MetricTrendCard(
                  title: 'Active minutes',
                  unit: 'min',
                  days: snapshot.last7Days,
                  value: (d) => d.activeMinutes,
                ),
                const SizedBox(height: 16),
                _MetricTrendCard(
                  title: 'Distance traveled',
                  unit: 'ft',
                  days: snapshot.last7Days,
                  value: (d) => d.distanceFt,
                ),
                if (snapshot.recentWalks.isNotEmpty) ...[
                  const SizedBox(height: 26),
                  _RecentWalksSection(
                    walks: snapshot.recentWalks,
                    isWalkerUser: _isWalkerUser,
                    view: view,
                  ),
                ],
                if (snapshot.openAlerts.isNotEmpty) ...[
                  const SizedBox(height: 26),
                  const _SectionLabel('Today\'s alerts'),
                  const SizedBox(height: 10),
                  for (final a in snapshot.openAlerts) ...[
                    _AlertCard(
                      alert: a,
                      onAck: onAckAlert == null ? null : () => onAckAlert!(a),
                    ),
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
// Coach nudge — "new message from Steady", pulls the walker user into the
// Coach tab (ai-coach-c1-text-chat.md §5.7). Gently pops in; clears once
// Coach is opened. Colors verified WCAG-AA on the sage tint (§5.7.1).
// ─────────────────────────────────────────────────────────────────────

class _CoachNudge extends StatelessWidget {
  const _CoachNudge({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      duration: const Duration(milliseconds: 340),
      curve: Curves.easeOutBack,
      tween: Tween(begin: 0.0, end: 1.0),
      builder: (context, t, child) => Opacity(
        opacity: t.clamp(0.0, 1.0),
        child: Transform.scale(scale: 0.97 + 0.03 * t, child: child),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Ink(
            decoration: BoxDecoration(
              color: AppTheme.sage.withOpacity(0.10),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: AppTheme.sage.withOpacity(0.22)),
            ),
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Row(
              children: [
                // Circular Steady avatar with an unread dot.
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: const BoxDecoration(
                        color: AppTheme.sage,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.auto_awesome,
                          size: 20, color: Colors.white),
                    ),
                    Positioned(
                      right: -1,
                      top: -1,
                      child: Container(
                        width: 13,
                        height: 13,
                        decoration: BoxDecoration(
                          color: AppTheme.statusAlert,
                          shape: BoxShape.circle,
                          border:
                              Border.all(color: AppTheme.warmWhite, width: 2),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 13),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'New message from Steady',
                        style: TextStyle(
                          color: AppTheme.textDark,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        'Your AI activity coach has a hello for you',
                        style: TextStyle(
                          color: AppTheme.textSoft,
                          fontSize: 12.5,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(Icons.chevron_right_rounded,
                    size: 22, color: AppTheme.sage),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// No-walker empty state — account has no device (never claimed, or the
// device was rotated to another household)
// ─────────────────────────────────────────────────────────────────────

class _NoWalkerView extends StatelessWidget {
  const _NoWalkerView();

  @override
  Widget build(BuildContext context) {
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
              Icons.qr_code_scanner_rounded,
              size: 40,
              color: AppTheme.sage,
            ),
          ),
        ),
        const SizedBox(height: 24),
        Text(
          'No walker connected',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontSize: 24,
                height: 1.2,
              ),
        ),
        const SizedBox(height: 12),
        const Text(
          "There's no walker on this account right now. To set one up, scan "
          "the QR code on your GoSteady walker — it'll take you through the "
          "rest. If someone set it up for you, check with them.",
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppTheme.textSoft,
            fontSize: 15,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 24),
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
          'usually lands within a few minutes.',
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

    // Per-type hero metric (DT-4): steps for a walker cap, active-minutes for a
    // rollator (no steps). is7DayHigh / streak / weeklyAverageSteps are already
    // computed on the hero metric upstream — only the display noun differs.
    final heroIsActiveMin = deviceTypeView(snapshot.deviceType).hero ==
        ActivityMetric.activeMinutes;
    final heroVal = heroIsActiveMin ? t.activeMinutes : t.steps;
    final heroAvg = t.weeklyAverageSteps;
    final noun = heroIsActiveMin ? 'active minutes' : 'steps';
    final heroFmt = NumberFormat('#,##0').format(heroVal);

    // 1. Personal best — strongest day this week
    if (t.is7DayHigh && heroVal > 0) {
      return (
        headline: isYou
            ? 'Your most active day this week.'
            : "${w.firstName}'s most active day this week.",
        subhead:
            '$heroFmt $noun · ${t.percentChangeFromYesterday}% above yesterday.',
      );
    }

    // 2. Three-day streak above pace
    if (t.streakDaysAboveAverage >= 3 && heroVal >= heroAvg) {
      return (
        headline: isYou
            ? '${t.streakDaysAboveAverage} steady days in a row.'
            : '${w.firstName} — ${t.streakDaysAboveAverage} steady days in a row.',
        subhead:
            '$heroFmt $noun so far, above $theirs usual again. Nice and steady.',
      );
    }

    // 3. Above weekly pace (less than 3-day streak)
    if (heroVal >= heroAvg && heroAvg > 0) {
      final pct = (((heroVal - heroAvg) / heroAvg) * 100).round();
      return (
        headline: isYou
            ? "You're ahead of your usual today."
            : '${w.firstName} is ahead of her usual today.',
        subhead: '$heroFmt $noun so far · $pct% above a typical day.',
      );
    }

    // 4. Lighter than usual but still some movement
    if (heroVal > 0 && heroVal < heroAvg) {
      final pct = (((heroAvg - heroVal) / heroAvg) * 100).round();
      return (
        headline: isYou
            ? 'A quieter day so far.'
            : 'A quieter day for ${w.firstName} so far.',
        subhead: '$heroFmt $noun · $pct% below a typical day.',
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
  const _StatRow({required this.today, required this.view});
  final TodayActivity today;
  final DeviceTypeView view;

  @override
  Widget build(BuildContext context) {
    final tiles = view.statRow;
    return Row(
      children: [
        for (var i = 0; i < tiles.length; i++) ...[
          if (i > 0) const SizedBox(width: 12),
          Expanded(child: _tile(tiles[i])),
        ],
      ],
    );
  }

  _StatTile _tile(ActivityMetric m) {
    final rollator = view.deviceType == 'rollator_platform';
    switch (m) {
      case ActivityMetric.steps:
        return _StatTile(
            value: NumberFormat('#,##0').format(today.steps), unit: 'steps');
      case ActivityMetric.activeMinutes:
        return _StatTile(
            value: today.activeMinutes.toString(), unit: 'active min');
      case ActivityMetric.distanceFt:
        // Rollator distance is firmware confidence-gated — 0 means "no valid
        // estimate" (a stationary session), shown as "—", not "0".
        final v = (rollator && today.distanceFt == 0)
            ? '—'
            : NumberFormat('#,##0').format(today.distanceFt);
        return _StatTile(value: v, unit: 'feet');
      case ActivityMetric.gaitSpeedFts:
        final g = today.gaitSpeedFts;
        return _StatTile(
            value: g == null ? '—' : g.toStringAsFixed(1), unit: 'ft/s');
    }
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
  const _WeekContextLine({required this.today, required this.view});
  final TodayActivity today;
  final DeviceTypeView view;

  String? _line() {
    final heroVal = view.hero == ActivityMetric.activeMinutes
        ? today.activeMinutes
        : today.steps;
    final avg = today.weeklyAverageSteps;
    final delta = heroVal - avg;
    final pct = avg == 0 ? 0 : ((delta / avg) * 100).round();
    if (today.is7DayHigh && heroVal > 0) {
      return 'Personal best this week';
    }
    if (today.streakDaysAboveAverage >= 3) {
      return '${today.streakDaysAboveAverage} days in a row above weekly average';
    }
    if (delta > 0) return '$pct% above weekly average';
    if (delta < 0 && heroVal > 0) {
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
// Per-metric 7-day trend card — tappable days + expandable day detail
// ─────────────────────────────────────────────────────────────────────

/// One labelled 7-day bar chart for a single metric (active minutes,
/// distance). Replaces the old single hero-metric chart, which never named the
/// metric it plotted, annotated only today, and whose bars weren't tappable.
///
/// Tapping a day selects it: the header restates that day's value with its
/// unit, the bar highlights, and that day's sessions expand underneath (time ·
/// duration · distance per session). Defaults to today. Every day column is a
/// full-height tap target (~42×94), comfortably past the 44px minimum, and the
/// detail rows are flex-laid so nothing overflows a 375px phone.
class _MetricTrendCard extends StatefulWidget {
  const _MetricTrendCard({
    required this.title,
    required this.unit,
    required this.days,
    required this.value,
  });

  /// Names the metric explicitly — "Active minutes", "Distance traveled".
  final String title;

  /// Unit shown beside the selected day's value ("min", "ft").
  final String unit;

  /// Oldest-first; the last entry is today.
  final List<DayStep> days;

  /// Pulls this card's metric off a day.
  final int Function(DayStep) value;

  @override
  State<_MetricTrendCard> createState() => _MetricTrendCardState();
}

class _MetricTrendCardState extends State<_MetricTrendCard> {
  /// null → follow "today" (the last bar), so a refresh with new data keeps
  /// pointing at today rather than a stale index.
  int? _selected;

  @override
  Widget build(BuildContext context) {
    final days = widget.days;
    if (days.isEmpty) return const SizedBox.shrink();
    final idx = (_selected ?? days.length - 1).clamp(0, days.length - 1);
    final selected = days[idx];
    final maxVal = days.map(widget.value).fold<int>(0, (a, b) => a > b ? a : b);
    final fmt = NumberFormat('#,##0');

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppTheme.cardRadius),
        boxShadow: AppTheme.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.title,
            style: const TextStyle(
              color: AppTheme.textDark,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          // The selected day's value, named and united — this is what makes
          // the chart self-explanatory at a glance.
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                fmt.format(widget.value(selected)),
                style: const TextStyle(
                  color: AppTheme.textDark,
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  height: 1.1,
                ),
              ),
              const SizedBox(width: 5),
              Text(
                widget.unit,
                style: const TextStyle(
                  color: AppTheme.textSoft,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  selected.dateLabel.isEmpty
                      ? selected.weekday
                      : selected.dateLabel,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppTheme.textSoft,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i < days.length; i++)
                Expanded(
                  child: _DayBar(
                    day: days[i],
                    value: widget.value(days[i]),
                    maxValue: maxVal,
                    selected: i == idx,
                    onTap: () => setState(() => _selected = i),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          _DayDetail(day: selected),
        ],
      ),
    );
  }
}

/// One tappable day column: bar + weekday label. Bottom-aligned so bars share
/// a baseline; a zero day still renders a faint stub so it reads as tappable.
class _DayBar extends StatelessWidget {
  const _DayBar({
    required this.day,
    required this.value,
    required this.maxValue,
    required this.selected,
    required this.onTap,
  });

  final DayStep day;
  final int value;
  final int maxValue;
  final bool selected;
  final VoidCallback onTap;

  static const double _maxBarHeight = 72;

  @override
  Widget build(BuildContext context) {
    final scaled =
        maxValue == 0 ? 0.0 : (value / maxValue) * _maxBarHeight;
    // Floor a non-zero day at 4px so a light day is still visible; a true zero
    // gets a 3px stub (present, clearly empty).
    final barHeight = value > 0 ? scaled.clamp(4.0, _maxBarHeight) : 3.0;
    final color =
        selected ? AppTheme.sage : AppTheme.sage.withOpacity(0.30);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: _maxBarHeight,
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Container(
                  height: barHeight,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(7),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              day.weekday,
              maxLines: 1,
              overflow: TextOverflow.clip,
              style: TextStyle(
                color: selected ? AppTheme.textDark : AppTheme.textSoft,
                fontSize: 11,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The tapped day's sessions — time · duration · distance per row. Flex-laid
/// (no fixed widths) so long values can't overflow a narrow phone.
class _DayDetail extends StatelessWidget {
  const _DayDetail({required this.day});

  final DayStep day;

  @override
  Widget build(BuildContext context) {
    final sessions = day.sessions;
    final isToday = day.dateLabel == 'Today';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppTheme.warmWhite,
        borderRadius: BorderRadius.circular(12),
      ),
      child: sessions.isEmpty
          ? Text(
              isToday
                  ? 'No walks recorded yet today.'
                  : 'No walks recorded that day.',
              style: const TextStyle(
                color: AppTheme.textSoft,
                fontSize: 13,
                height: 1.4,
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${sessions.length} session${sessions.length == 1 ? '' : 's'}',
                  style: const TextStyle(
                    color: AppTheme.textDark,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                const _DetailRow(
                  time: 'Time',
                  duration: 'Duration',
                  distance: 'Distance',
                  isHeader: true,
                ),
                for (final s in sessions) ...[
                  Divider(height: 13, color: AppTheme.border.withOpacity(0.5)),
                  _DetailRow(
                    time: s.startTimeOfDay,
                    duration: '${s.durationMinutes} min',
                    distance: '${NumberFormat('#,##0').format(s.distanceFt)} ft',
                  ),
                ],
              ],
            ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.time,
    required this.duration,
    required this.distance,
    this.isHeader = false,
  });

  final String time;
  final String duration;
  final String distance;
  final bool isHeader;

  @override
  Widget build(BuildContext context) {
    final style = isHeader
        ? const TextStyle(
            color: AppTheme.textSoft,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.3,
          )
        : const TextStyle(
            color: AppTheme.textDark,
            fontSize: 13.5,
          );
    return Row(
      children: [
        Expanded(flex: 4, child: Text(time, style: style)),
        Expanded(
          flex: 3,
          child: Text(duration, textAlign: TextAlign.right, style: style),
        ),
        Expanded(
          flex: 3,
          child: Text(distance, textAlign: TextAlign.right, style: style),
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

class _RecentWalksSection extends StatefulWidget {
  const _RecentWalksSection({
    required this.walks,
    required this.isWalkerUser,
    required this.view,
  });

  final List<WalkSession> walks;
  final bool isWalkerUser;
  final DeviceTypeView view;

  @override
  State<_RecentWalksSection> createState() => _RecentWalksSectionState();
}

class _RecentWalksSectionState extends State<_RecentWalksSection> {
  // Collapse long days to a preview; the rest reveal on tap (an active day can
  // log many short sessions, and burying them behind a hard cap hid them).
  static const _previewCount = 4;
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final walks = widget.walks;
    final canExpand = walks.length > _previewCount;
    final shown = (_expanded || !canExpand)
        ? walks
        : walks.take(_previewCount).toList();
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
            _WalkRow(walk: shown[i], view: widget.view),
            if (i < shown.length - 1)
              Divider(
                height: 1,
                color: AppTheme.border.withOpacity(0.5),
              ),
          ],
          if (canExpand)
            _ShowAllToggle(
              expanded: _expanded,
              totalCount: walks.length,
              onTap: () => setState(() => _expanded = !_expanded),
            ),
        ],
      ),
    );
  }
}

/// The "Show all N / Show less" control under a collapsed [_RecentWalksSection].
/// Full-width, ≥44px tap target (elderly users), sage to read as actionable.
class _ShowAllToggle extends StatelessWidget {
  const _ShowAllToggle({
    required this.expanded,
    required this.totalCount,
    required this.onTap,
  });

  final bool expanded;
  final int totalCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: double.infinity,
        constraints: const BoxConstraints(minHeight: 44),
        alignment: Alignment.center,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              expanded ? 'Show less' : 'Show all $totalCount',
              style: const TextStyle(
                color: AppTheme.sage,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 2),
            Icon(
              expanded
                  ? Icons.keyboard_arrow_up_rounded
                  : Icons.keyboard_arrow_down_rounded,
              color: AppTheme.sage,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }
}

class _WalkRow extends StatelessWidget {
  const _WalkRow({required this.walk, required this.view});
  final WalkSession walk;
  final DeviceTypeView view;

  @override
  Widget build(BuildContext context) {
    final rollator = view.deviceType == 'rollator_platform';
    // A walker's per-walk headline is steps; a rollator has none, so it leads
    // with distance ("—" when the odometer had no valid estimate) and shows
    // gait beside the duration when the firmware reported it.
    final String trailingValue;
    final String trailingUnit;
    final String subLine;
    if (rollator) {
      trailingValue = walk.distanceFt == 0
          ? '—'
          : NumberFormat('#,##0').format(walk.distanceFt);
      trailingUnit = 'ft';
      subLine = walk.gaitSpeedFts == null
          ? '${walk.durationMinutes} min'
          : '${walk.durationMinutes} min · ${walk.gaitSpeedFts!.toStringAsFixed(1)} ft/s';
    } else {
      trailingValue = NumberFormat('#,##0').format(walk.steps);
      trailingUnit = 'steps';
      subLine = '${walk.durationMinutes} min · ${walk.distanceFt} ft';
    }
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
                  subLine,
                  style: const TextStyle(
                    color: AppTheme.textSoft,
                    fontSize: 12.5,
                  ),
                ),
              ],
            ),
          ),
          Text(
            trailingValue,
            style: const TextStyle(
              color: AppTheme.textDark,
              fontSize: 16,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            trailingUnit,
            style: const TextStyle(
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
  const _AlertCard({required this.alert, this.onAck});
  final WalkerAlert alert;

  /// Wired in the live build (repository ack + refresh); null in the
  /// preview, where the button remains visual-only.
  final VoidCallback? onAck;

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
                      onPressed: onAck ?? () {},
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
          // Wrap (not Row + Spacer): on a ~390px phone the three status
          // fragments + timestamp overflow a single line — the Spacer collapses
          // to zero (running "signal" into "Last") and the timestamp clips off
          // the right edge. Wrap flows the timestamp onto a second line instead.
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 4,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
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
                ],
              ),
              Text(
                'Last checked ${device.lastSeenMinAgo} min ago',
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

