import 'package:flutter/foundation.dart';

import '../data/facility_mock_data.dart';
import '../models/unit.dart';

enum FacilityCheckState { all, none, partial }

/// State for the facility/unit selector dropdown plus the currently
/// drilled-in patient. Single source of truth shared by the top bar,
/// census view, and detail view.
class FacilitySelection extends ChangeNotifier {
  FacilitySelection(this._data) : _selectedUnitIds = {} {
    // Default selection is "all units." Demo opens with everyone visible.
    _selectedUnitIds = _data.allUnits().map((u) => u.id).toSet();
  }

  final FacilityMockData _data;

  Set<String> _selectedUnitIds;
  String? _selectedPatientId;

  // ── Read ───────────────────────────────────────────────────────────────

  Set<String> get selectedUnitIds => _selectedUnitIds;
  String? get selectedPatientId => _selectedPatientId;

  bool isUnitSelected(String unitId) => _selectedUnitIds.contains(unitId);

  /// Tri-state for facility-level checkboxes.
  FacilityCheckState facilityCheckState(String facilityId) {
    final units = _data.unitsForFacility(facilityId);
    final checkedCount =
        units.where((u) => _selectedUnitIds.contains(u.id)).length;
    if (checkedCount == 0) return FacilityCheckState.none;
    if (checkedCount == units.length) return FacilityCheckState.all;
    return FacilityCheckState.partial;
  }

  /// Compact label for the dropdown trigger button.
  /// e.g. "All Units (10)", "Memory Care, AL East (5)", "Memory Care (3)"
  String selectorLabel() {
    final allUnits = _data.allUnits();
    final selectedUnits = allUnits
        .where((u) => _selectedUnitIds.contains(u.id))
        .toList(growable: false);
    final patientCount = _patientCountForSelection();

    if (selectedUnits.isEmpty) {
      return 'No units selected';
    }
    if (selectedUnits.length == allUnits.length) {
      return 'All Units ($patientCount)';
    }
    if (selectedUnits.length <= 2) {
      final names = selectedUnits.map(_shortUnitName).join(', ');
      return '$names ($patientCount)';
    }
    return '${selectedUnits.length} units · $patientCount res.';
  }

  int _patientCountForSelection() =>
      _data.patientsForSelection(_selectedUnitIds).length;

  static String _shortUnitName(Unit u) {
    // Strip facility-name prefixes commonly embedded in unit display names.
    // For our seed data, unit names are already concise ("Memory Care",
    // "Assisted Living — East"); short-form just shortens em-dash variants.
    return u.displayName.replaceAll('Assisted Living — ', 'AL ');
  }

  // ── Mutate ─────────────────────────────────────────────────────────────

  void toggleUnit(String unitId) {
    if (_selectedUnitIds.contains(unitId)) {
      _selectedUnitIds.remove(unitId);
    } else {
      _selectedUnitIds.add(unitId);
    }
    _ensurePatientStillVisible();
    notifyListeners();
  }

  void setFacilityChecked(String facilityId, bool checked) {
    final units = _data.unitsForFacility(facilityId);
    if (checked) {
      _selectedUnitIds.addAll(units.map((u) => u.id));
    } else {
      _selectedUnitIds.removeAll(units.map((u) => u.id));
    }
    _ensurePatientStillVisible();
    notifyListeners();
  }

  void selectAll() {
    _selectedUnitIds = _data.allUnits().map((u) => u.id).toSet();
    notifyListeners();
  }

  void clearAll() {
    _selectedUnitIds = {};
    _ensurePatientStillVisible();
    notifyListeners();
  }

  // ── Patient drill-down ─────────────────────────────────────────────────

  void selectPatient(String patientId) {
    if (_selectedPatientId == patientId) return;
    _selectedPatientId = patientId;
    notifyListeners();
  }

  void clearPatient() {
    if (_selectedPatientId == null) return;
    _selectedPatientId = null;
    notifyListeners();
  }

  /// If the currently-selected patient is no longer visible after a unit
  /// filter change, deselect them so the right pane returns to empty state.
  void _ensurePatientStillVisible() {
    final selectedId = _selectedPatientId;
    if (selectedId == null) return;
    final visible =
        _data.patientsForSelection(_selectedUnitIds).any((s) => s.patient.id == selectedId);
    if (!visible) {
      _selectedPatientId = null;
    }
  }
}
