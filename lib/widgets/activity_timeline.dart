import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../models/activity.dart';
import '../theme/app_theme.dart';

/// 24-hour bar chart of today's hourly steps. Shows the caregiver *when*
/// their loved one was moving — quiet overnight, morning rise, meals,
/// etc. Any unseen hour (future-of-today) is left blank.
class ActivityTimeline extends StatelessWidget {
  const ActivityTimeline({super.key, required this.today});

  final DailyActivity today;

  @override
  Widget build(BuildContext context) {
    final byHour = <int, int>{
      for (final h in today.hours) h.hour.hour: h.steps,
    };
    final maxSteps = byHour.values.fold<int>(0, (m, v) => v > m ? v : m);
    final yMax = (maxSteps == 0 ? 100 : (maxSteps * 1.15)).toDouble();

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppTheme.cardRadius),
        boxShadow: AppTheme.cardShadow,
        border: Border.all(color: AppTheme.border, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'TODAY · HOURLY ACTIVITY',
            style: TextStyle(
              color: AppTheme.textSoft,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Steps per hour',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 24),
          SizedBox(
            height: 220,
            child: BarChart(
              BarChartData(
                alignment: BarChartAlignment.spaceBetween,
                maxY: yMax,
                minY: 0,
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  horizontalInterval: yMax / 4,
                  getDrawingHorizontalLine: (v) => FlLine(
                    color: AppTheme.border,
                    strokeWidth: 1,
                  ),
                ),
                borderData: FlBorderData(show: false),
                titlesData: FlTitlesData(
                  topTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  rightTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 36,
                      interval: yMax / 4,
                      getTitlesWidget: (value, meta) {
                        if (value == 0) return const SizedBox.shrink();
                        return Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Text(
                            value.round().toString(),
                            style: const TextStyle(
                              color: AppTheme.textSoft,
                              fontSize: 11,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 28,
                      interval: 1,
                      getTitlesWidget: (value, meta) {
                        final h = value.toInt();
                        if (h % 3 != 0) return const SizedBox.shrink();
                        return Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            _formatHour(h),
                            style: const TextStyle(
                              color: AppTheme.textSoft,
                              fontSize: 11,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                barTouchData: BarTouchData(
                  touchTooltipData: BarTouchTooltipData(
                    getTooltipColor: (_) => AppTheme.textDark,
                    tooltipRoundedRadius: 8,
                    getTooltipItem: (group, _, rod, __) {
                      return BarTooltipItem(
                        '${_formatHour(group.x)}\n${rod.toY.round()} steps',
                        const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      );
                    },
                  ),
                ),
                barGroups: List.generate(24, (h) {
                  final steps = byHour[h] ?? 0;
                  return BarChartGroupData(
                    x: h,
                    barRods: [
                      BarChartRodData(
                        toY: steps.toDouble(),
                        width: 10,
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(4),
                          topRight: Radius.circular(4),
                        ),
                        color: steps > 0
                            ? AppTheme.sage
                            : AppTheme.border.withOpacity(0.5),
                      ),
                    ],
                  );
                }),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _formatHour(int h) {
    if (h == 0) return '12a';
    if (h < 12) return '${h}a';
    if (h == 12) return '12p';
    return '${h - 12}p';
  }
}
