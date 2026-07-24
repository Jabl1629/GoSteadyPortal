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
                // Active minutes + distance under one shared Today/7-day/
                // 30-day zoom. The Today level supersedes the old standalone
                // "Today's walks" tile, which is why that section is gone.
                _TrendSection(
                  days: snapshot.last30Days.isNotEmpty
                      ? snapshot.last30Days
                      : snapshot.last7Days,
                ),
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
// Trend section — one shared Today / 7-day / 30-day zoom over two charts
// ─────────────────────────────────────────────────────────────────────

/// Zoom levels, coarsest last. The three form a stack: a 30-day bar is a week,
/// a 7-day bar is a day, and a day is the deepest level (intra-day buckets).
enum _TrendZoom { day, week, month }

/// A single plotted bar, whatever the zoom.
class _TrendBar {
  const _TrendBar({
    required this.label,
    required this.value,
    this.anchorDay,
    this.anchorWeek,
    this.isCurrent = false,
    this.labelVisible = true,
  });

  final String label;
  final int value;

  /// Set at week zoom — tapping drills into this day.
  final DateTime? anchorDay;

  /// Set at month zoom — tapping drills into this week.
  final DateTime? anchorWeek;

  /// The bar covering "now" (today / this week) — rendered darker.
  final bool isCurrent;

  /// Day zoom plots 12 buckets but labels every other one, so the axis stays
  /// readable on a narrow phone.
  final bool labelVisible;
}

class _WeekBucket {
  const _WeekBucket({required this.start, required this.days});
  final DateTime start;
  final List<DayStep> days;

  /// Average per DAY, not the week total — the current week is usually partial,
  /// and a total would make it read as a collapse next to full weeks.
  int avg(int Function(DayStep) value) {
    if (days.isEmpty) return 0;
    final sum = days.fold<int>(0, (a, d) => a + value(d));
    return (sum / days.length).round();
  }
}

/// Owns the zoom + focus shared by both metric charts, so "Active minutes" and
/// "Distance traveled" always describe the same period and can be compared.
///
/// Navigation: the toggle picks a zoom (resetting focus to the current period);
/// tapping a bar drills one level in (week → day, month → week). A back chip
/// appears whenever the view is focused on something other than the current
/// period, and zooms back out to where you came from.
class _TrendSection extends StatefulWidget {
  const _TrendSection({required this.days});

  /// The 30-day window, oldest-first (last entry is today).
  final List<DayStep> days;

  @override
  State<_TrendSection> createState() => _TrendSectionState();
}

class _TrendSectionState extends State<_TrendSection> {
  _TrendZoom _zoom = _TrendZoom.week; // spec: default to 7-day
  DateTime? _focusDay;
  DateTime? _focusWeekStart;

  List<DayStep> get _days => widget.days;

  static DateTime _dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  /// Monday-anchored week start — calendar weeks read more naturally than
  /// rolling 7-day chunks once you're comparing several of them.
  static DateTime _weekStart(DateTime d) =>
      _dayOnly(d).subtract(Duration(days: d.weekday - 1));

  /// Days plotted at week zoom: the focused calendar week, or (default) the
  /// trailing 7 days ending today.
  List<DayStep> _weekWindow() {
    final start = _focusWeekStart;
    if (start == null) {
      return _days.length <= 7 ? _days : _days.sublist(_days.length - 7);
    }
    final end = start.add(const Duration(days: 7));
    return [
      for (final d in _days)
        if (d.date != null &&
            !d.date!.isBefore(start) &&
            d.date!.isBefore(end))
          d,
    ];
  }

  DayStep _focusedDay() {
    final f = _focusDay;
    if (f != null) {
      for (final d in _days) {
        if (d.date != null && _sameDay(d.date!, f)) return d;
      }
    }
    return _days.last;
  }

  List<_WeekBucket> _weekBuckets() {
    final map = <DateTime, List<DayStep>>{};
    for (final d in _days) {
      if (d.date == null) continue;
      (map[_weekStart(d.date!)] ??= []).add(d);
    }
    final keys = map.keys.toList()..sort();
    return [for (final k in keys) _WeekBucket(start: k, days: map[k]!)];
  }

  static String _hourLabel(int hour) {
    if (hour == 0) return '12a';
    if (hour == 12) return '12p';
    return hour < 12 ? '${hour}a' : '${hour - 12}p';
  }

