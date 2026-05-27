import '../api/api_models.dart' as api;
import '../facility_demo/data/facility_mock_data.dart' show PatientRowStats;
import '../facility_demo/data/notification_engine.dart';
import '../facility_demo/models/facility.dart';
import '../facility_demo/models/notification.dart';
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

  /// Active (unacknowledged) notifications for the patient.
  ///
  /// - **Demo impl:** evaluates the three local rules in
  ///   [NotificationEngine] against [notificationContextFor].
  /// - **Live impl:** reads the cached `/alerts?status=unacknowledged`
  ///   response and maps each `alertType` to a [NotificationType] via
  ///   the spec's L6 mapping table. The live build bypasses
  ///   [NotificationEngine] entirely — server is the source of truth.
  ///
  /// Per phase-2b-fac-r-facility-reads.md L6.
  Future<List<PatientNotification>> notificationsFor(String patientId);

  /// All stats the list-view table needs for one patient.
  Future<PatientRowStats> rowStatsFor(String patientId);

  // ── Writes (2B-FAC-W) ─────────────────────────────────────────
  //
  // Live impl delegates to ApiClient + evicts the relevant caches on
  // success. Demo impl mutates the in-memory mock state so the
  // marketing demo's interactivity stays correct without going
  // out-of-network. Per phase-2b-fac-w-facility-writes.md L2 + L3.

  /// `PATCH /alerts/{patientId}/{sk}` — caregiver acknowledges an
  /// open alert. Live impl also evicts the alerts cache so the
  /// Notification Review panel re-renders without the acked row.
  Future<api.AckAlertResponse> ackAlert({
    required String patientId,
    required String sk,
    String? notes,
  });

  /// `POST /patients` — add a new resident. When [deviceSerial] is
  /// present, the server atomically provisions the device (per
  /// 2A-UM-P L3). Returns the new patient's full detail; live impl
  /// also refreshes `/me/patients`.
  Future<api.PatientDetailResponse> createPatient({
    required String displayName,
    required String censusId,
    required String room,
    String? deviceSerial,
  });

  /// `PATCH /patients/{id}` — edit displayName / censusId / room.
  /// At least one must be non-null. Live impl evicts the per-patient
  /// detail cache and refreshes `/me/patients` (in case cross-facility
  /// transfer moved the row).
  Future<api.PatientDetailResponse> updatePatient({
    required String patientId,
    String? displayName,
    String? censusId,
    String? room,
  });

  /// `POST /patients/{id}/discharge` — flip Patient.status to
  /// discharged; the discharge-cascade Lambda fires async via DDB
  /// Streams. Returns the cascade snapshot at response-time. Live
  /// impl refreshes `/me/patients` so the now-discharged row drops
  /// out of the active census.
  Future<api.DischargeResponse> dischargePatient({
    required String patientId,
    required String reason,
    String? notes,
  });

  /// `POST /patients/{id}/notifications/pause` — pause for [days]
  /// (∈ [1,90]). Live impl refreshes the patient detail cache so
  /// the Pause Banner renders immediately.
  Future<api.NotificationsPauseResponse> pauseNotifications({
    required String patientId,
    required int days,
    required String reason,
  });

  /// `DELETE /patients/{id}/notifications/pause` — caregiver-driven
  /// resume. Live impl refreshes the patient detail cache.
  Future<api.NotificationsPauseResponse> resumeNotifications(String patientId);

  /// `PATCH /patients/{id}/care-note` — set or clear the free-text
  /// care note. Empty [text] clears. Live impl refreshes patient
  /// detail so the new text + attribution render immediately.
  Future<api.CareNoteResponse> updateCareNote({
    required String patientId,
    required String text,
  });
}
