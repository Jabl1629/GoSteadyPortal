import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/activity.dart';
import '../theme/app_theme.dart';

/// Which metric the chart displays.
enum ChartMetric { steps, distance, timeInMotion }

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
    }
  }

  String get _perLabel {
    switch (timeRange) {
      case TimeRange.day:
        return 'hour';
      case TimeRange.week:
      case TimeRange.month:
        return 'day';
      case TimeRange.sixMonth:
        return 'week';
    }
  }

  Color get _barColor {
    switch (metric) {
      case ChartMetric.steps:
        return AppTheme.sage;
      case ChartMetric.distance:
        return const Color(0xFF5A8E6A);
      case ChartMetric.timeInMotion:
        return const Color(0xFF6B9E7D);
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
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 28),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppTheme.cardRadius),
        boxShadow: AppTheme.cardShadow,
        border: Border.all(color: AppTheme.border.withOpacity(0.5), width: 1),
      ),
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
            'Per $_perLabel',
            style: const TextStyle(
              color: AppTheme.textSoft,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 24),
          SizedBox(
            height: 220,
            child: _buildChart(),
          ),
        ],
      ),
    );
  }

  Widget _buildChart() {
    // Extract (labels, values) for the selected time range.
    final entries = _extractData();
    if (entries.isEmpty) return const SizedBox.shrink();

    final values = entries.map((e) => e.value).toList();
    final maxVal = values.fold<double>(0, (m, v) => v > m ? v : m);
    final yMax = _niceMax(maxVal);
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
          leftTitles: _leftTitles(yMax),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 28,
              interval: 1,
              getTitlesWidget: (value, _) {
                final i = value.toInt();
                if (i < 0 || i >= entries.length) return const SizedBox.shrink();
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
          return _makeBar(i, values[i], barWidth);
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
      if (a != null) {
        switch (metric) {
          case ChartMetric.steps:
            val = a.steps.toDouble();
          case ChartMetric.distance:
            val = a.distanceFt;
          case ChartMetric.timeInMotion:
            val = a.timeInMotionMinutes.toDouble();
        }
      }
      return _DataPoint(label: _fmtHour(h), value: val, tooltip: _fmtHour(h));
    });
  }

  List<_DataPoint> _fromDaily(List<DailyActivity> days,
      {required bool shortLabel}) {
    return days.map((d) {
      double val;
      switch (metric) {
        case ChartMetric.steps:
          val = d.totalSteps.toDouble();
        case ChartMetric.distance:
          val = d.totalDistanceFt;
        case ChartMetric.timeInMotion:
          val = d.totalTimeInMotionMinutes.toDouble();
      }
      final label = shortLabel
          ? DateFormat('E').format(d.date)
          : DateFormat('M/d').format(d.date);
      final tip = DateFormat('MMM d').format(d.date);
      return _DataPoint(label: label, value: val, tooltip: tip);
    }).toList();
  }

  List<_DataPoint> _fromWeekly(List<WeeklyActivity> weeks) {
    return weeks.map((w) {
      double val;
      switch (metric) {
        case ChartMetric.steps:
          val = w.totalSteps.toDouble();
        case ChartMetric.distance:
          val = w.totalDistanceFt;
        case ChartMetric.timeInMotion:
          val = w.totalTimeInMotionMinutes.toDouble();
      }
      final label = DateFormat('MMM').format(w.weekStart);
      final tip = 'Week of ${DateFormat('MMM d').format(w.weekStart)}';
      return _DataPoint(label: label, value: val, tooltip: tip);
    }).toList();
  }

  BarTouchData _touchData(List<_DataPoint> entries) {
    return BarTouchData(
      touchTooltipData: BarTouchTooltipData(
        getTooltipColor: (_) => AppTheme.textDark,
        tooltipRoundedRadius: 10,
        tooltipPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        getTooltipItem: (group, _, rod, __) {
          final i = group.x;
          if (i < 0 || i >= entries.length) return null;
          final valStr = metric == ChartMetric.distance
              ? '${NumberFormat('#,##0').format(rod.toY.round())} $_unit'
              : '${rod.toY.round()} $_unit';
          return BarTooltipItem(
            '${entries[i].tooltip}\n$valStr',
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

  BarChartGroupData _makeBar(int x, double y, double width) =>
      BarChartGroupData(
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

class _DataPoint {
  final String label;
  final double value;
  final String tooltip;

  const _DataPoint({
    required this.label,
    required this.value,
    required this.tooltip,
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
