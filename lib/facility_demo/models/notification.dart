/// Notification rule types rendered in the Census + Patient Detail badges.
///
/// The original demo spec named three (`noActivityToday`, `belowTypical`,
/// `decliningTrend`); 1C-slim + 1B-rev Threshold Detector added six more
/// alert types into the Alert History table. The live build maps each
/// server-side `alertType` value to one of these enum cases per
/// phase-2b-fac-r-facility-reads.md §Notification badge mapping (L6).
/// Demo mode keeps emitting just the original three via
/// [NotificationEngine].
enum NotificationType {
  // 1C-slim behavioral rules (deployed 2026-05-24)
  noActivityToday,
  belowTypical,
  decliningTrend,

  // 1C-slim offline rules
  deviceOffline,
  deviceSilent,

  // 1B-rev Threshold Detector rules (deployed 2026-04-27)
  batteryCritical,
  batteryLow,
  signalLost,
  signalWeak,

  // Catch-all for unknown alertType values (forward as generic "Alert").
  other;

  String get label {
    switch (this) {
      case NotificationType.noActivityToday:
        return 'No activity today';
      case NotificationType.belowTypical:
        return 'Below typical activity';
      case NotificationType.decliningTrend:
        return 'Declining trend';
      case NotificationType.deviceOffline:
        return 'Device offline';
      case NotificationType.deviceSilent:
        return 'Device silent';
      case NotificationType.batteryCritical:
        return 'Battery critical';
      case NotificationType.batteryLow:
        return 'Battery low';
      case NotificationType.signalLost:
        return 'Signal lost';
      case NotificationType.signalWeak:
        return 'Signal weak';
      case NotificationType.other:
        return 'Alert';
    }
  }
}

enum NotificationSeverity { critical, warning }

/// A single computed notification on a patient. The same patient can have
/// multiple (e.g. low activity + declining trend); UI dedupes nothing.
class PatientNotification {
  final String patientId;
  final NotificationType type;
  final NotificationSeverity severity;
  final String
      detail; // one-line context, e.g. "0 steps today · last data 9h ago"

  const PatientNotification({
    required this.patientId,
    required this.type,
    required this.severity,
    required this.detail,
  });

  /// Stable key for dismissal/notes lookups.
  String get key => '$patientId:${type.name}';
}

/// A note written by a caregiver on a notification. Notes survive
/// dismissal so the audit trail remains readable.
class NotificationNote {
  final String text;
  final DateTime addedAt;

  const NotificationNote({required this.text, required this.addedAt});
}
