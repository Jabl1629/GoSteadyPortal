import 'package:amazon_cognito_identity_dart_2/cognito.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/cognito_config.dart';
import '../models/user.dart';
import 'auth_service_interface.dart';
import 'user_claims.dart';

/// Cognito-backed implementation of [AuthServiceInterface].
///
/// Singleton; lives at `AuthService.instance`. Used by the live build
/// (`BUILD_MODE=live`). The demo build uses [MockAuthService] instead.
///
/// Per phase-2b-0-foundation.md L4 + L8.
class AuthService extends AuthServiceInterface {
  AuthService._();
  static final AuthService instance = AuthService._();

  late final CognitoUserPool _pool;
  CognitoUser? _cognitoUser;
  CognitoUserSession? _session;
  GoSteadyUser? _currentUser;

  /// Set after [signIn] returns an MFA challenge — held until
  /// [completeMfaChallenge] consumes it.
  CognitoUser? _pendingMfaUser;

  @override
  GoSteadyUser? get currentUser => _currentUser;

  @override
  bool get isSignedIn => _session?.isValid() == true && _currentUser != null;

  // ── Lifecycle ─────────────────────────────────────────────────

  @override
  Future<void> init() async {
    _pool = CognitoUserPool(
      CognitoConfig.userPoolId,
      CognitoConfig.clientId,
    );
    await _tryRestoreSession();
  }

  // ── Sign in (with MFA branch) ─────────────────────────────────

  @override
  Future<GoSteadyUser> signIn(String email, String password) async {
    _cognitoUser = CognitoUser(email, _pool);
    // Switch from SRP_AUTH (default) to USER_PASSWORD_AUTH — SRP via
    // Web Crypto API has been unreliable on Flutter Web in our testing
    // (CognitoNotAuthorizedException despite correct credentials).
    // USER_PASSWORD_AUTH sends the password over HTTPS to Cognito;
    // safe for a customer-facing browser flow. The Portal-Customer App
    // Client has ALLOW_USER_PASSWORD_AUTH enabled per Phase 0A-rev.
    _cognitoUser!.setAuthenticationFlowType('USER_PASSWORD_AUTH');

    final authDetails = AuthenticationDetails(
      username: email,
      password: password,
    );

    try {
      _session = await _cognitoUser!.authenticateUser(authDetails);
    } on CognitoUserMfaRequiredException {
      // Hold the cognitoUser; caller routes UI to /mfa-verify.
      _pendingMfaUser = _cognitoUser;
      throw MfaChallengeRequired(email);
    } on CognitoUserNewPasswordRequiredException {
      throw const AuthException('Password change required. Contact support.');
    } on CognitoUserCustomChallengeException {
      throw const AuthException('Custom challenge not supported.');
    } on CognitoClientException catch (e) {
      throw AuthException(_friendlyMessage(e.code, e.message));
    } on CognitoUserConfirmationNecessaryException {
      throw const AuthException('Please verify your email first.');
    } catch (e) {
      throw AuthException(e.toString());
    }

    if (_session == null || !_session!.isValid()) {
      throw const AuthException('Sign-in failed. Please try again.');
    }

    _currentUser = _extractUser(_session!);
    await _persistSession();
    notifyListeners();
    return _currentUser!;
  }

  @override
  Future<GoSteadyUser> completeMfaChallenge(String code) async {
    final user = _pendingMfaUser;
    if (user == null) {
      throw const AuthException('No MFA challenge in progress.');
    }

    try {
      _session = await user.sendMFACode(code, 'SOFTWARE_TOKEN_MFA');
    } on CognitoClientException catch (e) {
      throw AuthException(_friendlyMessage(e.code, e.message));
    } catch (e) {
      throw AuthException(e.toString());
    }

    if (_session == null || !_session!.isValid()) {
      throw const AuthException('MFA verification failed.');
    }

    _cognitoUser = user;
    _pendingMfaUser = null;
    _currentUser = _extractUser(_session!);
    await _persistSession();
    notifyListeners();
    return _currentUser!;
  }

  // ── MFA enrollment ────────────────────────────────────────────

  @override
  Future<MfaEnrollmentChallenge> enrollMfa() async {
    final user = _cognitoUser;
    if (user == null) {
      throw const AuthException('Sign in before enrolling MFA.');
    }

    try {
      final secret = await user.associateSoftwareToken();
      if (secret == null || secret.isEmpty) {
        throw const AuthException('Failed to start MFA enrollment.');
      }
      final email = _currentUser?.email ?? 'user';
      final otpauthUri =
          'otpauth://totp/GoSteady:$email?secret=$secret&issuer=GoSteady';
      return MfaEnrollmentChallenge(secret: secret, otpauthUri: otpauthUri);
    } on CognitoClientException catch (e) {
      throw AuthException(_friendlyMessage(e.code, e.message));
    } catch (e) {
      throw AuthException(e.toString());
    }
  }

