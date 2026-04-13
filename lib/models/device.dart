/// Operational health of a GoSteady device. Populated from the device's
/// heartbeat payload (REQ-FW-07, transmitted every ~4 hours).
class DeviceHealth {
  /// 8-digit alphanumeric serial printed on the device housing (REQ-HW-M-05).
  final String serialNumber;

  /// Firmware semver string baked into the build.
  final String firmwareVersion;

  /// Which IMU the samples came from (BMI270 / ADXL367).
  final String sensorModel;

  /// Battery voltage in millivolts from the most recent heartbeat.
  /// Li-SOCl2 nominal is ~3600 mV fresh, ~3000 mV near end-of-life.
  final int batteryMv;

  /// Cellular signal strength in dBm. Typical LTE-M range: -70 (great) to
  /// -110 (usable) to -120 (marginal).
  final int signalDbm;

  /// Timestamp of the most recent payload received by the cloud.
  final DateTime lastDataReceived;

  /// Expected heartbeat interval in hours. Anything older than ~2x this
  /// window means the device is considered offline.
  final int heartbeatIntervalHours;

  const DeviceHealth({
    required this.serialNumber,
    required this.firmwareVersion,
    required this.sensorModel,
    required this.batteryMv,
    required this.signalDbm,
    required this.lastDataReceived,
    this.heartbeatIntervalHours = 4,
  });

  /// Battery level as 0.0 - 1.0. Approximation based on Li-SOCl2 discharge
  /// curve between 3600 mV (full) and 3000 mV (end of life).
  double get batteryLevel {
    const fullMv = 3600;
    const emptyMv = 3000;
    final raw = (batteryMv - emptyMv) / (fullMv - emptyMv);
    return raw.clamp(0.0, 1.0);
  }

  /// Signal strength as 0.0 - 1.0 for UI rendering.
  /// -70 dBm or better = 1.0, -110 dBm or worse = 0.0.
  double get signalLevel {
    const strongDbm = -70;
    const weakDbm = -110;
    final raw = (signalDbm - weakDbm) / (strongDbm - weakDbm);
    return raw.clamp(0.0, 1.0);
  }

  /// Is the device currently considered online? True if the last payload
  /// is within 2x the heartbeat interval.
  bool get isOnline {
    final cutoff = Duration(hours: heartbeatIntervalHours * 2);
    return DateTime.now().difference(lastDataReceived) < cutoff;
  }

  /// Human-readable "time since last heard from" summary.
  String get lastSeenDescription {
    final delta = DateTime.now().difference(lastDataReceived);
    if (delta.inMinutes < 1) return 'just now';
    if (delta.inMinutes < 60) return '${delta.inMinutes} min ago';
    if (delta.inHours < 24) return '${delta.inHours}h ago';
    return '${delta.inDays}d ago';
  }
}
