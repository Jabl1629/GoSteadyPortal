import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../theme/app_theme.dart';
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

  const PatientListRow({
    required this.patient,
    required this.unitDisplay,
    required this.stats,
    required this.activeNotifications,
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
class PatientListView extends StatelessWidget {
  const PatientListView({
    super.key,
    required this.rows,
    required this.selectedPatientId,
    required this.onSelect,
  });

  final List<PatientListRow> rows;
  final String? selectedPatientId;
  final ValueChanged<String> onSelect;

  /// 1 m/s = 3.28084 ft/s. Used for the list-view Gait Speed cell.
  static const double mpsToFps = 3.28084;

  // Fixed column widths — sum is the table's natural minimum width.
  // `flex` columns absorb extra horizontal space when the viewport is
  // wider than the minimum (kept 0 for numeric columns so they don't
  // stretch into oceans of whitespace).
  static const List<_ColumnSpec> _columns = [
    _ColumnSpec(
      'Resident',
      170,
      _CellAlign.start,
      tooltip: 'Resident name and notification severity.',
      flex: 3,
    ),
    _ColumnSpec(
      'Location',
      195,
      _CellAlign.start,
      tooltip: 'Unit assignment and room number.',
      flex: 3,
    ),
    _ColumnSpec(
      'Notifications',
      100,
      _CellAlign.center,
      tooltip: 'Unreviewed notifications awaiting caregiver review.',
    ),
    _ColumnSpec(
      'Active minutes today',
      115,
      _CellAlign.end,
      tooltip:
          'Minutes the resident was actively moving today, per the cap\'s '
          'IMU + step-detection algorithm.',
    ),
    _ColumnSpec(
      'Active minutes 7d avg',
      120,
      _CellAlign.end,
      tooltip: 'Mean daily active minutes over the last 7 days.',
    ),
    _ColumnSpec(
      'Active minutes trend',
      90,
      _CellAlign.center,
      tooltip:
          'Last 7 days vs the prior 7 days. Arrow appears when the change '
          'exceeds ±5%.',
    ),
    _ColumnSpec(
      'Steps today',
      90,
      _CellAlign.end,
      tooltip: 'Total steps detected today.',
    ),
    _ColumnSpec(
      'Step trend',
      80,
      _CellAlign.center,
      tooltip:
          'Last 7 days vs the prior 7 days. Arrow appears when the change '
          'exceeds ±5%.',
    ),
    _ColumnSpec(
      'Gait Speed (ft/sec)',
      105,
      _CellAlign.end,
      tooltip:
          'Walking speed over the last 3 days, averaged. Values shown in '
          'feet per second.',
    ),
    _ColumnSpec(
      'Gait trend',
      80,
      _CellAlign.center,
      tooltip:
          '3-day average vs the prior 30-day baseline. Arrow appears when '
          'the change exceeds ±3%.',
    ),
  ];

  static double get _tableMinWidth =>
      _columns.fold<double>(0, (s, c) => s + c.width);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth;
        final shouldScroll = available < _tableMinWidth;

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
              _HeaderRow(columns: _columns, useFlex: !shouldScroll),
              for (var i = 0; i < rows.length; i++)
                _DataRow(
                  row: rows[i],
                  columns: _columns,
                  useFlex: !shouldScroll,
                  selected: rows[i].patient.id == selectedPatientId,
                  isLast: i == rows.length - 1,
                  onTap: () => onSelect(rows[i].patient.id),
                ),
            ],
          ),
        );

        if (shouldScroll) {
          // Narrow viewport: lock the table at its natural min width and
          // let the user swipe horizontally.
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(width: _tableMinWidth, child: table),
          );
        }
        // Wide viewport: table grows to fill the available width via
        // Expanded children on the flex columns inside each Row.
        return table;
      },
    );
  }
}

enum _CellAlign { start, center, end }

