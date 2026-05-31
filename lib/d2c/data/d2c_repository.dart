import '../../api/d2c_api_models.dart';
import 'd2c_mock_data.dart';

/// Data gateway for the D2C consumer portal. The screens in `lib/d2c/`
/// depend only on this abstraction so the demo build (mock) and the live
/// build (API-backed) share one widget tree — mirrors the facility
/// `FacilityRepository` split.
///
/// Phase 1 covers the **monitoring loop only**: QR landing → claim →
/// dashboard + history. Care Circle (Phase 5), notification prefs
/// (Phase 2), and the customer audit log have no Phase-1 backend, so
/// those screens stay on [D2CMockData] directly (or are hidden in the
/// live build) until their endpoints ship. See d2c.md §4/§5.
abstract class D2CRepository {
  /// `GET /public/walkers/{walkerId}` — unauthenticated QR-landing lookup.
  Future<PublicWalkerLookup> lookupWalker(String walkerId);

  /// `POST /claim` — bootstrap household + patient then provision the
  /// device. Authenticated with the just-signed-up walker user's JWT.
  Future<ClaimResponse> claim(String walkerId, {String? displayName});

  /// The patientId of this household's walker, or null if nothing is
  /// claimed yet. V1: one household = one patient (`/me/patients` → first).
  Future<String?> myWalkerPatientId();

  /// The bundled dashboard snapshot for [patientId] (detail + today's +
  /// 7-day activity + open alerts), shaped for [D2CDashboardScreen].
  Future<D2CDashboardSnapshot> dashboard(String patientId);

  /// Daily history for the 30/90-day History view.
  Future<List<HistoryDay>> history(String patientId, {required int days});
}

/// Mock repository for the demo build — delegates to the static
/// [D2CMockData] wireframe seeds. Ignores [patientId] (one mock household).
class D2CMockRepository implements D2CRepository {
  const D2CMockRepository();

  @override
  Future<PublicWalkerLookup> lookupWalker(String walkerId) async =>
      const PublicWalkerLookup(status: PublicWalkerStatus.unclaimed);

  @override
  Future<ClaimResponse> claim(String walkerId, {String? displayName}) async =>
      ClaimResponse(
        patient: ClaimedPatient(
          patientId: 'pat_d2c_susan',
          displayName: displayName ?? 'Susan Davis',
          status: 'active',
          clientId: 'dtc_mock',
          isWalkerUser: true,
        ),
        alreadyClaimed: false,
      );

  @override
  Future<String?> myWalkerPatientId() async => 'pat_d2c_susan';

  @override
  Future<D2CDashboardSnapshot> dashboard(String patientId) async =>
      D2CMockData.susanViewedBySarah();

  @override
  Future<List<HistoryDay>> history(
    String patientId, {
    required int days,
  }) async =>
      D2CMockData.history(days: days);
}
