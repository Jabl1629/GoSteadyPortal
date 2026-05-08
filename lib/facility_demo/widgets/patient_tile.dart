import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../theme/app_theme.dart';
import '../data/facility_mock_data.dart';
import '../models/notification.dart';
import '../models/patient.dart';

/// Single tile in the Patient Census wall. Layout per spec §5.5:
///   name (+ alert icon if any active notifications)
///   unit · room
///   {steps} steps   {minutes} min active
///   review-needed caption (only if active notifications)
///
/// "No data today" state when both metrics are zero.
class PatientTile extends StatelessWidget {
  const PatientTile({
    super.key,
    required this.summary,
    required this.unitDisplay,
    required this.selected,
    required this.onTap,
    this.activeNotifications = const [],
  });

  final PatientSummary summary;
  final String unitDisplay; // resolved unit name (e.g. "Memory Care")
  final bool selected;
  final VoidCallback onTap;
  final List<PatientNotification> activeNotifications;

  /// Highest-severity color from the active notifications, or null if none.
  Color? get _alertColor {
    if (activeNotifications.isEmpty) return null;
    final hasCritical = activeNotifications
        .any((n) => n.severity == NotificationSeverity.critical);
    return hasCritical ? AppTheme.statusAlert : AppTheme.statusWarn;
  }

  /// Short caption text. Single notification: just its label. Multiple:
  /// label of the most-severe one + "+N more".
  static String _captionText(List<PatientNotification> ns) {
    if (ns.isEmpty) return '';
    final sorted = [...ns]..sort((a, b) =>
        a.severity.index.compareTo(b.severity.index));
    final primary = sorted.first.type.label;
    if (sorted.length == 1) return primary;
    return '$primary  +${sorted.length - 1} more';
  }

  @override
  Widget build(BuildContext context) {
    final patient = summary.patient;
    final stepsFmt = NumberFormat('#,##0').format(summary.stepsToday);
    final alertColor = _alertColor;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
          // Fixed minimum height so the grid stays uniform whether or not
          // a tile carries the review-needed caption. Sized to fit the
          // tallest variant (name + room + metrics + caption) with breathing
          // room.
          constraints: const BoxConstraints(minHeight: 158),
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
          decoration: BoxDecoration(
            color: selected
                ? AppTheme.sage.withOpacity(0.06)
                : Colors.white,
            borderRadius: BorderRadius.circular(AppTheme.cardRadius),
            border: Border.all(
              color: selected
                  ? AppTheme.sage
                  : AppTheme.border.withOpacity(0.6),
              width: selected ? 2 : 1,
            ),
            boxShadow: selected ? null : AppTheme.cardShadow,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      patient.displayName,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                          ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (alertColor != null) ...[
                    const SizedBox(width: 8),
                    Icon(
                      Icons.notification_important_rounded,
                      size: 20,
                      color: alertColor,
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 2),
              Text(
                '$unitDisplay  ·  Rm ${patient.room}',
                style: const TextStyle(
                  color: AppTheme.textSoft,
                  fontSize: 13,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 16),
              if (summary.hasDataToday)
                Row(
                  children: [
                    Expanded(
                      child: _Metric(
                        value: stepsFmt,
                        unit: 'steps',
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _Metric(
                        value: summary.activeMinutesToday.toString(),
                        unit: 'min active',
                      ),
                    ),
                  ],
                )
              // When the resident has no activity but no review notification
              // either, show a soft empty-data line. When a notification is
              // active, the colored review caption below already conveys
              // the state — skip the italic to avoid duplication.
              else if (activeNotifications.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    'No activity today',
                    style: TextStyle(
                      color: AppTheme.textSoft.withOpacity(0.7),
                      fontSize: 14,
                      fontStyle: FontStyle.italic,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              if (alertColor != null) ...[
                const SizedBox(height: 12),
                _ReviewCaption(
                  text: _captionText(activeNotifications),
                  color: alertColor,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ReviewCaption extends StatelessWidget {
  const _ReviewCaption({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.1,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.value, required this.unit});

  final String value;
  final String unit;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontSize: 22,
                fontWeight: FontWeight.w600,
                color: AppTheme.textDark,
                height: 1.05,
              ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 1),
        Text(
          unit,
          style: const TextStyle(
            color: AppTheme.textSoft,
            fontSize: 12,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.2,
          ),
        ),
      ],
    );
  }
}

// Re-export to keep imports tidy in views that use the tile.
typedef PatientTileData = PatientSummary;

// Helper: lookup unit display name by id, used by callers that have
// the patient summary but not yet the unit string.
String unitDisplayFor(FacilityMockData data, String unitId) {
  return data.allUnits().firstWhere((u) => u.id == unitId).displayName;
}
