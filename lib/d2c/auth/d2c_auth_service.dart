import 'dart:math';

import 'package:amazon_cognito_identity_dart_2/cognito.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../auth/auth_service_interface.dart';
import '../../auth/user_claims.dart';
import '../../config/d2c_cognito_config.dart';
import '../../models/user.dart';

/// Cognito-backed auth for the **D2C consumer pool** — a passwordless
/// SMS-OTP custom-auth flow (d2c-phase1 §3.1). Distinct from the
/// facility [AuthService] (email + password + TOTP-MFA): D2C never
/// collects a password from the user.
///
/// Implements [AuthServiceInterface] so the shared [ApiClient] (which
/// only needs [getIdToken]) is reused unchanged. The password / MFA
/// methods on the interface are not part of the D2C flow and throw
/// [UnsupportedError]; D2C uses the dedicated methods below instead:
///
///   1. [signUp]        — create the account (random throwaway password).
///   2. [confirmSignUp] — confirm via the EMAILED code (`autoVerify: email`
///                        on the pool means a fresh self-signup is
///                        UNCONFIRMED until this runs — d2c-auth-stack.ts).
///   3. [startSignIn]   — begin CUSTOM_AUTH; Cognito SMS-OTPs the phone.
///   4. [submitOtp]     — answer the challenge; on success, tokens issue.
///
/// > NOTE: end-to-end OTP *delivery* is gated on the operator populating
/// > the `gosteady/dev/twilio` secret (coord §C37.3). This client is built
/// > to the deployed contract; the live exit test runs once SMS is enabled.
class D2CAuthService extends AuthServiceInterface {
  D2CAuthService._();
  static final D2CAuthService instance = D2CAuthService._();

  static const _emailPrefsKey = 'gs_d2c_auth_email';

  late final CognitoUserPool _pool;
  CognitoUser? _cognitoUser;
  CognitoUserSession? _session;
  GoSteadyUser? _currentUser;

  /// The user mid-sign-in: held between [startSignIn] (challenge issued)
  /// and [submitOtp] (challenge answered).
  CognitoUser? _pendingSignInUser;
  String? _pendingSignInEmail;

  @override
  GoSteadyUser? get currentUser => _currentUser;

  @override
  bool get isSignedIn => _session?.isValid() == true && _currentUser != null;

  // ── Lifecycle ─────────────────────────────────────────────────

  @override
  Future<void> init() async {
    _pool = CognitoUserPool(
      D2CCognitoConfig.userPoolId,
      D2CCognitoConfig.clientId,
    );
    await _tryRestoreSession();
  }

  // ── D2C sign-up + confirm (email code) ────────────────────────

  /// Register a new walker user. `phone` is the SMS-OTP channel and is
  /// normalised to E.164 (`+1` prepended for a bare 10-digit US number).
  /// Returns whether the account is already confirmed — for this pool it
  /// is NOT (email confirmation required), so callers route to the
  /// confirm-code step.
  Future<D2CSignUpResult> signUp({
    required String name,
    required String email,
    required String phone,
  }) async {
    final normalizedEmail = email.trim().toLowerCase();
    try {
      final data = await _pool.signUp(
        normalizedEmail,
        _randomThrowawayPassword(),
        userAttributes: [
          AttributeArg(name: 'name', value: name.trim()),
          AttributeArg(name: 'email', value: normalizedEmail),
          AttributeArg(name: 'phone_number', value: _normalizePhone(phone)),
        ],
      );
      return D2CSignUpResult(confirmed: data.userConfirmed ?? false);
    } on CognitoClientException catch (e) {
      throw AuthException(_friendlyMessage(e.code, e.message));
    } catch (e) {
      throw AuthException(e.toString());
    }
  }

  /// Confirm a fresh sign-up with the code Cognito emailed (ConfirmSignUp).
  Future<void> confirmSignUp({
    required String email,
    required String code,
  }) async {
    final user = CognitoUser(email.trim().toLowerCase(), _pool);
    try {
      final ok = await user.confirmRegistration(code.trim());
      if (ok != true) {
        throw const AuthException('Confirmation failed. Try again.');
      }
    } on CognitoClientException catch (e) {
      throw AuthException(_friendlyMessage(e.code, e.message));
    } on AuthException {
      rethrow;
    } catch (e) {
      throw AuthException(e.toString());
    }
  }

  /// Re-send the sign-up confirmation (email) code.
  Future<void> resendSignUpCode(String email) async {
    final user = CognitoUser(email.trim().toLowerCase(), _pool);
    try {
      await user.resendConfirmationCode();
    } on CognitoClientException catch (e) {
      throw AuthException(_friendlyMessage(e.code, e.message));
    } catch (e) {
      throw AuthException(e.toString());
    }
  }

