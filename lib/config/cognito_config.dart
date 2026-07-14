/// Cognito configuration for the live-mode portal.
///
/// Defaults match the GoSteady-Dev-Auth stack. A prod build overrides the pool
/// + client via `--dart-define` (deploy-portal.sh resolves them from the
/// `{Env}-Auth` stack outputs, mirroring how API_BASE_URL is injected) — so the
/// prod portal authenticates against the prod pool, and its token's audience
/// matches the prod API authorizer.
class CognitoConfig {
  static const String userPoolId = String.fromEnvironment(
    'COGNITO_USER_POOL_ID',
    defaultValue: 'us-east-1_ZHbhl19tQ',
  );
  static const String clientId = String.fromEnvironment(
    'COGNITO_CLIENT_ID',
    defaultValue: '1q9l9ujtsomf3ugq2tnqvdg6d7',
  );
  static const String region = 'us-east-1';
}
