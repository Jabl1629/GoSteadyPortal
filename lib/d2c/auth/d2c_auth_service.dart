import 'dart:math';

import 'package:amazon_cognito_identity_dart_2/cognito.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../auth/auth_service_interface.dart';
import '../../auth/prefs_cognito_storage.dart';
import '../../auth/user_claims.dart';
import '../../config/d2c_cognito_config.dart';
import '../../models/user.dart';

/// Cognito-backed auth for the **D2C consumer pool** — a passwordless,
/// **phone-first** SMS-OTP custom-auth flow (d2c-phone-only-signin.md).
/// Distinct from the facility [AuthService] (email + password + TOTP-MFA):
/// D2C never collects a password from the user, and there is NO email/second
/// verification step — SMS-OTP is the sole factor.
///
/// The pool signs users in by **phone number** (email is an optional secondary
/// alias / contact, never verified). A fresh self-signup is auto-confirmed by
/// the pool's pre-signup trigger, so the flow is simply:
///
///   1. [signUp]      — create the account (name + phone [+ optional email]).
///   2. [startSignIn] — begin CUSTOM_AUTH; Cognito SMS-OTPs the phone.
///   3. [submitOtp]   — answer the challenge; on success, tokens issue.
///
/// Implements [AuthServiceInterface] so the shared [ApiClient] (which only
/// needs [getIdToken]) is reused unchanged. Password / MFA methods throw
/// [UnsupportedError]; D2C uses the dedicated methods below.
///
/// > NOTE: OTP *delivery* is gated on the operator populating the
/// > `gosteady/dev/twilio` secret (coord §C37.3). Sessions are in-memory
/// > (default Cognito storage) — a page reload requires re-sign-in.
class D2CAuthService extends AuthServiceInterface {
  D2CAuthService._();
  static final D2CAuthService instance = D2CAuthService._();

  /// Convenience key: the phone (sign-in username) of the last session, so a
  /// same-page session restore can reconstruct the CognitoUser.
  static const _phonePrefsKey = 'gs_d2c_auth_phone';

  late final CognitoUserPool _pool;
  CognitoUser? _cognitoUser;
  CognitoUserSession? _session;
  GoSteadyUser? _currentUser;

  /// The sign-in username (E.164 phone) for the current/last session.
  String? _username;

  /// The user mid-sign-in: held between [startSignIn] (challenge issued)
  /// and [submitOtp] (challenge answered).
  CognitoUser? _pendingSignInUser;
  String? _pendingSignInPhone;

  @override
  GoSteadyUser? get currentUser => _currentUser;

  @override
  bool get isSignedIn => _session?.isValid() == true && _currentUser != null;

  // ── Lifecycle ─────────────────────────────────────────────────

  @override
  Future<void> init() async {
    // Persistent (localStorage-backed) token storage so the session survives a
    // page reload — otherwise the pool defaults to in-memory storage and every
    // refresh forces a fresh SMS-OTP sign-in. getSession() then restores from
    // the persisted tokens + auto-refreshes via the 30-day refresh token.
    final prefs = await SharedPreferences.getInstance();
    _pool = CognitoUserPool(
      D2CCognitoConfig.userPoolId,
      D2CCognitoConfig.clientId,
      storage: PrefsCognitoStorage(prefs, namespace: 'd2c_cognito'),
    );
    await _tryRestoreSession();
  }

  // ── D2C sign-up (phone-first; auto-confirmed, no code) ────────

  /// Register a new walker user, **phone-first**. `phone` is the sign-in
  /// identifier + the SMS-OTP channel, normalised to E.164 (`+1` prepended for
  /// a bare 10-digit US number). `email` is OPTIONAL (a secondary sign-in alias
  /// / contact) and is NOT verified. The pool's pre-signup trigger auto-confirms
  /// the account, so the caller proceeds straight to [startSignIn] — there is
  /// no email/second confirmation step.
  Future<void> signUp({
    required String name,
    required String phone,
    String? email,
  }) async {
    final normalizedPhone = _normalizePhone(phone);
    final attrs = <AttributeArg>[
      AttributeArg(name: 'name', value: name.trim()),
      AttributeArg(name: 'phone_number', value: normalizedPhone),
    ];
    final e = (email ?? '').trim();
    if (e.isNotEmpty) {
      attrs.add(AttributeArg(name: 'email', value: e.toLowerCase()));
    }
    try {
      await _pool.signUp(
        normalizedPhone,
        _randomThrowawayPassword(),
        userAttributes: attrs,
      );
    } on CognitoClientException catch (ex) {
      throw AuthException(_friendlyMessage(ex.code, ex.message));
    } catch (ex) {
      throw AuthException(ex.toString());
    }
  }

  // ── D2C sign-in: CUSTOM_AUTH SMS-OTP ──────────────────────────

