import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../data/facility_mock_data.dart';
import '../data/notification_engine.dart';
import '../models/notification.dart';
import '../models/patient.dart';
import '../state/facility_selection.dart';
import '../state/notification_state.dart';
import '../widgets/patient_list_view.dart';
import '../widgets/patient_tile.dart';
import '../widgets/simple_select_dropdown.dart';
import '../widgets/view_mode_toggle.dart';

/// Left/main pane of the facility shell. Renders one tile per patient
/// matching the current unit selection, sort, and filter. Click a tile ->
/// sets FacilitySelection.selectedPatientId, triggering the overlay.
class PatientCensusView extends StatelessWidget {
  const PatientCensusView({
    super.key,
    required this.data,
    required this.selection,
    required this.notifications,
  });

  final FacilityMockData data;
  final FacilitySelection selection;
  final NotificationState notifications;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([selection, notifications]),
      builder: (context, _) {
        final summaries = data.patientsForSelection(selection.selectedUnitIds);
        final rows = summaries.map((s) {
          final computed = notificationsForPatient(data, s.patient.id);
          final active = notifications.activeOf(computed);
          return _CensusRow(summary: s, active: active);
        }).toList();

        final filtered = _applyFilter(rows, selection.filterMode);
        _applySort(filtered, selection.sortMode);

        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(28, 28, 28, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Header(
                totalShown: filtered.length,
                totalSelected: summaries.length,
                selection: selection,
              ),
              const SizedBox(height: 18),
              if (filtered.isEmpty)
                _EmptyState(filterMode: selection.filterMode)
              else if (selection.viewMode == CensusViewMode.list)
                PatientListView(
                  rows: filtered
                      .map((r) => PatientListRow(
                            patient: r.summary.patient,
                            unitDisplay:
                                unitDisplayFor(data, r.summary.patient.unitId),
                            stats: data.rowStatsFor(r.summary.patient.id),
                            activeNotifications: r.active,
                          ))
                      .toList(),
                  selectedPatientId: selection.selectedPatientId,
                  onSelect: selection.selectPatient,
                )
              else
                _Grid(
                  rows: filtered,
                  data: data,
                  selection: selection,
                ),
            ],
          ),
        );
      },
    );
  }

  static List<_CensusRow> _applyFilter(
    List<_CensusRow> rows,
    CensusFilterMode mode,
  ) {
    switch (mode) {
      case CensusFilterMode.all:
        return rows;
      case CensusFilterMode.withNotifications:
        return rows.where((r) => r.active.isNotEmpty).toList();
      case CensusFilterMode.criticalOnly:
        return rows
            .where((r) => r.active
                .any((n) => n.severity == NotificationSeverity.critical))
            .toList();
      case CensusFilterMode.noNotifications:
        return rows.where((r) => r.active.isEmpty).toList();
    }
  }

  static void _applySort(List<_CensusRow> rows, CensusSortMode mode) {
    int byName(_CensusRow a, _CensusRow b) =>
        a.summary.patient.displayName.compareTo(b.summary.patient.displayName);

    int severityRank(_CensusRow r) {
      if (r.active.any((n) => n.severity == NotificationSeverity.critical)) {
        return 0;
      }
      if (r.active.isNotEmpty) return 1;
      return 2;
    }

    switch (mode) {
      case CensusSortMode.notificationsFirst:
        rows.sort((a, b) {
          final r = severityRank(a).compareTo(severityRank(b));
          return r != 0 ? r : byName(a, b);
        });
      case CensusSortMode.nameAZ:
        rows.sort(byName);
      case CensusSortMode.mostActive:
        rows.sort(
            (a, b) => b.summary.stepsToday.compareTo(a.summary.stepsToday));
      case CensusSortMode.leastActive:
        rows.sort(
            (a, b) => a.summary.stepsToday.compareTo(b.summary.stepsToday));
    }
  }
}

class _CensusRow {
  final PatientSummary summary;
  final List<PatientNotification> active;
  _CensusRow({required this.summary, required this.active});
}

class _Header extends StatelessWidget {
  const _Header({
    required this.totalShown,
    required this.totalSelected,
    required this.selection,
  });

  final int totalShown;
  final int totalSelected;
  final FacilitySelection selection;

  String _countLabel() {
    if (totalShown == totalSelected) {
      return totalShown == 1 ? '1 resident' : '$totalShown residents';
    }
    return '$totalShown of $totalSelected residents';
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      runSpacing: 12,
      spacing: 16,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
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
                _countLabel(),
                style: const TextStyle(
                  color: AppTheme.textSoft,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: ViewModeToggle(
                selected: selection.viewMode,
                onChanged: selection.setViewMode,
              ),
            ),
          ],
        ),
        const SizedBox(width: 8),
        SimpleSelectDropdown<CensusSortMode>(
          label: 'Sort',
          icon: Icons.sort_rounded,
          options: CensusSortMode.values,
          value: selection.sortMode,
          optionLabel: (m) => m.label,
          onChanged: selection.setSortMode,
        ),
        SimpleSelectDropdown<CensusFilterMode>(
          label: 'Filter',
          icon: Icons.filter_list_rounded,
          options: CensusFilterMode.values,
          value: selection.filterMode,
          optionLabel: (m) => m.label,
          onChanged: selection.setFilterMode,
        ),
      ],
    );
  }
}

class _Grid extends StatelessWidget {
  const _Grid({
    required this.rows,
    required this.data,
    required this.selection,
  });

  final List<_CensusRow> rows;
  final FacilityMockData data;
  final FacilitySelection selection;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const tileMinWidth = 260.0;
        const gap = 14.0;
        final cols = ((constraints.maxWidth + gap) / (tileMinWidth + gap))
            .floor()
            .clamp(1, 5);
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final r in rows)
              SizedBox(
                width: (constraints.maxWidth - gap * (cols - 1)) / cols,
                child: PatientTile(
                  summary: r.summary,
                  unitDisplay: unitDisplayFor(data, r.summary.patient.unitId),
                  selected: selection.selectedPatientId == r.summary.patient.id,
                  onTap: () => selection.selectPatient(r.summary.patient.id),
                  activeNotifications: r.active,
                ),
              ),
          ],
        );
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.filterMode});
  final CensusFilterMode filterMode;

  @override
  Widget build(BuildContext context) {
    final (icon, title, body) = switch (filterMode) {
      CensusFilterMode.all => (
          Icons.people_outline_rounded,
          'No units selected',
          'Choose at least one unit from the dropdown above\nto view residents.',
        ),
      CensusFilterMode.withNotifications => (
          Icons.check_circle_outline_rounded,
          'No notifications',
          'No residents in the current selection need review.',
        ),
      CensusFilterMode.criticalOnly => (
          Icons.check_circle_outline_rounded,
          'No critical alerts',
          'No residents in the current selection have critical notifications.',
        ),
      CensusFilterMode.noNotifications => (
          Icons.notifications_active_outlined,
          'All residents have notifications',
          'Every resident in the current selection currently has at least one\nnotification awaiting review.',
        ),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 64),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: AppTheme.textSoft.withOpacity(0.4)),
            const SizedBox(height: 14),
            Text(
              title,
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontSize: 17),
            ),
            const SizedBox(height: 6),
            Text(
              body,
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
