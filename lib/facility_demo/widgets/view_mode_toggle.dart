import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../state/facility_selection.dart';

/// Two-segment Tile / List toggle for the census header. Mirrors the
/// visual language of `TimeRangeToggle` so the controls feel consistent.
class ViewModeToggle extends StatelessWidget {
  const ViewModeToggle({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  final CensusViewMode selected;
  final ValueChanged<CensusViewMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.cream,
        borderRadius: BorderRadius.circular(100),
        border: Border.all(color: AppTheme.border.withOpacity(0.5), width: 1),
      ),
      padding: const EdgeInsets.all(3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Segment(
            icon: Icons.view_list_rounded,
            label: CensusViewMode.list.label,
            active: selected == CensusViewMode.list,
            onTap: () => onChanged(CensusViewMode.list),
          ),
          _Segment(
            icon: Icons.grid_view_rounded,
            label: CensusViewMode.tile.label,
            active: selected == CensusViewMode.tile,
            onTap: () => onChanged(CensusViewMode.tile),
          ),
        ],
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: active ? AppTheme.sage : Colors.transparent,
            borderRadius: BorderRadius.circular(100),
            boxShadow: active
                ? [
                    BoxShadow(
                      color: AppTheme.sage.withOpacity(0.25),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 14,
                color: active ? Colors.white : AppTheme.textSoft,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: active ? Colors.white : AppTheme.textDark,
                  fontSize: 12,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w600,
                  letterSpacing: 0.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