  // ── D2C sign-in: CUSTOM_AUTH SMS-OTP ──────────────────────────

  /// Begin sign-in for [email]. Triggers Cognito CUSTOM_AUTH, which fires
  /// the custom-auth Lambda → SMS-OTP to the phone on file. Returns the
  /// challenge (carrying the `phoneHint` the UI shows, e.g. "••34").
  /// Follow with [submitOtp].
  Future<D2COtpChallenge> startSignIn(String email) async {
    final normalizedEmail = email.trim().toLowerCase();
    final user = CognitoUser(normalizedEmail, _pool);
    try {
      // initiateAuth sends AuthFlow=CUSTOM_AUTH and throws the custom
      // challenge exception once the OTP is dispatched (expected path).
      final session = await user.initiateAuth(
        AuthenticationDetails(username: normalizedEmail, authParameters: []),
      );
      // Unreachable for this pool (a session without a challenge would
      // mean Cognito issued tokens with no factor) — treat as success.
      if (session != null && session.isValid()) {
        _adoptSession(user, session);
        return const D2COtpChallenge(phoneHint: '');
      }
      throw const AuthException('Could not start sign-in. Try again.');
    } on CognitoUserCustomChallengeException catch (e) {
      // Expected: OTP sent, awaiting the code.
      _pendingSignInUser = user;
      _pendingSignInEmail = normalizedEmail;
      return D2COtpChallenge(phoneHint: _phoneHintFrom(e.challengeParameters));
    } on CognitoClientException catch (e) {
      throw AuthException(_friendlyMessage(e.code, e.message));
    } on AuthException {
      rethrow;
    } catch (e) {
      throw AuthException(e.toString());
    }
  }

  /// Answer the SMS-OTP challenge. On success the session is established
  /// and the [GoSteadyUser] (with `dtc_*` claims) is returned. A wrong
  /// code re-issues the challenge (up to 3 attempts) — surfaced as an
  /// [AuthException] so the caller can let the user retry.
  Future<GoSteadyUser> submitOtp(String code) async {
    final user = _pendingSignInUser;
    if (user == null) {
      throw const AuthException('No sign-in in progress. Start again.');
    }
    try {
      final session = await user.sendCustomChallengeAnswer(code.trim());
      if (session == null || !session.isValid()) {
        throw const AuthException('Verification failed. Try again.');
      }
      _adoptSession(user, session);
      _pendingSignInUser = null;
      _pendingSignInEmail = null;
      await _persistSession();
      return _currentUser!;
    } on CognitoUserCustomChallengeException {
      // Wrong code — Cognito re-issued the challenge (the package already
      // refreshed the internal session, so the next submitOtp retries).
      throw const AuthException('Incorrect code. Try again.');
    } on CognitoClientException catch (e) {
      // After max attempts the pool fails the auth (NotAuthorizedException).
      _pendingSignInUser = null;
      throw AuthException(
        e.code == 'NotAuthorizedException'
            ? 'Too many incorrect attempts. Request a new code.'
            : _friendlyMessage(e.code, e.message),
      );
    } on AuthException {
      rethrow;
    } catch (e) {
      throw AuthException(e.toString());
    }
  }

  /// Re-send the SMS-OTP (restarts the challenge for the in-progress email).
  Future<D2COtpChallenge> resendOtp() async {
    final email = _pendingSignInEmail;
    if (email == null) {
      throw const AuthException('No sign-in in progress. Start again.');
    }
    return startSignIn(email);
  }

  // ── Token access (60s refresh buffer, mirrors facility L8) ─────

