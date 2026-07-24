import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../theme/app_theme.dart';
import '../../widgets/maybe_visible.dart';
import '../data/facility_mock_data.dart';
import '../models/notification.dart';
import '../models/patient.dart';

/// One row's worth of data for the list view. Built by the census view
/// from FacilityMockData.rowStatsFor() + the engine's active notifications.
class PatientListRow {
  final Patient patient;
  final String unitDisplay;
  final PatientRowStats stats;
  final List<PatientNotification> activeNotifications;

  /// Whether stats are still loading. When true, the trend / avg /
  /// today cells render a skeleton placeholder instead of zeros.
  /// Per phase-2b-fac-r L5.
  final bool isLoading;

  /// Fired once when this row first scrolls into view. Wired by
  /// `PatientCensusView` to enqueue the row's `rowStatsFor +
  /// notificationsForPatient` fetch through its `RowLoaderQueue`
  /// (capped at 5 concurrent per L5). Null in demo mode where rows
  /// load eagerly from seed.
  final VoidCallback? onFirstVisible;

  const PatientListRow({
    required this.patient,
    required this.unitDisplay,
    required this.stats,
    required this.activeNotifications,
    this.isLoading = false,
    this.onFirstVisible,
  });

  NotificationSeverity? get highestSeverity {
    if (activeNotifications.isEmpty) return null;
    if (activeNotifications
        .any((n) => n.severity == NotificationSeverity.critical)) {
      return NotificationSeverity.critical;
    }
    return NotificationSeverity.warning;
  }
}

/// Table-style alternative to the patient tile grid. Rows are clickable
/// (opens the same patient detail overlay as the tiles).
///
/// Responsive: when the available viewport width exceeds the table's
/// natural minimum, the Resident + Location columns flex to absorb the
/// extra space. When the viewport is narrower than the minimum, the
/// table is wrapped in a horizontal scroller so phone-sized viewports
/// still work.
///
/// [showSteps] / [colorMetrics] parameterize the table for the internal
/// Pilot residents view (user-analytics.md §pilot view): rollator devices
/// report no steps, so `showSteps: false` drops the Steps + Step-trend
/// columns; and while low/high active-minute bands are still being learned,
/// `colorMetrics: false` renders the active-minutes cells in plain black
/// instead of the reference-band tiers. Both default to the Census behaviour.
class PatientListView extends StatelessWidget {
  const PatientListView({
    super.key,
    required this.rows,
    required this.selectedPatientId,
    required this.onSelect,
    this.showSteps = true,
    this.colorMetrics = true,
  });

  final List<PatientListRow> rows;
  final String? selectedPatientId;
  final ValueChanged<String> onSelect;
  final bool showSteps;
  final bool colorMetrics;

  @override
  Widget build(BuildContext context) {
    final columns = _buildColumns(showSteps: showSteps);
    final tableMinWidth = columns.fold<double>(0, (s, c) => s + c.width);

    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth;
        final shouldScroll = available < tableMinWidth;

        final table = Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(AppTheme.cardRadius),
            border: Border.all(color: AppTheme.border.withOpacity(0.5)),
            boxShadow: AppTheme.cardShadow,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _HeaderRow(columns: columns, useFlex: !shouldScroll),
              for (var i = 0; i < rows.length; i++)
                MaybeVisible(
                  detectorKey:
                      ValueKey('row-visibility-${rows[i].patient.id}'),
                  onFirstVisible: rows[i].onFirstVisible,
                  child: _DataRow(
                    row: rows[i],
                    columns: columns,
                    useFlex: !shouldScroll,
                    colorMetrics: colorMetrics,
                    selected: rows[i].patient.id == selectedPatientId,
                    isLast: i == rows.length - 1,
                    onTap: () => onSelect(rows[i].patient.id),
                  ),
                ),
            ],
          ),
        );

        if (shouldScroll) {
          // Narrow viewport: lock the table at its natural min width and
          // let the user swipe horizontally.
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(width: tableMinWidth, child: table),
          );
        }
        // Wide viewport: table grows to fill the available width via
        // Expanded children on the flex columns inside each Row.
        return table;
      },
    );
  }
}

