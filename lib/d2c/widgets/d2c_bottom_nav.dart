import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../theme/app_theme.dart';
import '../d2c_routes.dart';

/// The three top-level tabs of the signed-in D2C experience. Everyone
/// (caregivers + walker users) gets the same three — no role-conditional
/// nav. Drill-down screens (notification prefs, audit, device settings)
/// keep this bar with [D2CTab.account] active.
enum D2CTab { activity, careTeam, account }

/// Persistent bottom navigation shared by Dashboard, Care Team, and
/// Account so the bar never disappears as you move between tabs.
class D2CBottomNav extends StatelessWidget {
  const D2CBottomNav({super.key, required this.active});

  final D2CTab active;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(
          top: BorderSide(color: AppTheme.border.withOpacity(0.6)),
        ),
      ),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: SafeArea(
        top: false,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _NavItem(
              icon: Icons.show_chart_rounded,
              label: 'Activity',
              active: active == D2CTab.activity,
              onTap: () => context.go(D2CRoutes.dashboard),
            ),
            _NavItem(
              icon: Icons.group_outlined,
              label: 'Care Team',
              active: active == D2CTab.careTeam,
              onTap: () => context.go(D2CRoutes.careTeam),
            ),
            _NavItem(
              icon: Icons.person_outline,
              label: 'Account',
              active: active == D2CTab.account,
              onTap: () => context.go(D2CRoutes.account),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final color = active ? AppTheme.sage : AppTheme.textSoft;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 11.5,
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
