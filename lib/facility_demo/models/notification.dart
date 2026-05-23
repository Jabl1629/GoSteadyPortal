/// One of the three notification rules from the demo spec.
enum NotificationType {
  noActivityToday,
  belowTypical,
  decliningTrend;

  String get label {
    switch (this) {
      case NotificationType.noActivityToday:
        return 'No activity today';
      case NotificationType.belowTypical:
        return 'Below typical activity';
      case NotificationType.decliningTrend:
        return 'Declining trend';
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
