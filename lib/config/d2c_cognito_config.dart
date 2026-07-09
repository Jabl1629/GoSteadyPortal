/// Cognito configuration for the separate D2C (consumer) user pool —
/// matches the deployed `GoSteady-Dev-D2C-Auth` stack (d2c-phase1 §3.1,
/// coord §C37). Deliberately distinct from the facility [CognitoConfig]:
/// D2C is a clean HIPAA/scoping boundary with a passwordless SMS-OTP
/// custom-auth flow (d2c.md L5).
class D2CCognitoConfig {
  /// `gosteady-dev-d2c` user pool — PHONE-FIRST (phone + email sign-in aliases,
  /// SMS-OTP sole factor). Replaced the email-username pool in the DT-5 cutover
  /// (coord §C56); the pool id changed because UsernameAttributes is immutable.
  static const String userPoolId = 'us-east-1_gskGQvzhg';

  /// `gosteady-dev-d2c-portal` public app client (CUSTOM_AUTH only, no secret).
  static const String clientId = '4kb1reql2patil0buc1mt14vk0';

  static const String region = 'us-east-1';
}
