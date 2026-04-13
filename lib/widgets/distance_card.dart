import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/activity.dart';
import '../theme/app_theme.dart';

/// Today's headline activity numbers: distance traveled + step count +
/// active hours. Big, glanceable typography — this is what caregivers
/// look at first.
class DistanceCard extends StatelessWidget {
  const DistanceCard({super.key, required this.today});

  final DailyActivity today;

  @override
  Widget build(BuildContext context) {
    final feet = today.totalDistanceFt;
    final steps = today.totalSteps;
    final activeHours = today.activeHourCount;
    final formatter = NumberFormat('#,##0');

    return Container(
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppTheme.cardRadius),
        boxShadow: AppTheme.cardShadow,
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppTheme.sage, AppTheme.sageDark],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'DISTANCE TODAY',
            style: TextStyle(
              color: Colors.white.withOpacity(0.85),
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                formatter.format(feet.round()),
                style: Theme.of(context)
                    .textTheme
                    .displayLarge
                    ?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w500,
                      fontSize: 56,
                      height: 1.0,
                    ),
              ),
              const SizedBox(width: 8),
              Text(
                'ft',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.85),
                  fontSize: 20,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${formatter.format(steps)} steps · $activeHours active '
            '${activeHours == 1 ? 'hour' : 'hours'}',
            style: TextStyle(
              color: Colors.white.withOpacity(0.88),
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.14),
              borderRadius: BorderRadius.circular(100),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.directions_walk_rounded,
                  color: Colors.white.withOpacity(0.9),
                  size: 16,
                ),
                const SizedBox(width: 6),
                Text(
                  '${(feet / 5280 * 100).toStringAsFixed(1)}% of a mile',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
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
