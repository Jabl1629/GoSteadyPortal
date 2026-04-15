import 'package:flutter/material.dart';

import '../models/activity.dart';
import '../theme/app_theme.dart';

/// Segmented toggle for switching between time ranges. Equal-width
/// segments with a polished active state.
class TimeRangeToggle extends StatelessWidget {
  const TimeRangeToggle({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  final TimeRange selected;
  final ValueChanged<TimeRange> onChanged;

  static const _labels = {
    TimeRange.day: '24H',
    TimeRange.week: '7D',
    TimeRange.month: '30D',
    TimeRange.sixMonth: '6M',
  };

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.cream,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border.withOpacity(0.5), width: 1),
      ),
      padding: const EdgeInsets.all(4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: TimeRange.values.map((range) {
          final isActive = range == selected;
          return Expanded(
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () => onChanged(range),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOut,
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  decoration: BoxDecoration(
                    color: isActive ? AppTheme.sage : Colors.transparent,
                    borderRadius: BorderRadius.circular(9),
                    boxShadow: isActive
                        ? [
                            BoxShadow(
                              color: AppTheme.sage.withOpacity(0.3),
                              blurRadius: 10,
                              offset: const Offset(0, 3),
                            ),
                          ]
                        : null,
                  ),
                  child: Text(
                    _labels[range]!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: isActive ? Colors.white : AppTheme.textDark,
                      fontSize: 14,
                      fontWeight: isActive ? FontWeight.w700 : FontWeight.w600,
                      letterSpacing: 0.3,
                    ),
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}
