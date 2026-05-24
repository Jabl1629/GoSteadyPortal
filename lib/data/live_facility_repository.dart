import '../api/api_client.dart';
import '../facility_demo/data/facility_mock_data.dart' show PatientRowStats;
import '../facility_demo/data/notification_engine.dart';
import '../facility_demo/models/facility.dart';
import '../facility_demo/models/patient.dart';
import '../facility_demo/models/unit.dart';
import '../models/activity.dart';
import '../models/device.dart';
import 'facility_repository.dart';

/// `ApiClient`-backed implementation of [FacilityRepository].
///
/// **2B-0 ships this as stubs that throw [UnimplementedError]** —
/// 2B-FAC-R fills in each method with cache-then-return behavior
/// (per-screen loading pattern + explicit refresh discipline).
///
/// Per phase-2b-0-foundation.md L3 + spec deviation note in
/// [FacilityRepository] (sync interface chosen over async-cascade).
class LiveFacilityRepository implements FacilityRepository {
  // ignore: unused_field
  final ApiClient _api;

  LiveFacilityRepository({required ApiClient api}) : _api = api;

  @override
  List<Facility> allFacilities() =>
      throw UnimplementedError('Wiring in 2B-FAC-R (cache from /me/patients)');

  @override
  List<Unit> unitsForFacility(String facilityId) =>
      throw UnimplementedError('Wiring in 2B-FAC-R');

  @override
  List<Unit> allUnits() =>
      throw UnimplementedError('Wiring in 2B-FAC-R');

  @override
  List<PatientSummary> patientsForSelection(Set<String> selectedUnitIds) =>
      throw UnimplementedError('Wiring in 2B-FAC-R (GET /me/patients)');

  @override
  Patient patientById(String patientId) =>
      throw UnimplementedError('Wiring in 2B-FAC-R (GET /patients/{id})');

  @override
  DailyActivity todayFor(String patientId) => throw UnimplementedError(
      'Wiring in 2B-FAC-R (GET /patients/{id}/activity?range=24h)');

  @override
  List<DailyActivity> last7DaysFor(String patientId) => throw UnimplementedError(
      'Wiring in 2B-FAC-R (GET /patients/{id}/activity?range=7d)');

  @override
  List<DailyActivity> last30DaysFor(String patientId) =>
      throw UnimplementedError(
          'Wiring in 2B-FAC-R (GET /patients/{id}/activity?range=30d)');

  @override
  List<WeeklyActivity> last6MonthsFor(String patientId) =>
      throw UnimplementedError(
          'Wiring in 2B-FAC-R (6M view requires Phase 1C rollup; disabled per umbrella L8)');

  @override
  DeviceHealth deviceFor(String patientId) =>
      throw UnimplementedError('Wiring in 2B-FAC-R (GET /devices/{serial})');

  @override
  NotificationContext notificationContextFor(String patientId) =>
      throw UnimplementedError(
          'Wiring in 2B-FAC-R (gated on Phase 1C-slim behavioral detector)');

  @override
  PatientRowStats rowStatsFor(String patientId) => throw UnimplementedError(
      'Wiring in 2B-FAC-R (assembled from /me/patients + /activity?range=7d)');
}
