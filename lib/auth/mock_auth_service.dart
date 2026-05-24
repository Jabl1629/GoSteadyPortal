import '../models/user.dart';
import 'auth_service_interface.dart';

/// Mock auth implementation used by the demo build (`BUILD_MODE=demo`).
///
/// Public surface mirrors [AuthService] so [AppShell] depends only on
/// the shared [AuthServiceInterface]. MFA / forgot-password methods
/// throw [UnsupportedError] in demo mode — the corresponding routes
/// are hidden by [AppRouter] when `BuildMode.isDemo`.
///
/// Per phase-2b-0-foundation.md L5. Previously known as
/// `FacilityMockAuthService` in `lib/facility_demo/services/`.
class MockAuthService extends AuthServiceInterface {
  MockAuthService._();
  static final MockAuthService instance = MockAuthService._();

  GoSteadyUser? _user;

  @override
  GoSteadyUser? get currentUser => _user;

  @override
  bool get isSignedIn => _user != null;

  @override
  Future<void> init() async {
    // Demo always starts logged out — investors should see the login
    // screen, not a pre-authenticated dashboard.
  }

  @override
  Future<GoSteadyUser> signIn(String email, String password) async {
    _user = const GoSteadyUser(
      userId: 'demo_user_dana',
      email: 'dana.chen@example.com',
      displayName: 'Dana Chen',
      role: UserRole.facilityAdmin,
      clientId: 'demo_client_001',
      facilities: [],
      censuses: [],
      mfaEnrolled: true,
    );
    notifyListeners();
    return _user!;
  }

  @override
  Future<GoSteadyUser> completeMfaChallenge(String code) {
    throw UnsupportedError('MFA challenge not used in demo mode.');
  }

  @override
  Future<MfaEnrollmentChallenge> enrollMfa() {
    throw UnsupportedError('MFA enrollment not used in demo mode.');
  }

  @override
  Future<void> verifyMfaEnrollment(String code) {
    throw UnsupportedError('MFA enrollment not used in demo mode.');
  }

  @override
  Future<void> forgotPassword(String email) {
    throw UnsupportedError('Forgot-password not used in demo mode.');
  }

  @override
  Future<void> confirmForgotPassword(
    String email,
    String code,
    String newPassword,
  ) {
    throw UnsupportedError('Forgot-password not used in demo mode.');
  }

  @override
  Future<void> signOut() async {
    if (_user == null) return;
    _user = null;
    notifyListeners();
  }

  @override
  Future<String?> getIdToken() async {
    // Demo has no real JWT — return null so any accidental ApiClient
    // call in demo mode fails clearly (caller should use FacilityMockData,
    // not ApiClient, in demo mode).
    return null;
  }
}
