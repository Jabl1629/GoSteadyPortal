import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/activity.dart';
import '../theme/app_theme.dart';

/// Which metric the chart displays.
enum ChartMetric { steps, distance, timeInMotion, gaitSpeed }

/// A single trend chart card. Renders a bar chart for the given metric
/// across the selected time range. Instantiate once per metric.
class TrendChartCard extends StatelessWidget {
  const TrendChartCard({
    super.key,
    required this.metric,
    required this.timeRange,
    this.todayHours = const [],
    this.dailyData = const [],
    this.weeklyData = const [],
  });

  final ChartMetric metric;
  final TimeRange timeRange;
  final List<HourlyActivity> todayHours;
  final List<DailyActivity> dailyData;
  final List<WeeklyActivity> weeklyData;

  String get _title {
    switch (metric) {
      case ChartMetric.steps:
        return 'Steps';
      case ChartMetric.distance:
        return 'Distance Traveled';
      case ChartMetric.timeInMotion:
        return 'Time in Motion';
      case ChartMetric.gaitSpeed:
        return 'Gait Speed';
    }
  }

  String get _unit {
    switch (metric) {
      case ChartMetric.steps:
        return 'steps';
      case ChartMetric.distance:
        return 'ft';
      case ChartMetric.timeInMotion:
        return 'min';
      case ChartMetric.gaitSpeed:
        return 'm/s';
    }
  }

  String get _perLabel {
    final base = switch (timeRange) {
      TimeRange.day => 'hour',
      TimeRange.week || TimeRange.month => 'day',
      TimeRange.sixMonth => 'week',
    };
    return metric == ChartMetric.gaitSpeed ? 'Average per $base' : 'Per $base';
  }

  /// Whether the chart-card subtitle should be prefixed with "Per".
  /// Gait speed already says "Average per …" so the prefix is suppressed.
  bool get _perLabelHasOwnPrefix => metric == ChartMetric.gaitSpeed;

