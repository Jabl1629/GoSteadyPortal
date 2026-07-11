/// Cognito configuration for the separate D2C (consumer) user pool —
/// matches the deployed `GoSteady-<Env>-D2C-Auth` stack (d2c-phase1 §3.1,
/// coord §C37). Deliberately distinct from the facility [CognitoConfig]:
/// D2C is a clean HIPAA/scoping boundary with a passwordless SMS-OTP
/// custom-auth flow (d2c.md L5).
///
/// The pool + client ids are **resolved at build time from the target env's
/// D2C-Auth stack outputs** (`D2CUserPoolId` / `D2CPortalClientId`) and injected
/// via `--dart-define` by `tools/deploy-d2c-app.sh`, exactly like `API_BASE_URL`.
/// They are intentionally NOT hardcoded: a prod build must bake in the PROD
/// pool, and a hardcoded dev id would silently point prod auth at the dev pool
/// (coord §C57.3 #2 — the #1 pre-prod code gap). When a define is missing,
/// [isConfigured] is false and the live entrypoint (`main_d2c.dart`) shows a
/// config-error screen rather than signing in against the wrong pool.
class D2CCognitoConfig {
  /// D2C user pool id — `GoSteady-<Env>-D2C-Auth` output `D2CUserPoolId`
  /// (dev: `us-east-1_gskGQvzhg`). Empty string when the `--dart-define` is
  /// absent; see [isConfigured].
  static const String userPoolId = String.fromEnvironment('D2C_USER_POOL_ID');

  /// D2C public app client id — `D2CPortalClientId` output (CUSTOM_AUTH only,
  /// no secret; dev: `4kb1reql2patil0buc1mt14vk0`). Empty when absent.
  static const String clientId = String.fromEnvironment('D2C_CLIENT_ID');

  static const String region = 'us-east-1';

  /// True only when both the pool id and client id were injected at build time.
  /// A live build that fails this must NOT construct the Cognito pool — it would
  /// otherwise target an unintended (or empty) pool.
  static bool get isConfigured => userPoolId.isNotEmpty && clientId.isNotEmpty;
}
