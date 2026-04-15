import 'package:flutter/material.dart';

import '../models/device.dart';
import '../theme/app_theme.dart';

/// Full device detail screen — battery, signal, data timing, and device
/// metadata. Reached by tapping the status indicators on the dashboard.
class DeviceScreen extends StatelessWidget {
  const DeviceScreen({super.key, required this.device});

  final DeviceHealth device;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.warmWhite,
      body: SafeArea(
        child: SingleChildScrollView(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 700),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 32,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _BackButton(),
                    const SizedBox(height: 24),
                    Text(
                      'Device Details',
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      device.serialNumber,
                      style: const TextStyle(
                        color: AppTheme.textSoft,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 32),
                    _Card(
                      child: Column(
                        children: [
                          _MetricRow(
                            icon: Icons.battery_full_rounded,
                            label: 'Battery',
                            value: '${(device.batteryLevel * 100).round()}%',
                            sub: '${device.batteryMv} mV',
                            progress: device.batteryLevel,
                            progressColor: _batteryColor(device.batteryLevel),
                          ),
                          const SizedBox(height: 20),
                          _MetricRow(
                            icon: Icons.signal_cellular_alt_rounded,
                            label: 'Cellular signal',
                            value: '${device.signalDbm} dBm',
                            sub: _signalDescription(device.signalDbm),
                            progress: device.signalLevel,
                            progressColor: _signalColor(device.signalLevel),
                          ),
                          const SizedBox(height: 20),
                          _MetricRow(
                            icon: Icons.cloud_done_rounded,
                            label: 'Last data received',
                            value: device.lastSeenDescription,
                            sub:
                                'Heartbeat every ${device.heartbeatIntervalHours}h',
                            progress: null,
                            progressColor: AppTheme.sage,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    _Card(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'DEVICE INFO',
                            style: TextStyle(
                              color: AppTheme.textSoft,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 1.2,
                            ),
                          ),
                          const SizedBox(height: 16),
                          _InfoRow(label: 'Serial number', value: device.serialNumber),
                          const SizedBox(height: 12),
                          _InfoRow(label: 'Firmware', value: device.firmwareVersion),
                          const SizedBox(height: 12),
                          _InfoRow(label: 'Sensor', value: device.sensorModel),
                          const SizedBox(height: 12),
                          _InfoRow(
                            label: 'Status',
                            value: device.isOnline ? 'Online' : 'Offline',
                            valueColor: device.isOnline
                                ? AppTheme.statusOk
                                : AppTheme.statusAlert,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
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

  static String _signalDescription(int dbm) {
    if (dbm >= -80) return 'Strong';
    if (dbm >= -100) return 'Good';
    if (dbm >= -110) return 'Marginal';
    return 'Weak';
  }
}

class _BackButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.of(context).pop(),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: const [
          Icon(Icons.arrow_back_rounded, color: AppTheme.sage, size: 20),
          SizedBox(width: 6),
          Text(
            'Dashboard',
            style: TextStyle(
              color: AppTheme.sage,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
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

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.label,
    required this.value,
    this.valueColor,
  });

  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          label,
          style: const TextStyle(
            color: AppTheme.textSoft,
            fontSize: 14,
          ),
        ),
        const Spacer(),
        Text(
          value,
          style: TextStyle(
            color: valueColor ?? AppTheme.textDark,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