  /// Right-aligned summary chip for the gait-speed chart card. Surfaces
  /// the period's min–max range and time-averaged value so the audience
  /// gets the clinical headline at a glance — the per-bucket bars are
  /// then just "where it sat hour-by-hour."
  Widget _gaitSpeedSummary() {
    final entries = _extractData();
    final active = entries.where((e) => e.value > 0).toList();
    if (active.isEmpty) {
      return Text(
        'No walking yet',
        style: TextStyle(
          color: AppTheme.textSoft.withOpacity(0.7),
          fontSize: 12,
          fontWeight: FontWeight.w500,
          fontStyle: FontStyle.italic,
        ),
      );
    }
    double rangeMin = double.infinity;
    double rangeMax = 0;
    double avgSum = 0;
    var avgN = 0;
    for (final e in active) {
      final lo = e.minValue ?? e.value;
      final hi = e.maxValue ?? e.value;
      if (lo > 0 && lo < rangeMin) rangeMin = lo;
      if (hi > rangeMax) rangeMax = hi;
      avgSum += e.value;
      avgN++;
    }
    final avgVal = avgN == 0 ? 0.0 : avgSum / avgN;
    final loStr =
        (rangeMin == double.infinity ? avgVal : rangeMin).toStringAsFixed(2);
    final hiStr = rangeMax.toStringAsFixed(2);
    final avgStr = avgVal.toStringAsFixed(2);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _SummaryStat(label: 'Range', value: '$loStr–$hiStr', unit: 'm/s'),
        const SizedBox(width: 16),
        _SummaryStat(label: 'Avg', value: avgStr, unit: 'm/s'),
      ],
    );
  }

  Color get _barColor {
    switch (metric) {
      case ChartMetric.steps:
        return AppTheme.sage;
      case ChartMetric.distance:
        return const Color(0xFF5A8E6A);
      case ChartMetric.timeInMotion:
        return const Color(0xFF6B9E7D);
      case ChartMetric.gaitSpeed:
        return const Color(0xFF4A7C8E); // slate-teal — distinct clinical metric
    }
  }

  Color get _barColorLight {
    switch (metric) {
      case ChartMetric.steps:
        return AppTheme.sageLight;
      case ChartMetric.distance:
        return const Color(0xFF72A883);
      case ChartMetric.timeInMotion:
        return const Color(0xFF8AB898);
      case ChartMetric.gaitSpeed:
        return const Color(0xFF6FA4B5);
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final isNarrow = constraints.maxWidth < 480;
      return Container(
        padding: EdgeInsets.fromLTRB(
          isNarrow ? 18 : 28,
          isNarrow ? 18 : 24,
          isNarrow ? 18 : 28,
          isNarrow ? 18 : 28,
        ),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(AppTheme.cardRadius),
          boxShadow: AppTheme.cardShadow,
          border: Border.all(color: AppTheme.border.withOpacity(0.5), width: 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _title,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontSize: 18,
                            ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _perLabelHasOwnPrefix ? _perLabel : 'Per $_perLabel',
                        style: const TextStyle(
                          color: AppTheme.textSoft,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                if (metric == ChartMetric.gaitSpeed) _gaitSpeedSummary(),
              ],
            ),
            const SizedBox(height: 24),
            SizedBox(
              height: 220,
              child: _buildChart(),
            ),
          ],
        ),
      );
    });
  }

  Widget _buildChart() {
    // Extract (labels, values) for the selected time range.
    final entries = _extractData();
    if (entries.isEmpty) return const SizedBox.shrink();

    final isGaitSpeed = metric == ChartMetric.gaitSpeed;
    final maxVal =
        entries.map((e) => e.value).fold<double>(0, (m, v) => v > m ? v : m);
    final yMax = isGaitSpeed ? _niceMaxFractional(maxVal) : _niceMax(maxVal);
    final barWidth = _barWidth(entries.length);

    return BarChart(
      BarChartData(
        alignment: BarChartAlignment.spaceBetween,
        maxY: yMax,
        minY: 0,
        gridData: _grid(yMax),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          topTitles: _noTitles,
          rightTitles: _noTitles,
          leftTitles:
              isGaitSpeed ? _leftTitlesFractional(yMax) : _leftTitles(yMax),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 28,
              interval: 1,
              getTitlesWidget: (value, _) {
                final i = value.toInt();
                if (i < 0 || i >= entries.length)
                  return const SizedBox.shrink();
                final showEvery = _labelInterval(entries.length);
                if (i % showEvery != 0) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(entries[i].label, style: _axisStyle),
                );
              },
            ),
          ),
        ),
        barTouchData: _touchData(entries),
        barGroups: List.generate(entries.length, (i) {
          return _makeBar(i, entries[i], barWidth);
        }),
      ),
    );
  }

  List<_DataPoint> _extractData() {
    switch (timeRange) {
      case TimeRange.day:
        return _fromHourly(todayHours);
      case TimeRange.week:
        return _fromDaily(dailyData, shortLabel: true);
      case TimeRange.month:
        return _fromDaily(dailyData, shortLabel: false);
      case TimeRange.sixMonth:
        return _fromWeekly(weeklyData);
    }
  }

  List<_DataPoint> _fromHourly(List<HourlyActivity> hours) {
    // Generate all 24 hour slots.
    final byHour = <int, HourlyActivity>{
      for (final h in hours) h.hour.hour: h,
    };
    return List.generate(24, (h) {
      final a = byHour[h];
      double val = 0;
      double? minVal;
      double? maxVal;
      if (a != null) {
        switch (metric) {
          case ChartMetric.steps:
            val = a.steps.toDouble();
          case ChartMetric.distance:
            val = a.distanceFt;
          case ChartMetric.timeInMotion:
            val = a.timeInMotionMinutes.toDouble();
          case ChartMetric.gaitSpeed:
            val = a.avgGaitSpeedMs;
            minVal = a.minGaitSpeedMs;
            maxVal = a.maxGaitSpeedMs;
        }
      }
      return _DataPoint(
        label: _fmtHour(h),
        value: val,
        tooltip: _fmtHour(h),
        minValue: minVal,
        maxValue: maxVal,
      );
    });
  }

  List<_DataPoint> _fromDaily(List<DailyActivity> days,
      {required bool shortLabel}) {
    return days.map((d) {
      double val;
      double? minVal;
      double? maxVal;
      switch (metric) {
        case ChartMetric.steps:
          val = d.totalSteps.toDouble();
        case ChartMetric.distance:
          val = d.totalDistanceFt;
        case ChartMetric.timeInMotion:
          val = d.totalTimeInMotionMinutes.toDouble();
        case ChartMetric.gaitSpeed:
          val = d.avgGaitSpeedMs;
          minVal = d.minGaitSpeedMs;
          maxVal = d.maxGaitSpeedMs;
      }
      final label = shortLabel
          ? DateFormat('E').format(d.date)
          : DateFormat('M/d').format(d.date);
      final tip = DateFormat('MMM d').format(d.date);
      return _DataPoint(
        label: label,
        value: val,
        tooltip: tip,
        minValue: minVal,
        maxValue: maxVal,
      );
    }).toList();
  }

  List<_DataPoint> _fromWeekly(List<WeeklyActivity> weeks) {
    return weeks.map((w) {
      double val;
      double? minVal;
      double? maxVal;
      switch (metric) {
        case ChartMetric.steps:
          val = w.totalSteps.toDouble();
        case ChartMetric.distance:
          val = w.totalDistanceFt;
        case ChartMetric.timeInMotion:
          val = w.totalTimeInMotionMinutes.toDouble();
        case ChartMetric.gaitSpeed:
          val = w.avgGaitSpeedMs;
          minVal = w.minGaitSpeedMs;
          maxVal = w.maxGaitSpeedMs;
      }
      final label = DateFormat('MMM').format(w.weekStart);
      final tip = 'Week of ${DateFormat('MMM d').format(w.weekStart)}';
      return _DataPoint(
        label: label,
        value: val,
        tooltip: tip,
        minValue: minVal,
        maxValue: maxVal,
      );
    }).toList();
  }

  BarTouchData _touchData(List<_DataPoint> entries) {
    return BarTouchData(
      touchTooltipData: BarTouchTooltipData(
        getTooltipColor: (_) => AppTheme.textDark,
        tooltipRoundedRadius: 10,
        tooltipPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        getTooltipItem: (group, _, rod, __) {
          final i = group.x;
          if (i < 0 || i >= entries.length) return null;
          final e = entries[i];
          String text;
          if (metric == ChartMetric.gaitSpeed) {
            final avgStr = e.value.toStringAsFixed(2);
            if (e.value <= 0) {
              text = '${e.tooltip}\nno walking';
            } else if (e.minValue != null && e.maxValue != null) {
              final lo = e.minValue!.toStringAsFixed(2);
              final hi = e.maxValue!.toStringAsFixed(2);
              text = '${e.tooltip}\n'
                  'avg  $avgStr m/s\n'
                  'min  $lo m/s\n'
                  'max  $hi m/s';
            } else {
              text = '${e.tooltip}\navg  $avgStr m/s';
            }
          } else {
            final v = rod.toY.round();
            final valStr = metric == ChartMetric.distance
                ? '${NumberFormat('#,##0').format(v)} $_unit'
                : '$v $_unit';
            text = '${e.tooltip}\n$valStr';
          }
          return BarTooltipItem(
            text,
            const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              height: 1.4,
            ),
          );
        },
      ),
    );
  }

  BarChartGroupData _makeBar(int x, _DataPoint e, double width) {
    final y = e.value;
    return BarChartGroupData(
      x: x,
      barRods: [
        BarChartRodData(
          toY: y,
          width: width,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(5),
            topRight: Radius.circular(5),
          ),
          gradient: y > 0
              ? LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [_barColor, _barColorLight],
                )
              : null,
          color: y > 0 ? null : AppTheme.border.withOpacity(0.3),
        ),
      ],
    );
  }

  static String _fmtHour(int h) {
    if (h == 0) return '12a';
    if (h < 12) return '${h}a';
    if (h == 12) return '12p';
    return '${h - 12}p';
  }

  static double _barWidth(int count) {
    if (count <= 7) return 28;
    if (count <= 24) return 10;
    if (count <= 31) return 8;
    return 10;
  }

  static int _labelInterval(int count) {
    if (count <= 7) return 1;
    if (count <= 24) return 3;
    if (count <= 31) return 5;
    return 4; // 6M weekly
  }
}