  @override
  Future<void> verifyMfaEnrollment(String code) async {
    final user = _cognitoUser;
    if (user == null) {
      throw const AuthException('Sign in before verifying MFA.');
    }

    try {
      final ok = await user.verifySoftwareToken(totpCode: code);
      if (ok != true) {
        throw const AuthException('Incorrect code. Try again.');
      }
      // Make TOTP the preferred MFA method for this user.
      await user.setUserMfaPreference(
        IMfaSettings(preferredMfa: false, enabled: false),
        IMfaSettings(preferredMfa: true, enabled: true),
      );
    } on CognitoClientException catch (e) {
      throw AuthException(_friendlyMessage(e.code, e.message));
    } on AuthException {
      rethrow;
    } catch (e) {
      throw AuthException(e.toString());
    }
  }

  // ── Forgot password ──────────────────────────────────────────

  @override
  Future<void> forgotPassword(String email) async {
    final user = CognitoUser(email, _pool);
    try {
      await user.forgotPassword();
    } on CognitoClientException catch (e) {
      throw AuthException(_friendlyMessage(e.code, e.message));
    } catch (e) {
      throw AuthException(e.toString());
    }
  }

  @override
  Future<void> confirmForgotPassword(
    String email,
    String code,
    String newPassword,
  ) async {
    final user = CognitoUser(email, _pool);
    try {
      final ok = await user.confirmPassword(code, newPassword);
      if (ok != true) {
        throw const AuthException('Password reset failed. Try again.');
      }
    } on CognitoClientException catch (e) {
      throw AuthException(_friendlyMessage(e.code, e.message));
    } on AuthException {
      rethrow;
    } catch (e) {
      throw AuthException(e.toString());
    }
  }

  // ── Sign out ─────────────────────────────────────────────────

  @override
  Future<void> signOut() async {
    if (_cognitoUser != null) {
      try {
        await _cognitoUser!.signOut();
      } catch (_) {
        // Best-effort — clear local state regardless.
      }
    }
    _session = null;
    _currentUser = null;
    _cognitoUser = null;
    _pendingMfaUser = null;
    await _clearPersistedSession();
    notifyListeners();
  }

  // ── Token access (60s refresh buffer per L8) ─────────────────

  @override
  Future<String?> getIdToken() async {
    if (_session == null || _cognitoUser == null) return null;

    // Opportunistic refresh if within 60 s of expiry.
    final idToken = _session!.getIdToken();
    final expSec = idToken.getExpiration();
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final needsRefresh = !_session!.isValid() || (expSec - nowSec) < 60;

    if (needsRefresh) {
      try {
        _session = await _cognitoUser!.getSession();
        if (_session?.isValid() != true) {
          await signOut();
          return null;
        }
        _currentUser = _extractUser(_session!);
        await _persistSession();
        notifyListeners();
      } catch (_) {
        await signOut();
        return null;
      }
    }
    return _session!.getIdToken().getJwtToken();
  }

  // ── Internals ────────────────────────────────────────────────

  GoSteadyUser _extractUser(CognitoUserSession session) {
    final idToken = session.getIdToken();
    return UserClaims.parse(idToken.payload);
  }

  Future<void> _tryRestoreSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final email = prefs.getString('gs_auth_email');
      if (email == null) return;

      _cognitoUser = CognitoUser(email, _pool);
      _session = await _cognitoUser!.getSession();

      if (_session?.isValid() == true) {
        _currentUser = _extractUser(_session!);
        notifyListeners();
      } else {
        await _clearPersistedSession();
      }
    } catch (_) {
      await _clearPersistedSession();
    }
  }

  Future<void> _persistSession() async {
    if (_currentUser == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('gs_auth_email', _currentUser!.email);
  }

  Future<void> _clearPersistedSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('gs_auth_email');
  }

  String _friendlyMessage(String? code, String? message) {
    switch (code) {
      case 'NotAuthorizedException':
        return 'Incorrect email or password.';
      case 'UserNotFoundException':
        return 'No account found with that email.';
      case 'UserNotConfirmedException':
        return 'Please verify your email first.';
      case 'CodeMismatchException':
        return 'Incorrect code. Try again.';
      case 'ExpiredCodeException':
        return 'Code expired. Request a new one.';
      case 'InvalidPasswordException':
        return 'Password must be at least 14 characters with uppercase, lowercase, a number, and a symbol.';
      case 'TooManyRequestsException':
      case 'LimitExceededException':
        return 'Too many attempts. Please wait a moment and try again.';
      case 'InvalidParameterException':
        return 'Please check your input and try again.';
      default:
        return message ?? 'Something went wrong. Please try again.';
    }
  }
}
