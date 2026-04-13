import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/activity.dart';
import '../theme/app_theme.dart';

/// 7-day history strip. One vertical "bar" per day with the day's total
/// distance and a day-of-week label. Gives a quick week-at-a-glance
/// trend without the complexity of a full chart component.
class DailyHistory extends StatelessWidget {
  const DailyHistory({super.key, required this.days});

  final List<DailyActivity> days;

  @override
  Widget build(BuildContext context) {
    final maxFt = days.fold<double>(
      0,
      (m, d) => d.totalDistanceFt > m ? d.totalDistanceFt : m,
    );
    final numberFormat = NumberFormat('#,##0');

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
            'LAST 7 DAYS',
            style: TextStyle(
              color: AppTheme.textSoft,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Distance by day',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 24),
          SizedBox(
            height: 180,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final day in days)
                  Expanded(
                    child: _DayBar(
                      day: day,
                      maxFt: maxFt,
                      formatter: numberFormat,
                    ),
                  ),
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
    required this.maxFt,
    required this.formatter,
  });

  final DailyActivity day;
  final double maxFt;
  final NumberFormat formatter;

  @override
  Widget build(BuildContext context) {
    final ratio = maxFt == 0 ? 0.0 : (day.totalDistanceFt / maxFt);
    final dayLabel = DateFormat('EEE').format(day.date);
    final dateLabel = DateFormat('M/d').format(day.date);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Text(
            formatter.format(day.totalDistanceFt.round()),
            style: const TextStyle(
              color: AppTheme.textDark,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final barHeight = constraints.maxHeight * ratio.clamp(0.04, 1.0);
                return Align(
                  alignment: Alignment.bottomCenter,
                  child: Container(
                    width: double.infinity,
                    height: barHeight,
                    decoration: BoxDecoration(
                      color: AppTheme.sageLight.withOpacity(0.85),
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(8),
                        topRight: Radius.circular(8),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          Text(
            dayLabel,
            style: const TextStyle(
              color: AppTheme.textDark,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          Text(
            dateLabel,
            style: const TextStyle(
              color: AppTheme.textSoft,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}
