import '../models/notification.dart';
import '../../data/facility_repository.dart';

/// Snapshot of a patient's data shape used to evaluate notification rules.
/// Built once per patient by FacilityMockData; passed into NotificationEngine.
class NotificationContext {
  final int stepsToday;
  final int activeMinutesToday;
  final bool hasDataToday;
  final int median7Day;
  final int medianPrior23Day;
  final Duration lastDataAgo;

  const NotificationContext({
    required this.stepsToday,
    required this.activeMinutesToday,
    required this.hasDataToday,
    required this.median7Day,
    required this.medianPrior23Day,
    required this.lastDataAgo,
  });
}

/// Pure rule evaluator. Three rules per spec:
///   - No activity today (Critical)        — today.steps == 0
///   - Below typical (Warning)             — today < 65% of 7-day median
///   - Declining trend (Warning)           — 7-day median < 75% of prior 23 days
class NotificationEngine {
  const NotificationEngine();

  static const double belowTypicalThreshold = 0.70;
  static const double decliningTrendThreshold = 0.85;

  List<PatientNotification> evaluate(
      String patientId, NotificationContext ctx) {
    final out = <PatientNotification>[];

    if (!ctx.hasDataToday) {
      out.add(PatientNotification(
        patientId: patientId,
        type: NotificationType.noActivityToday,
        severity: NotificationSeverity.critical,
        detail: '0 steps today · last data ${_formatAgo(ctx.lastDataAgo)}',
      ));
    } else if (ctx.median7Day > 0 &&
        ctx.stepsToday < ctx.median7Day * belowTypicalThreshold) {
      out.add(PatientNotification(
        patientId: patientId,
        type: NotificationType.belowTypical,
        severity: NotificationSeverity.warning,
        detail:
            '${ctx.stepsToday} steps today vs ${ctx.median7Day} typical (last 7 days)',
      ));
    }

    if (ctx.median7Day > 0 &&
        ctx.medianPrior23Day > 0 &&
        ctx.median7Day < ctx.medianPrior23Day * decliningTrendThreshold) {
      final pct = ((1 - (ctx.median7Day / ctx.medianPrior23Day)) * 100).round();
      out.add(PatientNotification(
        patientId: patientId,
        type: NotificationType.decliningTrend,
        severity: NotificationSeverity.warning,
        detail: '7-day average down $pct% vs prior 3 weeks',
      ));
    }

    return out;
  }

  static String _formatAgo(Duration d) {
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }
}

/// Convenience that delegates to the repository's polymorphic
/// notifications method. Demo impl returns engine-evaluated rules;
/// live impl returns alertType-mapped notifications per
/// phase-2b-fac-r L6.
///
/// Retained as a free function so existing call sites
/// (`patient_census_view.dart`, `patient_detail_view.dart`,
/// `notification_review_panel.dart`) don't need to chase the rename.
Future<List<PatientNotification>> notificationsForPatient(
  FacilityRepository data,
  String patientId,
) =>
    data.notificationsFor(patientId);
