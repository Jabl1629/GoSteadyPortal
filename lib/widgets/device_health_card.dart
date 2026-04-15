import 'package:flutter/material.dart';

import '../models/device.dart';
import '../theme/app_theme.dart';

/// Lightweight inline status indicators for battery, signal, and last
/// data. No heavy card — just the chips and a subtle chevron. Tap to
/// navigate to the full device detail screen.
class DeviceStatusBar extends StatelessWidget {
  const DeviceStatusBar({
    super.key,
    required this.device,
    required this.onTap,
  });

  final DeviceHealth device;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Row(
          children: [
            _Indicator(
              icon: Icons.battery_full_rounded,
              label: '${(device.batteryLevel * 100).round()}%',
              color: _batteryColor(device.batteryLevel),
            ),
            const SizedBox(width: 16),
            _Indicator(
              icon: Icons.signal_cellular_alt_rounded,
              label: _signalLabel(device.signalLevel),
              color: _signalColor(device.signalLevel),
            ),
            const SizedBox(width: 16),
            _Indicator(
              icon: Icons.cloud_done_rounded,
              label: device.lastSeenDescription,
              color: device.isOnline
                  ? AppTheme.statusOk
                  : AppTheme.statusAlert,
            ),
            const SizedBox(width: 8),
            Icon(
              Icons.chevron_right_rounded,
              color: AppTheme.textSoft.withOpacity(0.4),
              size: 20,
            ),
          ],
        ),
      ),
    );
  }

  static Color _batteryColor(double level) {
    if (level > 0.5) return AppTheme.statusOk;
    if (level > 0.2) return AppTheme.statusWarn;
    return AppTheme.statusAlert;
  }

  static Color _signalColor(double level) {
    if (level > 0.6) return AppTheme.statusOk;
    if (level > 0.3) return AppTheme.statusWarn;
    return AppTheme.statusAlert;
  }

  static String _signalLabel(double level) {
    if (level > 0.6) return 'Strong';
    if (level > 0.3) return 'Good';
    return 'Weak';
  }
}

class _Indicator extends StatelessWidget {
  const _Indicator({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color, size: 18),
        const SizedBox(width: 5),
        Text(
          label,
          style: const TextStyle(
            color: AppTheme.textSoft,
            fontSize: 15,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}