  /// Begin sign-in for [phone]. Triggers Cognito CUSTOM_AUTH, which fires the
  /// custom-auth Lambda → SMS-OTP to that phone. Returns the challenge
  /// (carrying the `phoneHint` the UI shows, e.g. "•••34"). Follow with
  /// [submitOtp].
  Future<D2COtpChallenge> startSignIn(String phone) async {
    final normalizedPhone = _normalizePhone(phone);
    final user = CognitoUser(normalizedPhone, _pool);
    try {
      // initiateAuth sends AuthFlow=CUSTOM_AUTH and throws the custom
      // challenge exception once the OTP is dispatched (expected path).
      final session = await user.initiateAuth(
        AuthenticationDetails(username: normalizedPhone, authParameters: []),
      );
      // Unreachable for this pool (tokens with no factor) — treat as success.
      if (session != null && session.isValid()) {
        _username = normalizedPhone;
        _adoptSession(user, session);
        await _persistSession();
        return const D2COtpChallenge(phoneHint: '');
      }
      throw const AuthException('Could not start sign-in. Try again.');
    } on CognitoUserCustomChallengeException catch (e) {
      // Expected: OTP sent, awaiting the code.
      _pendingSignInUser = user;
      _pendingSignInPhone = normalizedPhone;
      return D2COtpChallenge(phoneHint: _phoneHintFrom(e.challengeParameters));
    } on CognitoClientException catch (e) {
      throw AuthException(_friendlyMessage(e.code, e.message));
    } on AuthException {
      rethrow;
    } catch (e) {
      throw AuthException(e.toString());
    }
  }

  /// Answer the SMS-OTP challenge. On success the session is established and
  /// the [GoSteadyUser] (with `dtc_*` claims) is returned. A wrong code
  /// re-issues the challenge (up to 3 attempts) — surfaced as an
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
      _username = _pendingSignInPhone;
      _adoptSession(user, session);
      _pendingSignInUser = null;
      _pendingSignInPhone = null;
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

  /// Re-send the SMS-OTP (restarts the challenge for the in-progress phone).
  Future<D2COtpChallenge> resendOtp() async {
    final phone = _pendingSignInPhone;
    if (phone == null) {
      throw const AuthException('No sign-in in progress. Start again.');
    }
    return startSignIn(phone);
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

  /// Force a fresh token mint (using the refresh token) so newly-persisted
  /// custom claims are reflected — the D2C flow calls this right after
  /// `POST /claim` so `custom:clientId` picks up the just-created household
  /// (the pre-claim bootstrap token carried `dtc_{sub}`, not the persisted
  /// `dtc_{householdId}`) before the dashboard reads.
  @override
  Future<void> refreshClaims() async {
    final u = _cognitoUser;
    final rt = _session?.getRefreshToken();
    if (u == null || rt == null) return;
    try {
      final s = await u.refreshSession(rt);
      if (s != null && s.isValid()) {
        _session = s;
        _currentUser = _extractUser(s);
        await _persistSession();
        notifyListeners();
      }
    } catch (_) {
      // Best-effort; getIdToken() will refresh on next use if needed.
    }
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
    _username = null;
    _pendingSignInUser = null;
    _pendingSignInPhone = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_phonePrefsKey);
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
      final phone = prefs.getString(_phonePrefsKey);
      if (phone == null || phone.isEmpty) return;

      _username = phone;
      _cognitoUser = CognitoUser(phone, _pool);
      _session = await _cognitoUser!.getSession();
      if (_session?.isValid() == true) {
        _currentUser = _extractUser(_session!);
        notifyListeners();
      } else {
        await prefs.remove(_phonePrefsKey);
      }
    } catch (_) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_phonePrefsKey);
    }
  }

  Future<void> _persistSession() async {
    final u = _username;
    if (u == null || u.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_phonePrefsKey, u);
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
  /// prepends `+1` for a bare 10-digit US number. The pool requires a valid
  /// `phone_number` at sign-up + uses it as the sign-in identifier.
  /// Canonicalize a typed phone to E.164. MUST match the backend
  /// `_shared.claim_binding.normalize_e164` — the bind side (fleet) and this
  /// signup/OTP side both feed the same canonical form, so any divergence
  /// re-opens the claim phone-mismatch.
  ///
  /// US-only pilot: a 10-digit number (or 11 digits starting with 1) is US
  /// (+1) **even when typed with a stray leading '+'**. That stray '+' is the
  /// prod bug where "+5165891580" was read as country code +516 and Twilio
  /// rejected the OTP; a real US number missing its +1 must still resolve to
  /// +1…. Only a non-US-shaped number typed with '+' is treated as intl.
  String _normalizePhone(String raw) {
    final trimmed = raw.trim();
    final digits = trimmed.replaceAll(RegExp(r'\D'), '');
    if (digits.length == 10) return '+1$digits';
    if (digits.length == 11 && digits.startsWith('1')) return '+$digits';
    if (trimmed.startsWith('+') && digits.length >= 8 && digits.length <= 15) {
      return '+$digits';
    }
    return '+$digits'; // last resort — Cognito validates the final format
  }

  /// A throwaway password satisfying the pool policy (≥14, upper/lower/
  /// digit/symbol). Never shown or reused — the user always SMS-OTPs in.
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
        return 'An account with that phone already exists. Sign in instead.';
      case 'CodeMismatchException':
        return 'Incorrect code. Try again.';
      case 'ExpiredCodeException':
        return 'Code expired. Request a new one.';
      case 'UserNotFoundException':
        return 'No account found with that phone number.';
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

/// The pending SMS-OTP challenge returned by [D2CAuthService.startSignIn].
class D2COtpChallenge {
  /// Masked tail of the destination phone (e.g. `"•••34"`), or neutral
  /// copy ("your phone") when the backend didn't surface a hint.
  final String phoneHint;
  const D2COtpChallenge({required this.phoneHint});
}