class _SummaryStat extends StatelessWidget {
  const _SummaryStat({
    required this.label,
    required this.value,
    required this.unit,
  });

  final String label;
  final String value;
  final String unit;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            color: AppTheme.textSoft,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 2),
        RichText(
          text: TextSpan(
            children: [
              TextSpan(
                text: value,
                style: const TextStyle(
                  color: AppTheme.textDark,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              TextSpan(
                text: ' $unit',
                style: const TextStyle(
                  color: AppTheme.textSoft,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DataPoint {
  final String label;
  final double value;
  final String tooltip;
  final double? minValue;
  final double? maxValue;

  const _DataPoint({
    required this.label,
    required this.value,
    required this.tooltip,
    this.minValue,
    this.maxValue,
  });
}

// ---------------------------------------------------------------------------
// Shared chart helpers
// ---------------------------------------------------------------------------

const _axisStyle = TextStyle(
  color: AppTheme.textSoft,
  fontSize: 11,
  fontWeight: FontWeight.w400,
);

const _noTitles = AxisTitles(sideTitles: SideTitles(showTitles: false));

double _niceMax(double raw) {
  if (raw <= 0) return 100;
  final padded = raw * 1.12;
  final magnitude = [5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000]
      .firstWhere((m) => padded <= m * 4, orElse: () => 10000);
  return (padded / magnitude).ceil() * magnitude.toDouble();
}

/// Nicely-rounded ceiling for fractional metrics (gait speed in m/s).
/// Picks 0.5 / 1.0 / 1.5 / 2.0 / 3.0 etc. based on the input range.
double _niceMaxFractional(double raw) {
  if (raw <= 0) return 1.0;
  final padded = raw * 1.10;
  if (padded <= 0.5) return 0.5;
  if (padded <= 1.0) return 1.0;
  if (padded <= 1.5) return 1.5;
  if (padded <= 2.0) return 2.0;
  if (padded <= 3.0) return 3.0;
  return ((padded * 2).ceil() / 2).toDouble();
}

AxisTitles _leftTitles(double yMax) => AxisTitles(
      sideTitles: SideTitles(
        showTitles: true,
        reservedSize: 44,
        interval: yMax / 4,
        getTitlesWidget: (value, _) {
          if (value == 0) return const SizedBox.shrink();
          final label = value >= 1000
              ? '${(value / 1000).toStringAsFixed(1)}k'
              : value.round().toString();
          return Padding(
            padding: const EdgeInsets.only(right: 10),
            child: Text(label, style: _axisStyle),
          );
        },
      ),
    );

/// Fractional left-axis labels (gait speed). Two decimals when the ceiling
/// is below 1; one decimal otherwise.
AxisTitles _leftTitlesFractional(double yMax) => AxisTitles(
      sideTitles: SideTitles(
        showTitles: true,
        reservedSize: 48,
        interval: yMax / 4,
        getTitlesWidget: (value, _) {
          if (value == 0) return const SizedBox.shrink();
          final label =
              yMax <= 1.0 ? value.toStringAsFixed(2) : value.toStringAsFixed(1);
          return Padding(
            padding: const EdgeInsets.only(right: 10),
            child: Text(label, style: _axisStyle),
          );
        },
      ),
    );

FlGridData _grid(double yMax) => FlGridData(
      show: true,
      drawVerticalLine: false,
      horizontalInterval: yMax / 4,
      getDrawingHorizontalLine: (v) => FlLine(
        color: AppTheme.border.withOpacity(0.45),
        strokeWidth: 1,
        dashArray: [6, 4],
      ),
    );
