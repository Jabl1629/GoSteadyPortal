import 'package:flutter/foundation.dart';

import '../models/user.dart';

/// Contract that both the Cognito-backed [AuthService] and the mock
/// [MockAuthService] satisfy. Lets [AppShell] depend only on the
/// abstraction so the demo and live builds share a single screen tree.
///
/// Per phase-2b-0-foundation.md L5.
abstract class AuthServiceInterface extends ChangeNotifier {
  /// The currently signed-in user, or null.
  GoSteadyUser? get currentUser;

  /// Whether there's a valid session.
  bool get isSignedIn;

  /// Restore a persisted session if one exists. Call once at app boot.
  Future<void> init();

  /// Sign in with email + password. Returns the user on success.
  ///
  /// May throw [MfaChallengeRequired] (caller routes to /mfa-verify)
  /// or [AuthException] (caller surfaces the message).
  Future<GoSteadyUser> signIn(String email, String password);

  /// Continue an MFA challenge after [signIn] threw [MfaChallengeRequired].
  /// Throws [AuthException] on bad code.
  Future<GoSteadyUser> completeMfaChallenge(String code);

  /// Begin TOTP enrollment for the current user. Returns the secret +
  /// otpauth URI the UI renders as a QR code. The user enters the
  /// 6-digit code that the authenticator app generates; the UI then
  /// calls [verifyMfaEnrollment].
  Future<MfaEnrollmentChallenge> enrollMfa();

  /// Verify the 6-digit code from the authenticator app, completing
  /// enrollment. After this, the user's next sign-in will trigger an
  /// MFA challenge.
  Future<void> verifyMfaEnrollment(String code);

  /// Send a password-reset code to the user's email.
  Future<void> forgotPassword(String email);

  /// Complete the password reset with the code + new password.
  Future<void> confirmForgotPassword(
    String email,
    String code,
    String newPassword,
  );

  /// Sign out + clear local session.
  Future<void> signOut();

  /// Fetch a valid ID token, refreshing if within 60 s of expiry.
  /// Returns null if no session.
  ///
  /// Per phase-2b-0-foundation.md L8.
  Future<String?> getIdToken();

  /// Force a token refresh so freshly-persisted custom claims are reflected.
  /// The D2C flow calls this after `POST /claim` so `custom:clientId` picks up
  /// the new household (the pre-claim bootstrap token carried `dtc_{sub}`, not
  /// the persisted `dtc_{householdId}`). No-op by default (facility auth mints
  /// its claims at sign-in).
  Future<void> refreshClaims() async {}
}

/// Thrown when [signIn] returns a Cognito MFA challenge — caller
/// must route to /mfa-verify and call [AuthServiceInterface.completeMfaChallenge].
class MfaChallengeRequired implements Exception {
  final String username;
  const MfaChallengeRequired(this.username);

  @override
  String toString() => 'MFA challenge required for $username';
}

/// User-facing auth error with a message safe to display.
class AuthException implements Exception {
  final String message;
  const AuthException(this.message);

  @override
  String toString() => message;
}

/// Data needed to render the MFA enrollment QR code.
class MfaEnrollmentChallenge {
  /// Base32 TOTP secret. Showed to the user as a fallback for manual
  /// authenticator-app entry when the QR code can't be scanned.
  final String secret;

  /// `otpauth://totp/...` URI encoded as a QR code by the UI.
  final String otpauthUri;

  const MfaEnrollmentChallenge({
    required this.secret,
    required this.otpauthUri,
  });
}
