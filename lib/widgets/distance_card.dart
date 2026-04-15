import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/activity.dart';
import '../theme/app_theme.dart';

/// Today's headline glanceable tile. Always locked to today — this is the
/// caregiver's "is everything okay?" check. Clear language up top, key
/// metrics immediately below.
class TodayCard extends StatelessWidget {
  const TodayCard({super.key, required this.today});

  final DailyActivity today;

  String get _motionLabel {
    final mins = today.totalTimeInMotionMinutes;
    final hours = mins ~/ 60;
    final remainder = mins % 60;
    if (hours > 0 && remainder > 0) return '${hours}h ${remainder}m';
    if (hours > 0) return '${hours}h 0m';
    return '${remainder}m';
  }

  @override
  Widget build(BuildContext context) {
    final formatter = NumberFormat('#,##0');
    final feet = today.totalDistanceFt;
    final steps = today.totalSteps;

    return Container(
      padding: const EdgeInsets.fromLTRB(32, 28, 32, 30),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppTheme.cardRadius),
        boxShadow: AppTheme.cardShadowElevated,
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          stops: [0.0, 0.5, 1.0],
          colors: [
            Color(0xFF5A8E6A),
            AppTheme.sage,
            Color(0xFF375A42),
          ],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Today\'s Activity',
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w500,
                ),
          ),
          const SizedBox(height: 24),
          IntrinsicHeight(
            child: Row(
              children: [
                // Active time — left
                Expanded(
                  child: _Metric(
                    icon: Icons.timer_outlined,
                    value: _motionLabel,
                    label: 'Active time',
                  ),
                ),
                VerticalDivider(
                  width: 32,
                  thickness: 1,
                  indent: 4,
                  endIndent: 4,
                  color: Colors.white.withOpacity(0.18),
                ),
                // Distance — right
                Expanded(
                  child: _Metric(
                    icon: Icons.directions_walk_rounded,
                    value: '${formatter.format(feet.round())} ft',
                    label: '${formatter.format(steps)} steps',
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

class _Metric extends StatelessWidget {
  const _Metric({
    required this.icon,
    required this.value,
    required this.label,
  });

  final IconData icon;
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.12),
            borderRadius: BorderRadius.circular(11),
          ),
          child: Icon(icon, color: Colors.white.withOpacity(0.85), size: 20),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                value,
                style: Theme.of(context).textTheme.displayLarge?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w500,
                      fontSize: 32,
                      height: 1.0,
                    ),
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.75),
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