// Column set — identified by `id` so the data + header rows stay aligned
// when optional columns (Steps / Step trend) are dropped. `flex` columns
// absorb extra horizontal space when the viewport is wider than the minimum
// (kept 0 for numeric columns so they don't stretch into oceans of whitespace).
List<_ColumnSpec> _buildColumns({required bool showSteps}) => [
      const _ColumnSpec(
        'name',
        'Name',
        170,
        _CellAlign.start,
        tooltip: 'Name and notification severity.',
        flex: 3,
      ),
      const _ColumnSpec(
        'location',
        'Location',
        195,
        _CellAlign.start,
        tooltip: 'Unit assignment and room number.',
        flex: 3,
      ),
      const _ColumnSpec(
        'notifications',
        'Notifications',
        100,
        _CellAlign.center,
        tooltip: 'Unreviewed notifications awaiting caregiver review.',
      ),
      const _ColumnSpec(
        'am_today',
        'Active minutes today',
        115,
        _CellAlign.end,
        tooltip: 'Minutes actively moving today, per the cap\'s '
            'IMU + step-detection algorithm.',
      ),
      const _ColumnSpec(
        'am_7d',
        'Active minutes 7d avg',
        120,
        _CellAlign.end,
        tooltip: 'Mean daily active minutes over the last 7 days.',
      ),
      const _ColumnSpec(
        'am_trend',
        'Active minutes trend',
        90,
        _CellAlign.center,
        tooltip:
            'Last 7 days vs the prior 7 days. Arrow appears when the change '
            'exceeds ±5%.',
      ),
      if (showSteps) ...[
        const _ColumnSpec(
          'steps_today',
          'Steps today',
          90,
          _CellAlign.end,
          tooltip: 'Total steps detected today.',
        ),
        const _ColumnSpec(
          'step_trend',
          'Step trend',
          80,
          _CellAlign.center,
          tooltip:
              'Last 7 days vs the prior 7 days. Arrow appears when the change '
              'exceeds ±5%.',
        ),
      ],
      const _ColumnSpec(
        'gait',
        'Gait Speed (ft/sec)',
        105,
        _CellAlign.end,
        tooltip:
            'Walking speed over the last 3 days, averaged. Values shown in '
            'feet per second.',
      ),
      const _ColumnSpec(
        'gait_trend',
        'Gait trend',
        80,
        _CellAlign.center,
        tooltip: '3-day average vs the prior 30-day baseline. Arrow appears '
            'when the change exceeds ±3%.',
      ),
    ];

enum _CellAlign { start, center, end }

class _ColumnSpec {
  final String id;
  final String label;
  final double width;
  final _CellAlign align;
  final String tooltip;
  final int flex;
  const _ColumnSpec(
    this.id,
    this.label,
    this.width,
    this.align, {
    this.tooltip = '',
    this.flex = 0,
  });
}