class _ColumnSpec {
  final String label;
  final double width;
  final _CellAlign align;
  final String tooltip;
  final int flex;
  const _ColumnSpec(
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
          for (var i = 0; i < columns.length; i++)
            _slot(
              col: columns[i],
              useFlex: useFlex,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Tooltip(
                  message: columns[i].tooltip,
                  waitDuration: const Duration(milliseconds: 350),
                  child: Text(
                    columns[i].label,
                    textAlign: _toTextAlign(columns[i].align),
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
    required this.selected,
    required this.isLast,
    required this.onTap,
  });

  final PatientListRow row;
  final List<_ColumnSpec> columns;
  final bool useFlex;
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
    final stats = r.stats;
    final unitOnly = r.unitDisplay.replaceAll('Assisted Living — ', 'AL ');

    final activeMin7d = stats.activeMinutes7dAvg.round();
    final gaitFps = stats.gaitSpeed3dAvg * PatientListView.mpsToFps;

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
              _cell(
                index: 0,
                child: _ResidentCell(
                  name: r.patient.displayName,
                  severity: r.highestSeverity,
                ),
              ),
              _cell(
                index: 1,
                child: Text(
                  '$unitOnly  ·  Rm ${r.patient.room}',
                  style: const TextStyle(
                    color: AppTheme.textSoft,
                    fontSize: 13,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              _cell(
                index: 2,
                child: _NeedsReviewCell(
                  count: r.activeNotifications.length,
                  severity: r.highestSeverity,
                ),
              ),
              _cell(
                index: 3,
                child: _MetricText(
                  value: stats.activeMinutesToday.toString(),
                  color: _activeMinColor(stats.activeMinutesToday),
                ),
              ),
              _cell(
                index: 4,
                child: _MetricText(
                  value: activeMin7d.toString(),
                  color: _activeMinColor(activeMin7d),
                ),
              ),
              _cell(
                index: 5,
                child: _TrendCell(
                  trend: stats.activeMinutesTrend7d,
                  recent: stats.activeMinutes7dAvg,
                  prior: stats.activeMinutesPrior7dAvg,
                ),
              ),
              _cell(
                index: 6,
                child: _MetricText(
                  value: NumberFormat('#,##0').format(stats.stepsToday),
                  color: _stepsColor(stats.stepsToday),
                ),
              ),
              _cell(
                index: 7,
                child: _TrendCell(
                  trend: stats.stepsTrend7d,
                  recent: stats.stepsRecentAvg,
                  prior: stats.stepsPriorAvg,
                ),
              ),
              _cell(
                index: 8,
                child: _MetricText(
                  value: stats.gaitSpeed3dAvg > 0
                      ? gaitFps.toStringAsFixed(2)
                      : '—',
                  color: stats.gaitSpeed3dAvg > 0
                      ? AppTheme.textDark
                      : AppTheme.textSoft,
                ),
              ),
              _cell(
                index: 9,
                child: _TrendCell(
                  trend: stats.gaitSpeedTrend,
                  recent: stats.gaitSpeed3dAvg,
                  prior: stats.gaitSpeedPriorAvg,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _cell({required int index, required Widget child}) {
    final col = widget.columns[index];
    return _slot(
      col: col,
      useFlex: widget.useFlex,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Align(alignment: _toAlignment(col.align), child: child),
      ),
    );
  }
}

// ── Color tiers ────────────────────────────────────────────────────────
//
// Senior-population reference bands. The lower tiers (rust, amber) are
// pegged off "this resident should probably move more"; the upper tier
// (sage) gives a visible win for residents who are very active. The
// middle band stays neutral so the eye scans for outliers.

Color _activeMinColor(int min) {
  if (min < 10) return AppTheme.statusAlert; // very low
  if (min < 20) return AppTheme.statusWarn;  // low
  if (min >= 40) return AppTheme.statusOk;   // high
  return AppTheme.textDark;                  // typical
}

Color _stepsColor(int steps) {
  if (steps < 100) return AppTheme.statusAlert;
  if (steps < 250) return AppTheme.statusWarn;
  if (steps >= 600) return AppTheme.statusOk;
  return AppTheme.textDark;
}

// ── Cell widgets ───────────────────────────────────────────────────────

class _ResidentCell extends StatelessWidget {
  const _ResidentCell({required this.name, this.severity});
  final String name;
  final NotificationSeverity? severity;

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
      ],
    );
  }
}

class _NeedsReviewCell extends StatelessWidget {
  const _NeedsReviewCell({required this.count, this.severity});
  final int count;
  final NotificationSeverity? severity;

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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(100),
      ),
      child: Text(
        count.toString(),
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
