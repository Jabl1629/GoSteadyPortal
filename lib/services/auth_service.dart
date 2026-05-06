import 'dart:convert';

import 'package:amazon_cognito_identity_dart_2/cognito.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/cognito_config.dart';
import '../models/user.dart';

/// Singleton auth service wrapping Amazon Cognito.
///
/// Usage:
///   final auth = AuthService.instance;
///   await auth.init();
///   if (auth.isSignedIn) { ... }
class AuthService extends ChangeNotifier {
  AuthService._();
  static final AuthService instance = AuthService._();

  late final CognitoUserPool _pool;
  CognitoUser? _cognitoUser;
  CognitoUserSession? _session;
  GoSteadyUser? _currentUser;

  /// The currently signed-in user, or null.
  GoSteadyUser? get currentUser => _currentUser;

  /// Whether the user has a valid session.
  bool get isSignedIn => _session?.isValid() == true && _currentUser != null;

  // ── Lifecycle ──────────────────────────────────────────────────

  /// Call once at app startup.
  Future<void> init() async {
    _pool = CognitoUserPool(
      CognitoConfig.userPoolId,
      CognitoConfig.clientId,
    );
    await _tryRestoreSession();
  }

  // ── Sign in ────────────────────────────────────────────────────

  /// Sign in with email + password. Returns the user on success.
  /// Throws [AuthException] on failure.
  Future<GoSteadyUser> signIn(String email, String password) async {
    _cognitoUser = CognitoUser(email, _pool);

    final authDetails = AuthenticationDetails(
      username: email,
      password: password,
    );

    try {
      _session = await _cognitoUser!.authenticateUser(authDetails);
    } on CognitoUserNewPasswordRequiredException {
      throw AuthException('Password change required. Contact support.');
    } on CognitoUserMfaRequiredException {
      throw AuthException('MFA not yet supported.');
    } on CognitoUserCustomChallengeException {
      throw AuthException('Custom challenge not supported.');
    } on CognitoClientException catch (e) {
      throw AuthException(_friendlyMessage(e.code, e.message));
    } on CognitoUserConfirmationNecessaryException {
      throw AuthException('Please verify your email first.');
    } catch (e) {
      throw AuthException(e.toString());
    }

    if (_session == null || !_session!.isValid()) {
      throw AuthException('Sign-in failed. Please try again.');
    }

    _currentUser = _extractUser(_session!);
    await _persistSession();
    notifyListeners();
    return _currentUser!;
  }

  // ── Sign up ────────────────────────────────────────────────────

  /// Register a new user. Returns true if confirmation (email) is needed.
  Future<bool> signUp({
    required String email,
    required String password,
    required String fullName,
    required UserRole role,
  }) async {
    final attributes = [
      AttributeArg(name: 'email', value: email),
      AttributeArg(name: 'name', value: fullName),
      AttributeArg(name: 'custom:role', value: role.name),
    ];

    try {
      final result = await _pool.signUp(email, password,
          userAttributes: attributes);
      return !(result.userConfirmed ?? false);
    } on CognitoClientException catch (e) {
      throw AuthException(_friendlyMessage(e.code, e.message));
    } catch (e) {
      throw AuthException(e.toString());
    }
  }

  /// Confirm sign-up with the verification code emailed to the user.
  Future<void> confirmSignUp(String email, String code) async {
    final user = CognitoUser(email, _pool);
    try {
      await user.confirmRegistration(code);
    } on CognitoClientException catch (e) {
      throw AuthException(_friendlyMessage(e.code, e.message));
    } catch (e) {
      throw AuthException(e.toString());
    }
  }

  // ── Sign out ───────────────────────────────────────────────────

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
    await _clearPersistedSession();
    notifyListeners();
  }

  // ── Token access ───────────────────────────────────────────────

  /// Returns the current ID token JWT, refreshing if needed.
  Future<String?> getIdToken() async {
    if (_session == null || _cognitoUser == null) return null;
    if (!_session!.isValid()) {
      // Attempt refresh
      try {
        _session = await _cognitoUser!.getSession();
        _currentUser = _extractUser(_session!);
        await _persistSession();
      } catch (_) {
        await signOut();
        return null;
      }
    }
    return _session!.getIdToken().getJwtToken();
  }

  // ── Internals ──────────────────────────────────────────────────

  GoSteadyUser _extractUser(CognitoUserSession session) {
    final idToken = session.getIdToken();
    final payload = idToken.payload;

    return GoSteadyUser(
      userId: payload['sub'] as String? ?? '',
      email: payload['email'] as String? ?? '',
      name: payload['name'] as String? ?? '',
      role: UserRole.fromString(payload['custom:role'] as String?),
      idToken: idToken.getJwtToken(),
    );
  }

  /// Try to restore session from local storage on cold start.
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
      // No valid session — user will need to sign in.
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
      case 'UsernameExistsException':
        return 'An account with this email already exists.';
      case 'InvalidParameterException':
        return 'Please check your input and try again.';
      case 'InvalidPasswordException':
        return 'Password must be at least 8 characters with uppercase, lowercase, and a number.';
      case 'TooManyRequestsException':
        return 'Too many attempts. Please wait a moment and try again.';
      case 'LimitExceededException':
        return 'Too many attempts. Please wait a moment and try again.';
      default:
        return message ?? 'Something went wrong. Please try again.';
    }
  }
}

/// Thrown for auth-related errors with a user-friendly message.
class AuthException implements Exception {
  final String message;
  const AuthException(this.message);

  @override
  String toString() => message;
}
