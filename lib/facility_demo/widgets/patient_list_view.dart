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
/// (opens the same patient detail overlay as the tiles). Wraps in a
/// horizontal scroller below the table's natural width so it works on
/// phone-sized viewports too.
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

  // Fixed column widths — sum is the table's natural minimum width.
  static const List<_ColumnSpec> _columns = [
    _ColumnSpec('Resident', 180, _CellAlign.start),
    _ColumnSpec('Location', 195, _CellAlign.start),
    _ColumnSpec('Needs review', 100, _CellAlign.center),
    _ColumnSpec('Active minutes today', 120, _CellAlign.end),
    _ColumnSpec('Active minutes 7d avg', 125, _CellAlign.end),
    _ColumnSpec('Active minutes 30d avg', 130, _CellAlign.end),
    _ColumnSpec('Steps today', 90, _CellAlign.end),
    _ColumnSpec('Step trend', 80, _CellAlign.center),
    _ColumnSpec('Gait (3d)', 85, _CellAlign.end),
    _ColumnSpec('Gait trend', 80, _CellAlign.center),
  ];

  static double get _tableWidth =>
      _columns.fold<double>(0, (s, c) => s + c.width);

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Container(
        constraints: BoxConstraints(minWidth: _tableWidth),
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
            _HeaderRow(columns: _columns),
            for (var i = 0; i < rows.length; i++)
              _DataRow(
                row: rows[i],
                columns: _columns,
                selected: rows[i].patient.id == selectedPatientId,
                isLast: i == rows.length - 1,
                onTap: () => onSelect(rows[i].patient.id),
              ),
          ],
        ),
      ),
    );
  }
}

enum _CellAlign { start, center, end }

class _ColumnSpec {
  final String label;
  final double width;
  final _CellAlign align;
  const _ColumnSpec(this.label, this.width, this.align);
}

class _HeaderRow extends StatelessWidget {
  const _HeaderRow({required this.columns});
  final List<_ColumnSpec> columns;

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
          for (final c in columns)
            SizedBox(
              width: c.width,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  c.label,
                  textAlign: _toTextAlign(c.align),
                  style: const TextStyle(
                    color: AppTheme.textSoft,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _DataRow extends StatefulWidget {
  const _DataRow({
    required this.row,
    required this.columns,
    required this.selected,
    required this.isLast,
    required this.onTap,
  });

  final PatientListRow row;
  final List<_ColumnSpec> columns;
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
                widget.columns[0],
                child: _ResidentCell(
                  name: r.patient.displayName,
                  severity: r.highestSeverity,
                ),
              ),
              _cell(
                widget.columns[1],
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
                widget.columns[2],
                child: _NeedsReviewCell(
                  count: r.activeNotifications.length,
                  severity: r.highestSeverity,
                ),
              ),
              _cell(
                widget.columns[3],
                child: _MetricText(value: stats.activeMinutesToday.toString()),
              ),
              _cell(
                widget.columns[4],
                child: _MetricText(
                  value: stats.activeMinutes7dAvg.round().toString(),
                  muted: true,
                ),
              ),
              _cell(
                widget.columns[5],
                child: _MetricText(
                  value: stats.activeMinutes30dAvg.round().toString(),
                  muted: true,
                ),
              ),
              _cell(
                widget.columns[6],
                child: _MetricText(
                  value: NumberFormat('#,##0').format(stats.stepsToday),
                ),
              ),
              _cell(
                widget.columns[7],
                child: _TrendCell(
                  trend: stats.stepsTrend7d,
                  recent: stats.stepsRecentAvg,
                  prior: stats.stepsPriorAvg,
                  unitSingular: 'step',
                ),
              ),
              _cell(
                widget.columns[8],
                child: _MetricText(
                  value: stats.gaitSpeed3dAvg > 0
                      ? stats.gaitSpeed3dAvg.toStringAsFixed(2)
                      : '—',
                  muted: stats.gaitSpeed3dAvg <= 0,
                ),
              ),
              _cell(
                widget.columns[9],
                child: _TrendCell(
                  trend: stats.gaitSpeedTrend,
                  recent: stats.gaitSpeed3dAvg,
                  prior: stats.gaitSpeedPriorAvg,
                  unitSingular: 'm/s',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _cell(_ColumnSpec c, {required Widget child}) {
    return SizedBox(
      width: c.width,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Align(alignment: _toAlignment(c.align), child: child),
      ),
    );
  }
}

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
  const _MetricText({required this.value, this.muted = false});
  final String value;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    return Text(
      value,
      style: TextStyle(
        color: muted ? AppTheme.textSoft : AppTheme.textDark,
        fontSize: 14,
        fontWeight: FontWeight.w500,
      ),
    );
  }
}

class _TrendCell extends StatelessWidget {
  const _TrendCell({
    required this.trend,
    required this.recent,
    required this.prior,
    required this.unitSingular,
  });

  final Trend trend;
  final double recent;
  final double prior;
  final String unitSingular;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (trend) {
      Trend.up =>
        (Icons.trending_up_rounded, AppTheme.statusOk),
      Trend.down =>
        (Icons.trending_down_rounded, AppTheme.statusAlert),
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