  @override
  Future<String?> getIdToken() async {
    if (_session == null || _cognitoUser == null) return null;

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

  // ── Sign out ──────────────────────────────────────────────────

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
    _pendingSignInUser = null;
    _pendingSignInEmail = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_emailPrefsKey);
    notifyListeners();
  }

  // ── Unsupported (facility password/MFA paths) ─────────────────

  @override
  Future<GoSteadyUser> signIn(String email, String password) =>
      throw UnsupportedError('D2C is passwordless — use startSignIn + submitOtp.');

  @override
  Future<GoSteadyUser> completeMfaChallenge(String code) =>
      throw UnsupportedError('D2C has no separate MFA step.');

  @override
  Future<MfaEnrollmentChallenge> enrollMfa() =>
      throw UnsupportedError('D2C has no MFA enrollment.');

  @override
  Future<void> verifyMfaEnrollment(String code) =>
      throw UnsupportedError('D2C has no MFA enrollment.');

  @override
  Future<void> forgotPassword(String email) =>
      throw UnsupportedError('D2C is passwordless — no password reset.');

  @override
  Future<void> confirmForgotPassword(
    String email,
    String code,
    String newPassword,
  ) =>
      throw UnsupportedError('D2C is passwordless — no password reset.');

  // ── Internals ─────────────────────────────────────────────────

  void _adoptSession(CognitoUser user, CognitoUserSession session) {
    _cognitoUser = user;
    _session = session;
    _currentUser = _extractUser(session);
    notifyListeners();
  }

  GoSteadyUser _extractUser(CognitoUserSession session) =>
      UserClaims.parse(session.getIdToken().payload);

  Future<void> _tryRestoreSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final email = prefs.getString(_emailPrefsKey);
      if (email == null) return;

      _cognitoUser = CognitoUser(email, _pool);
      _session = await _cognitoUser!.getSession();
      if (_session?.isValid() == true) {
        _currentUser = _extractUser(_session!);
        notifyListeners();
      } else {
        await prefs.remove(_emailPrefsKey);
      }
    } catch (_) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_emailPrefsKey);
    }
  }

  Future<void> _persistSession() async {
    if (_currentUser == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_emailPrefsKey, _currentUser!.email);
  }

  /// Pull the masked phone hint out of the challenge's public parameters
  /// (CreateAuthChallenge sets `phoneHint`); fall back to neutral copy.
  String _phoneHintFrom(dynamic challengeParameters) {
    if (challengeParameters is Map) {
      final hint = challengeParameters['phoneHint'];
      if (hint is String && hint.isNotEmpty) return hint;
    }
    return 'your phone';
  }

  /// E.164 normaliser: keeps a leading `+`, strips other non-digits, and
  /// prepends `+1` for a bare 10-digit US number. The pool requires a
  /// valid `phone_number` at sign-up.
  String _normalizePhone(String raw) {
    final trimmed = raw.trim();
    if (trimmed.startsWith('+')) {
      return '+${trimmed.substring(1).replaceAll(RegExp(r'\D'), '')}';
    }
    final digits = trimmed.replaceAll(RegExp(r'\D'), '');
    if (digits.length == 10) return '+1$digits';
    return '+$digits';
  }

  /// A throwaway password satisfying the pool policy (≥14, upper/lower/
  /// digit/symbol). Never shown or reused — the user always SMS-OTPs in
  /// (d2c-auth-stack.ts §passwordPolicy comment).
  String _randomThrowawayPassword() {
    final rng = Random.secure();
    const upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
    const lower = 'abcdefghijkmnpqrstuvwxyz';
    const digits = '23456789';
    const symbols = '!@#\$%^&*()-_=+';
    const all = upper + lower + digits + symbols;
    final chars = <String>[
      upper[rng.nextInt(upper.length)],
      lower[rng.nextInt(lower.length)],
      digits[rng.nextInt(digits.length)],
      symbols[rng.nextInt(symbols.length)],
      for (var i = 0; i < 20; i++) all[rng.nextInt(all.length)],
    ]..shuffle(rng);
    return chars.join();
  }

  String _friendlyMessage(String? code, String? message) {
    switch (code) {
      case 'UsernameExistsException':
        return 'An account with that email already exists. Sign in instead.';
      case 'CodeMismatchException':
        return 'Incorrect code. Try again.';
      case 'ExpiredCodeException':
        return 'Code expired. Request a new one.';
      case 'UserNotFoundException':
        return 'No account found with that email.';
      case 'InvalidParameterException':
        return 'Please check your details and try again.';
      case 'TooManyRequestsException':
      case 'LimitExceededException':
        return 'Too many attempts. Please wait a moment and try again.';
      default:
        return message ?? 'Something went wrong. Please try again.';
    }
  }
}

/// Result of [D2CAuthService.signUp] — whether the account is already
/// confirmed (for the D2C pool it never is; the caller routes to the
/// email-code confirmation step).
class D2CSignUpResult {
  final bool confirmed;
  const D2CSignUpResult({required this.confirmed});
}

/// The pending SMS-OTP challenge returned by [D2CAuthService.startSignIn].
class D2COtpChallenge {
  /// Masked tail of the destination phone (e.g. `"••34"`), or neutral
  /// copy ("your phone") when the backend didn't surface a hint.
  final String phoneHint;
  const D2COtpChallenge({required this.phoneHint});
}