  static String _monthDay(DateTime d) =>
      '${const [
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
      ][d.month - 1]} ${d.day}';

  /// Bars for the current zoom, valued by this card's metric.
  List<_TrendBar> _bars(
    int Function(DayStep) dayValue,
    int Function(WalkSession) sessionValue,
  ) {
    switch (_zoom) {
      case _TrendZoom.day:
        // 12 two-hour buckets. Deepest level, so bars aren't tap targets —
        // which is what lets them be this thin without hurting usability.
        final buckets = List<int>.filled(12, 0);
        for (final s in _focusedDay().sessions) {
          buckets[(s.startHour ~/ 2).clamp(0, 11)] += sessionValue(s);
        }
        return [
          for (var i = 0; i < 12; i++)
            _TrendBar(
              label: _hourLabel(i * 2),
              value: buckets[i],
              labelVisible: i.isEven,
            ),
        ];
      case _TrendZoom.week:
        return [
          for (final d in _weekWindow())
            _TrendBar(
              label: d.weekday,
              value: dayValue(d),
              anchorDay: d.date,
              isCurrent: d.dateLabel == 'Today',
            ),
        ];
      case _TrendZoom.month:
        final now = _dayOnly(DateTime.now());
        return [
          for (final b in _weekBuckets())
            _TrendBar(
              label: _monthDay(b.start),
              value: b.avg(dayValue),
              anchorWeek: b.start,
              isCurrent: !now.isBefore(b.start) &&
                  now.isBefore(b.start.add(const Duration(days: 7))),
            ),
        ];
    }
  }

  int _headerValue(int Function(DayStep) dayValue) {
    switch (_zoom) {
      case _TrendZoom.day:
        return dayValue(_focusedDay());
      case _TrendZoom.week:
        final w = _weekWindow();
        return w.fold<int>(0, (a, d) => a + dayValue(d));
      case _TrendZoom.month:
        if (_days.isEmpty) return 0;
        final sum = _days.fold<int>(0, (a, d) => a + dayValue(d));
        return (sum / _days.length).round();
    }
  }

  /// Names the period the header value covers.
  String get _periodLabel {
    switch (_zoom) {
      case _TrendZoom.day:
        final d = _focusedDay();
        return d.dateLabel.isEmpty ? d.weekday : d.dateLabel;
      case _TrendZoom.week:
        final s = _focusWeekStart;
        return s == null ? 'Last 7 days' : 'Week of ${_monthDay(s)}';
      case _TrendZoom.month:
        return 'Last 30 days';
    }
  }

  /// A 30-day bar is an average, so its unit needs saying so.
  String _unitSuffix(String unit) =>
      _zoom == _TrendZoom.month ? '$unit/day' : unit;

  bool get _isDrilled =>
      (_zoom == _TrendZoom.day && _focusDay != null) ||
      (_zoom == _TrendZoom.week && _focusWeekStart != null);

  void _selectZoom(_TrendZoom z) => setState(() {
        _zoom = z;
        // A toggle press means "show me the current period at this zoom".
        _focusDay = null;
        _focusWeekStart = null;
      });

  void _onBarTap(_TrendBar bar) {
    if (bar.anchorDay != null) {
      // week → day. `_focusWeekStart` is deliberately left alone so backing out
      // returns to whichever week view you came from (trailing 7 or calendar).
      setState(() {
        _focusDay = bar.anchorDay;
        _zoom = _TrendZoom.day;
      });
    } else if (bar.anchorWeek != null) {
      setState(() {
        _focusWeekStart = bar.anchorWeek;
        _zoom = _TrendZoom.week;
      });
    }
  }

  void _back() => setState(() {
        if (_zoom == _TrendZoom.day) {
          _focusDay = null;
          _zoom = _TrendZoom.week;
        } else {
          _focusWeekStart = null;
          _zoom = _TrendZoom.month;
        }
      });

  @override
  Widget build(BuildContext context) {
    if (_days.isEmpty) return const SizedBox.shrink();
    final showSessions = _zoom == _TrendZoom.day;
    final day = _focusedDay();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: _ZoomToggle(zoom: _zoom, onChanged: _selectZoom)),
            if (_isDrilled) ...[
              const SizedBox(width: 10),
              _BackChip(onTap: _back),
            ],
          ],
        ),
        const SizedBox(height: 14),
        _MetricTrendCard(
          title: 'Active minutes',
          unit: _unitSuffix('min'),
          periodLabel: _periodLabel,
          headerValue: _headerValue((d) => d.activeMinutes),
          bars: _bars(
            (d) => d.activeMinutes,
            (s) => s.activeMinutes > 0 ? s.activeMinutes : s.durationMinutes,
          ),
          onBarTap: _onBarTap,
          sessions: showSessions ? day.sessions : null,
          emptyIsToday: day.dateLabel == 'Today',
        ),
        const SizedBox(height: 16),
        _MetricTrendCard(
          title: 'Distance traveled',
          unit: _unitSuffix('ft'),
          periodLabel: _periodLabel,
          headerValue: _headerValue((d) => d.distanceFt),
          bars: _bars((d) => d.distanceFt, (s) => s.distanceFt),
          onBarTap: _onBarTap,
          sessions: showSessions ? day.sessions : null,
          emptyIsToday: day.dateLabel == 'Today',
        ),
      ],
    );
  }
}

