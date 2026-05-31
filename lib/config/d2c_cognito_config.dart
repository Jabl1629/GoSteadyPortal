/// Cognito configuration for the separate D2C (consumer) user pool —
/// matches the deployed `GoSteady-Dev-D2C-Auth` stack (d2c-phase1 §3.1,
/// coord §C37). Deliberately distinct from the facility [CognitoConfig]:
/// D2C is a clean HIPAA/scoping boundary with a passwordless SMS-OTP
/// custom-auth flow (d2c.md L5).
class D2CCognitoConfig {
  /// `gosteady-dev-d2c` user pool.
  static const String userPoolId = 'us-east-1_bhvtxuHwD';

  /// `gosteady-dev-d2c-portal` public app client (CUSTOM_AUTH only, no secret).
  static const String clientId = '1mfi0ori1r0r5tvd5rq11m3ac3';

  static const String region = 'us-east-1';
}
