import '../facility_demo/data/facility_mock_data.dart' show PatientRowStats;
import '../facility_demo/data/notification_engine.dart';
import '../facility_demo/models/facility.dart';
import '../facility_demo/models/patient.dart';
import '../facility_demo/models/unit.dart';
import '../models/activity.dart';
import '../models/device.dart';

/// Data abstraction consumed by every facility-tier screen.
///
/// Two implementations:
///   - [FacilityMockData] (lib/facility_demo/data/facility_mock_data.dart)
///     — seed-driven, used by the marketing demo build
///     (`BUILD_MODE=demo`)
///   - [LiveFacilityRepository] (lib/data/live_facility_repository.dart)
///     — `ApiClient`-backed, used by the live portal build
///     (`BUILD_MODE=live`)
///
/// **Hybrid sync/async per phase-2b-fac-r-facility-reads.md L2:**
/// Census-level lookups (Facility / Unit / PatientSummary) stay
/// **synchronous** — the live impl caches the `/me/patients` response
/// at shell init via [primeAtSignIn] and serves these synchronously
/// from cache. Per-patient methods are **async** so the live impl can
/// fetch + cache per-patient detail on demand.
abstract class FacilityRepository {
  // ── Lifecycle (added in 2B-FAC-R) ────────────────────────────

  /// Called after sign-in. Live impl fetches all pages of /me/patients
  /// and primes its in-memory caches; mock impl is a no-op.
  Future<void> primeAtSignIn();

  /// Force a Census refresh. Live impl refetches page 1 of
  /// /me/patients (per L13); mock impl is a no-op.
  Future<void> refreshCensus();

  /// Force a Patient Detail refresh. Live impl re-fetches the 3
  /// detail endpoints in parallel and replaces the cache; mock impl
  /// is a no-op.
  Future<void> refreshPatientDetail(String patientId);

  /// Drop all cached state. Called on sign-out so the next user
  /// starts fresh.
  void clearOnSignOut();

  // ── Census-level (sync; backed by cache in live impl) ────────

  List<Facility> allFacilities();

  List<Unit> unitsForFacility(String facilityId);

  /// All units across all facilities (helper for the selector dropdown).
  List<Unit> allUnits();

  /// All patient summaries whose unit is in [selectedUnitIds]. Empty
  /// set returns no patients (UI default is "all selected").
  List<PatientSummary> patientsForSelection(Set<String> selectedUnitIds);

  // ── Per-patient (async — cache + fetch on miss in live impl) ─

  /// Lookup a single patient.
  Future<Patient> patientById(String patientId);

  Future<DailyActivity> todayFor(String patientId);

  /// 7 days of history, oldest-first.
  Future<List<DailyActivity>> last7DaysFor(String patientId);

  /// 30 days of history, oldest-first.
  Future<List<DailyActivity>> last30DaysFor(String patientId);

  /// 26 weeks of history, oldest-first.
  ///
  /// Live build hides the 6M tab per phase-2b-fac-r L4; demo build
  /// continues to render this from seeded weekly data.
  Future<List<WeeklyActivity>> last6MonthsFor(String patientId);

  Future<DeviceHealth> deviceFor(String patientId);

  /// Snapshot the demo's notification engine evaluates against.
  /// Live impl returns a context derived from the cached /me/patients
  /// + /alerts response (per phase-2b-fac-r L6 — the live build
  /// renders alertType-mapped badges directly, bypassing this engine
  /// at the screen level; this method is retained for compatibility).
  Future<NotificationContext> notificationContextFor(String patientId);

  /// All stats the list-view table needs for one patient.
  Future<PatientRowStats> rowStatsFor(String patientId);
}