/// Three-way segmented range control. Each segment is a 44px tap target.
class _ZoomToggle extends StatelessWidget {
  const _ZoomToggle({required this.zoom, required this.onChanged});

  final _TrendZoom zoom;
  final ValueChanged<_TrendZoom> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      padding: const EdgeInsets.all(3),
      child: Row(
        children: [
          _seg('Today', _TrendZoom.day),
          _seg('7 days', _TrendZoom.week),
          _seg('30 days', _TrendZoom.month),
        ],
      ),
    );
  }

  Widget _seg(String label, _TrendZoom value) {
    final selected = zoom == value;
    return Expanded(
      child: Material(
        color: selected ? AppTheme.sage : Colors.transparent,
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          borderRadius: BorderRadius.circular(9),
          onTap: selected ? null : () => onChanged(value),
          child: Container(
            height: 38,
            alignment: Alignment.center,
            child: Text(
              label,
              style: TextStyle(
                color: selected ? Colors.white : AppTheme.textDark,
                fontSize: 13.5,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Zoom-out affordance, shown only when focused on a past day/week.
class _BackChip extends StatelessWidget {
  const _BackChip({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.border),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.arrow_back_rounded, size: 16, color: AppTheme.sage),
              SizedBox(width: 5),
              Text(
                'Back',
                style: TextStyle(
                  color: AppTheme.sage,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One metric's chart: a named value for the period, the bars, and (at day
/// zoom only) that day's sessions underneath.
class _MetricTrendCard extends StatelessWidget {
  const _MetricTrendCard({
    required this.title,
    required this.unit,
    required this.periodLabel,
    required this.headerValue,
    required this.bars,
    required this.onBarTap,
    this.sessions,
    this.emptyIsToday = false,
  });

  final String title;
  final String unit;
  final String periodLabel;
  final int headerValue;
  final List<_TrendBar> bars;
  final ValueChanged<_TrendBar> onBarTap;

  /// Non-null only at day zoom — the focused day's sessions.
  final List<WalkSession>? sessions;
  final bool emptyIsToday;

  @override
  Widget build(BuildContext context) {
    final maxVal = bars.fold<int>(0, (a, b) => a > b.value ? a : b.value);
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
            title,
            style: const TextStyle(
              color: AppTheme.textDark,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                fmt.format(headerValue),
                style: const TextStyle(
                  color: AppTheme.textDark,
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  height: 1.1,
                ),
              ),
              const SizedBox(width: 5),
              Text(
                unit,
                style: const TextStyle(
                  color: AppTheme.textSoft,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  periodLabel,
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
              for (final b in bars)
                Expanded(
                  child: _TrendBarColumn(
                    bar: b,
                    maxValue: maxVal,
                    onTap: (b.anchorDay != null || b.anchorWeek != null)
                        ? () => onBarTap(b)
                        : null,
                  ),
                ),
            ],
          ),
          if (sessions != null) ...[
            const SizedBox(height: 12),
            _DayDetail(sessions: sessions!, isToday: emptyIsToday),
          ],
        ],
      ),
    );
  }
}

/// One bar + its axis label. Tappable only when it can be drilled into.
class _TrendBarColumn extends StatelessWidget {
  const _TrendBarColumn({
    required this.bar,
    required this.maxValue,
    this.onTap,
  });

  final _TrendBar bar;
  final int maxValue;
  final VoidCallback? onTap;

  static const double _maxBarHeight = 72;

  @override
  Widget build(BuildContext context) {
    final scaled =
        maxValue == 0 ? 0.0 : (bar.value / maxValue) * _maxBarHeight;
    // Floor a non-zero bucket at 4px so light activity stays visible; a true
    // zero gets a 3px stub (present, clearly empty).
    final barHeight = bar.value > 0 ? scaled.clamp(4.0, _maxBarHeight) : 3.0;
    final color =
        bar.isCurrent ? AppTheme.sage : AppTheme.sage.withOpacity(0.30);
    final column = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: _maxBarHeight,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(7),
                ),
                height: barHeight,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            bar.labelVisible ? bar.label : '',
            maxLines: 1,
            overflow: TextOverflow.clip,
            style: TextStyle(
              color: bar.isCurrent ? AppTheme.textDark : AppTheme.textSoft,
              fontSize: 11,
              fontWeight: bar.isCurrent ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ],
      ),
    );
    if (onTap == null) return column;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: column,
    );
  }
}

/// The focused day's sessions — time · duration · distance per row. Flex-laid
/// (no fixed widths) so long values can't overflow a narrow phone.
class _DayDetail extends StatelessWidget {
  const _DayDetail({required this.sessions, required this.isToday});

  final List<WalkSession> sessions;
  final bool isToday;

  @override
  Widget build(BuildContext context) {
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

