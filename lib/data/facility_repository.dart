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
/// Per phase-2b-0-foundation.md L3 — with the deviation noted below.
///
/// **Deviation from spec's §Interfaces (2026-05-24):** the spec called
/// for `Future<...>`-returning methods. In practice, converting the
/// existing demo screens to await/FutureBuilder wrappers is a much
/// larger change than 2B-0 foundation should carry (~25 call sites in
/// 8 files; cascades through `FacilitySelection` ChangeNotifier and
/// every screen `build()`). Keeping the interface synchronous matches
/// the demo verbatim and defers the async-loading question to
/// 2B-FAC-R, which will design a cache + `refresh()` discipline for
/// the live impl appropriate to each screen's loading pattern. 2B-0
/// ships [LiveFacilityRepository] as stubs that throw
/// `UnimplementedError`; 2B-FAC-R fills them with cache-then-return
/// behavior.
abstract class FacilityRepository {
  // ── Facility / Unit / Patient lookups ─────────────────────────

  List<Facility> allFacilities();

  List<Unit> unitsForFacility(String facilityId);

  /// All units across all facilities (helper for the selector dropdown).
  List<Unit> allUnits();

  /// All patient summaries whose unit is in [selectedUnitIds]. Empty
  /// set returns no patients (UI default is "all selected").
  List<PatientSummary> patientsForSelection(Set<String> selectedUnitIds);

  /// Lookup a single patient.
  Patient patientById(String patientId);

  // ── Detail-panel data (one patient) ───────────────────────────

  DailyActivity todayFor(String patientId);

  /// 7 days of history, oldest-first.
  List<DailyActivity> last7DaysFor(String patientId);

  /// 30 days of history, oldest-first.
  List<DailyActivity> last30DaysFor(String patientId);

  /// 26 weeks of history, oldest-first.
  List<WeeklyActivity> last6MonthsFor(String patientId);

  DeviceHealth deviceFor(String patientId);

  /// Snapshot the demo's notification engine evaluates against (today's
  /// activity + recent baselines). Live impl will populate this from
  /// server-side rule output once Phase 1C-slim ships.
  NotificationContext notificationContextFor(String patientId);

  /// All stats the list-view table needs for one patient.
  PatientRowStats rowStatsFor(String patientId);
}
