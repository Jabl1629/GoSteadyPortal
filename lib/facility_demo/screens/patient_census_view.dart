import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../data/facility_mock_data.dart';
import '../models/patient.dart';
import '../state/facility_selection.dart';
import '../widgets/patient_tile.dart';

/// Left/main pane of the facility shell. Renders one tile per patient
/// matching the current unit selection. Click a tile -> sets the
/// FacilitySelection.selectedPatientId, which triggers the right pane.
class PatientCensusView extends StatelessWidget {
  const PatientCensusView({
    super.key,
    required this.data,
    required this.selection,
  });

  final FacilityMockData data;
  final FacilitySelection selection;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: selection,
      builder: (context, _) {
        final summaries = data.patientsForSelection(selection.selectedUnitIds);
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(28, 28, 28, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Header(count: summaries.length),
              const SizedBox(height: 18),
              if (summaries.isEmpty)
                const _EmptyState()
              else
                _Grid(summaries: summaries, data: data, selection: selection),
            ],
          ),
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          'Patient Census',
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontSize: 24,
                fontWeight: FontWeight.w600,
              ),
        ),
        const SizedBox(width: 12),
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            count == 1 ? '1 resident' : '$count residents',
            style: const TextStyle(
              color: AppTheme.textSoft,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }
}

class _Grid extends StatelessWidget {
  const _Grid({
    required this.summaries,
    required this.data,
    required this.selection,
  });

  final List<PatientSummary> summaries;
  final FacilityMockData data;
  final FacilitySelection selection;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Tile target width ~260; figure column count.
        const tileMinWidth = 260.0;
        const gap = 14.0;
        final cols = ((constraints.maxWidth + gap) / (tileMinWidth + gap))
            .floor()
            .clamp(1, 4);
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final s in summaries)
              SizedBox(
                width: (constraints.maxWidth - gap * (cols - 1)) / cols,
                child: PatientTile(
                  summary: s,
                  unitDisplay: unitDisplayFor(data, s.patient.unitId),
                  selected:
                      selection.selectedPatientId == s.patient.id,
                  onTap: () => selection.selectPatient(s.patient.id),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 64),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.people_outline_rounded,
              size: 48,
              color: AppTheme.textSoft.withOpacity(0.4),
            ),
            const SizedBox(height: 14),
            Text(
              'No units selected',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontSize: 17,
                  ),
            ),
            const SizedBox(height: 6),
            Text(
              'Choose at least one unit from the dropdown above\nto view residents.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppTheme.textSoft,
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
