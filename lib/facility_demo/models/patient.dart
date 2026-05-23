enum PatientStatus { active, discharged }

/// A walker user being monitored. Patient-centric model matches the
/// architecture's Phase 0B-rev decision to make Activity Series and Alert
/// History patient-keyed (not device-keyed) — history follows the patient
/// across device reassignments.
class Patient {
  final String id;
  final String displayName;
  final String facilityId;
  final String unitId; // -> Census id
  final String room;
  final String? deviceSerial;
  final PatientStatus status;

  const Patient({
    required this.id,
    required this.displayName,
    required this.facilityId,
    required this.unitId,
    required this.room,
    this.deviceSerial,
    this.status = PatientStatus.active,
  });
}

/// What renders on a Patient Census tile — the bare summary fields, no
/// charts. Materialized server-side in the eventual API; built from the
/// patient + the day's activity row in the mock layer.
class PatientSummary {
  final Patient patient;
  final int stepsToday;
  final int activeMinutesToday;
  final bool hasDataToday;

  const PatientSummary({
    required this.patient,
    required this.stepsToday,
    required this.activeMinutesToday,
    required this.hasDataToday,
  });
}
