import 'package:flutter/material.dart';

import '../models/device.dart';
import '../theme/app_theme.dart';

/// Operational health card: battery, signal, last heartbeat, and the
/// identifying device metadata (serial, firmware, sensor).
class DeviceHealthCard extends StatelessWidget {
  const DeviceHealthCard({super.key, required this.device});

  final DeviceHealth device;

  @override
  Widget build(BuildContext context) {
    return _PortalCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _SectionLabel(text: 'Device health'),
              const Spacer(),
              _OnlinePill(online: device.isOnline),
            ],
          ),
          const SizedBox(height: 18),
          _MetricRow(
            icon: Icons.battery_full_rounded,
            label: 'Battery',
            value: '${(device.batteryLevel * 100).round()}%',
            sub: '${device.batteryMv} mV',
            progress: device.batteryLevel,
            progressColor: _batteryColor(device.batteryLevel),
          ),
          const SizedBox(height: 14),
          _MetricRow(
            icon: Icons.signal_cellular_alt_rounded,
            label: 'Cellular signal',
            value: '${device.signalDbm} dBm',
            sub: _signalDescription(device.signalDbm),
            progress: device.signalLevel,
            progressColor: _signalColor(device.signalLevel),
          ),
          const SizedBox(height: 14),
          _MetricRow(
            icon: Icons.cloud_done_rounded,
            label: 'Last data received',
            value: device.lastSeenDescription,
            sub: 'Heartbeat every ${device.heartbeatIntervalHours}h',
            progress: null,
            progressColor: AppTheme.sage,
          ),
          const SizedBox(height: 22),
          Divider(color: AppTheme.border, height: 1),
          const SizedBox(height: 18),
          Wrap(
            spacing: 28,
            runSpacing: 12,
            children: [
              _MetaField(label: 'Serial', value: device.serialNumber),
              _MetaField(label: 'Firmware', value: device.firmwareVersion),
              _MetaField(label: 'Sensor', value: device.sensorModel),
            ],
          ),
        ],
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

  static String _signalDescription(int dbm) {
    if (dbm >= -80) return 'Strong';
    if (dbm >= -100) return 'Good';
    if (dbm >= -110) return 'Marginal';
    return 'Weak';
  }
}

class _MetricRow extends StatelessWidget {
  const _MetricRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.sub,
    required this.progress,
    required this.progressColor,
  });

  final IconData icon;
  final String label;
  final String value;
  final String sub;
  final double? progress;
  final Color progressColor;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: AppTheme.cream,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: AppTheme.sage, size: 20),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      color: AppTheme.textSoft,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    value,
                    style: const TextStyle(
                      color: AppTheme.textDark,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              if (progress != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: progress!.clamp(0.0, 1.0),
                    minHeight: 6,
                    backgroundColor: AppTheme.border.withOpacity(0.6),
                    valueColor: AlwaysStoppedAnimation<Color>(progressColor),
                  ),
                )
              else
                const SizedBox(height: 2),
              const SizedBox(height: 4),
              Text(
                sub,
                style: const TextStyle(
                  color: AppTheme.textSoft,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MetaField extends StatelessWidget {
  const _MetaField({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            color: AppTheme.textSoft,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            color: AppTheme.textDark,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _OnlinePill extends StatelessWidget {
  const _OnlinePill({required this.online});

  final bool online;

  @override
  Widget build(BuildContext context) {
    final color = online ? AppTheme.statusOk : AppTheme.statusOffline;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(100),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            online ? 'Online' : 'Offline',
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: const TextStyle(
        color: AppTheme.textSoft,
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.2,
      ),
    );
  }
}

class _PortalCard extends StatelessWidget {
  const _PortalCard({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppTheme.cardRadius),
        boxShadow: AppTheme.cardShadow,
        border: Border.all(color: AppTheme.border, width: 1),
      ),
      child: child,
    );
  }
}
