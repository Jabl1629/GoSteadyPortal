import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../theme/app_theme.dart';
import '../data/facility_mock_data.dart';
import '../models/patient.dart';

/// Single tile in the Patient Census wall. Layout per spec §5.5:
///   name
///   unit · room
///   {steps} steps   {minutes} min active
///
/// "No data today" state when both metrics are zero.
class PatientTile extends StatelessWidget {
  const PatientTile({
    super.key,
    required this.summary,
    required this.unitDisplay,
    required this.selected,
    required this.onTap,
  });

  final PatientSummary summary;
  final String unitDisplay; // resolved unit name (e.g. "Memory Care")
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final patient = summary.patient;
    final stepsFmt = NumberFormat('#,##0').format(summary.stepsToday);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
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
              Text(
                patient.displayName,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
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
              else
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
            ],
          ),
        ),
      ),
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