class _HeaderRow extends StatelessWidget {
  const _HeaderRow({required this.columns, required this.useFlex});
  final List<_ColumnSpec> columns;
  final bool useFlex;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.cream.withOpacity(0.5),
        border: Border(
          bottom: BorderSide(color: AppTheme.border.withOpacity(0.7)),
        ),
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(AppTheme.cardRadius),
          topRight: Radius.circular(AppTheme.cardRadius),
        ),
      ),
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          for (final col in columns)
            _slot(
              col: col,
              useFlex: useFlex,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Tooltip(
                  message: col.tooltip,
                  waitDuration: const Duration(milliseconds: 350),
                  child: Text(
                    col.label,
                    textAlign: _toTextAlign(col.align),
                    style: const TextStyle(
                      color: AppTheme.textSoft,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Picks the right wrapper for a column cell:
/// `Expanded` when the column has flex > 0 and we're in wide mode,
/// otherwise `SizedBox` at the column's fixed base width.
Widget _slot({
  required _ColumnSpec col,
  required bool useFlex,
  required Widget child,
}) {
  if (useFlex && col.flex > 0) {
    return Expanded(flex: col.flex, child: child);
  }
  return SizedBox(width: col.width, child: child);
}

class _DataRow extends StatefulWidget {
  const _DataRow({
    required this.row,
    required this.columns,
    required this.useFlex,
    required this.colorMetrics,
    required this.selected,
    required this.isLast,
    required this.onTap,
  });

  final PatientListRow row;
  final List<_ColumnSpec> columns;
  final bool useFlex;
  final bool colorMetrics;
  final bool selected;
  final bool isLast;
  final VoidCallback onTap;

  @override
  State<_DataRow> createState() => _DataRowState();
}

class _DataRowState extends State<_DataRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final r = widget.row;

    Color rowBg;
    if (widget.selected) {
      rowBg = AppTheme.sage.withOpacity(0.07);
    } else if (_hover) {
      rowBg = AppTheme.cream.withOpacity(0.6);
    } else {
      rowBg = Colors.white;
    }

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          decoration: BoxDecoration(
            color: rowBg,
            border: widget.isLast
                ? null
                : Border(
                    bottom:
                        BorderSide(color: AppTheme.border.withOpacity(0.45)),
                  ),
          ),
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              for (final col in widget.columns)
                _slot(
                  col: col,
                  useFlex: widget.useFlex,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Align(
                      alignment: _toAlignment(col.align),
                      child: _content(col.id, r),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Renders one cell's content by column id. Keeping the mapping here (not
  /// positional) is what lets optional columns drop without misaligning.
  Widget _content(String id, PatientListRow r) {
    final stats = r.stats;
    switch (id) {
      case 'name':
        return _ResidentCell(
          name: r.patient.displayName,
          severity: r.highestSeverity,
          paused: r.patient.notificationsPaused?.isActive ?? false,
        );
      case 'location':
        // D2C/internal residents have no room — show just the location label
        // (the cap serial) without a dangling "· Rm".
        final unitOnly = r.unitDisplay.replaceAll('Assisted Living — ', 'AL ');
        return Text(
          r.patient.room.isEmpty ? unitOnly : '$unitOnly  ·  Rm ${r.patient.room}',
          style: const TextStyle(color: AppTheme.textSoft, fontSize: 13),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        );
      case 'notifications':
        return r.isLoading
            ? const _SkeletonBar(width: 70)
            : _NeedsReviewCell(
                count: r.activeNotifications.length,
                severity: r.highestSeverity,
                headlineLabel: _headlineLabel(r.activeNotifications),
              );
      case 'am_today':
        return r.isLoading
            ? const _SkeletonBar(width: 28)
            : _MetricText(
                value: stats.activeMinutesToday.toString(),
                color: widget.colorMetrics
                    ? _activeMinColor(stats.activeMinutesToday)
                    : AppTheme.textDark,
              );
      case 'am_7d':
        final activeMin7d = stats.activeMinutes7dAvg.round();
        return r.isLoading
            ? const _SkeletonBar(width: 28)
            : _MetricText(
                value: activeMin7d.toString(),
                color: widget.colorMetrics
                    ? _activeMinColor(activeMin7d)
                    : AppTheme.textDark,
              );
      case 'am_trend':
        return r.isLoading
            ? const _SkeletonBar(width: 36)
            : _TrendCell(
                trend: stats.activeMinutesTrend7d,
                recent: stats.activeMinutes7dAvg,
                prior: stats.activeMinutesPrior7dAvg,
              );
      case 'steps_today':
        return r.isLoading
            ? const _SkeletonBar(width: 40)
            : _MetricText(
                value: NumberFormat('#,##0').format(stats.stepsToday),
                color: widget.colorMetrics
                    ? _stepsColor(stats.stepsToday)
                    : AppTheme.textDark,
              );
      case 'step_trend':
        return r.isLoading
            ? const _SkeletonBar(width: 36)
            : _TrendCell(
                trend: stats.stepsTrend7d,
                recent: stats.stepsRecentAvg,
                prior: stats.stepsPriorAvg,
              );
      case 'gait':
        final gaitFps = stats.gaitSpeed3dAvg; // already ft/s (0.16.0-gait+)
        return r.isLoading
            ? const _SkeletonBar(width: 28)
            : _MetricText(
                value: stats.gaitSpeed3dAvg > 0 ? gaitFps.toStringAsFixed(2) : '—',
                color: stats.gaitSpeed3dAvg > 0
                    ? AppTheme.textDark
                    : AppTheme.textSoft,
              );
      case 'gait_trend':
        return r.isLoading
            ? const _SkeletonBar(width: 36)
            : _TrendCell(
                trend: stats.gaitSpeedTrend,
                recent: stats.gaitSpeed3dAvg,
                prior: stats.gaitSpeedPriorAvg,
              );
      default:
        return const SizedBox.shrink();
    }
  }
}

// ── Color tiers ────────────────────────────────────────────────────────
//
// Senior-population reference bands. The lower tiers (rust, amber) are
// pegged off "this person should probably move more"; the upper tier
// (sage) gives a visible win for those who are very active. The
// middle band stays neutral so the eye scans for outliers.

Color _activeMinColor(int min) {
  if (min < 10) return AppTheme.statusAlert; // very low
  if (min < 20) return AppTheme.statusWarn; // low
  if (min >= 40) return AppTheme.statusOk; // high
  return AppTheme.textDark; // typical
}

Color _stepsColor(int steps) {
  if (steps < 100) return AppTheme.statusAlert;
  if (steps < 250) return AppTheme.statusWarn;
  if (steps >= 600) return AppTheme.statusOk;
  return AppTheme.textDark;
}

/// Picks the rule-name label for the most-prominent notification —
/// prefers a critical-severity entry, falling back to the first entry.
/// Per phase-2b-fac-r L6, the Census badge shows the rule name (not
/// just a count); if multiple alerts are open, this picks the highest-
/// severity headline and the cell appends "· N".
String? _headlineLabel(List<PatientNotification> notifications) {
  if (notifications.isEmpty) return null;
  for (final n in notifications) {
    if (n.severity == NotificationSeverity.critical) return n.type.label;
  }
  return notifications.first.type.label;
}

// ── Cell widgets ───────────────────────────────────────────────────────

class _ResidentCell extends StatelessWidget {
  const _ResidentCell({
    required this.name,
    this.severity,
    this.paused = false,
  });
  final String name;
  final NotificationSeverity? severity;
  final bool paused;

  @override
  Widget build(BuildContext context) {
    final dotColor = switch (severity) {
      NotificationSeverity.critical => AppTheme.statusAlert,
      NotificationSeverity.warning => AppTheme.statusWarn,
      _ => null,
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (dotColor != null) ...[
          Container(
            width: 8,
            height: 8,
            decoration:
                BoxDecoration(color: dotColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
        ],
        Flexible(
          child: Text(
            name,
            style: const TextStyle(
              color: AppTheme.textDark,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (paused) ...[
          const SizedBox(width: 6),
          Tooltip(
            message: 'Notifications paused',
            child: Icon(
              Icons.notifications_paused_outlined,
              size: 16,
              color: AppTheme.textSoft,
            ),
          ),
        ],
      ],
    );
  }
}

class _NeedsReviewCell extends StatelessWidget {
  const _NeedsReviewCell({
    required this.count,
    this.severity,
    this.headlineLabel,
  });
  final int count;
  final NotificationSeverity? severity;

  /// Most-prominent unacked notification's display label
  /// (e.g. "Battery critical"). Per phase-2b-fac-r L6, the badge text
  /// is the rule name, not just a count. Null falls back to count-only
  /// rendering for backwards compatibility (e.g. legacy demo tiles
  /// without a label resolver).
  final String? headlineLabel;

  @override
  Widget build(BuildContext context) {
    if (count == 0) {
      return const Text(
        '—',
        style: TextStyle(
          color: AppTheme.textSoft,
          fontSize: 14,
          fontWeight: FontWeight.w500,
        ),
      );
    }
    final color = severity == NotificationSeverity.critical
        ? AppTheme.statusAlert
        : AppTheme.statusWarn;
    final label = headlineLabel == null
        ? count.toString()
        : (count > 1 ? '${headlineLabel!} · $count' : headlineLabel!);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(100),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: color,
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _MetricText extends StatelessWidget {
  const _MetricText({required this.value, this.color = AppTheme.textDark});
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Text(
      value,
      style: TextStyle(
        color: color,
        fontSize: 14,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

class _TrendCell extends StatelessWidget {
  const _TrendCell({
    required this.trend,
    required this.recent,
    required this.prior,
  });

  final Trend trend;
  final double recent;
  final double prior;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (trend) {
      Trend.up => (Icons.trending_up_rounded, AppTheme.statusOk),
      Trend.down => (Icons.trending_down_rounded, AppTheme.statusAlert),
      Trend.flat => (Icons.trending_flat_rounded, AppTheme.textSoft),
    };

    final pct = Trend.percentDelta(recent, prior);
    final tooltipMsg = pct == 0
        ? 'no data'
        : '${pct > 0 ? "+" : ""}${pct.toStringAsFixed(0)}% vs prior period';

    return Tooltip(
      message: tooltipMsg,
      child: Icon(icon, size: 22, color: color),
    );
  }
}

TextAlign _toTextAlign(_CellAlign a) {
  switch (a) {
    case _CellAlign.start:
      return TextAlign.left;
    case _CellAlign.center:
      return TextAlign.center;
    case _CellAlign.end:
      return TextAlign.right;
  }
}

Alignment _toAlignment(_CellAlign a) {
  switch (a) {
    case _CellAlign.start:
      return Alignment.centerLeft;
    case _CellAlign.center:
      return Alignment.center;
    case _CellAlign.end:
      return Alignment.centerRight;
  }
}

/// Sage-tinted skeleton placeholder rendered in each metric cell
/// while a row's `rowStatsFor + notificationsForPatient` fetch is
/// pending (per phase-2b-fac-r L5). A static bar — not animated —
/// keeps the Census quiet during cold-load instead of pulsing.
class _SkeletonBar extends StatelessWidget {
  const _SkeletonBar({this.width = 32});
  final double width;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: 10,
      decoration: BoxDecoration(
        color: AppTheme.sage.withOpacity(0.18),
        borderRadius: BorderRadius.circular(4),
      ),
    );
  }
}
