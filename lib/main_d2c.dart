import 'package:flutter/material.dart';
import 'package:url_strategy/url_strategy.dart';

import 'api/api_client.dart';
import 'auth/mock_auth_service.dart';
import 'config/d2c_cognito_config.dart';
import 'd2c/auth/d2c_auth_service.dart';
import 'd2c/d2c_app.dart';
import 'd2c/d2c_routes.dart';
import 'd2c/data/d2c_repository.dart';
import 'd2c/data/live_d2c_repository.dart';
import 'state/build_mode.dart';

/// Entry point for the GoSteady **D2C consumer** portal (the household /
/// walker-user app), distinct from the facility entry `lib/main.dart`.
///
///   flutter run -d chrome -t lib/main_d2c.dart \
///     --dart-define=BUILD_MODE=live \
///     --dart-define=API_BASE_URL=https://<api-gw-id>.execute-api.us-east-1.amazonaws.com
///
/// Falls back to demo (mock repository) when `BUILD_MODE` is unset, so a
/// flag-less developer build looks like the demo, not a broken portal
/// (mirrors `main.dart`, per phase-2b-0-foundation.md L2). Per d2c-phase1 §6.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  const useHashUrls = bool.fromEnvironment('USE_HASH_URLS', defaultValue: false);
  if (!useHashUrls) {
    setPathUrlStrategy();
  }

  // The live D2C app mounts its display screens at the root (not under
  // `/d2c/preview/*`), so the shared bottom-nav + dashboard links resolve
  // against this router. Must be set before the router is built.
  D2CRoutes.prefix = '';

  final mode = BuildMode.current;

  if (mode.isLive) {
    const apiBaseUrl = String.fromEnvironment('API_BASE_URL');
    // Every live-build config value is injected per-env via --dart-define by
    // deploy-d2c-app.sh (resolved from the target env's stack outputs). Refuse
    // to launch if any is missing rather than silently falling back to demo or,
    // worse, baking in the wrong Cognito pool (coord §C57.3 #2).
    final missing = <String>[
      if (apiBaseUrl.isEmpty) 'API_BASE_URL',
      if (D2CCognitoConfig.userPoolId.isEmpty) 'D2C_USER_POOL_ID',
      if (D2CCognitoConfig.clientId.isEmpty) 'D2C_CLIENT_ID',
    ];
    if (missing.isNotEmpty) {
      runApp(_MissingConfigScreen(missing: missing));
      return;
    }
    final auth = D2CAuthService.instance;
    await auth.init();
    // D2C reads (`/me/patients`, `/patients/{id}[/activity|/alerts]`) go to
    // the `/api/v1/d2c/*` routes bound to the D2C-pool authorizer; the
    // facility authorizer 401s D2C tokens (coord §C54). claim + public
    // lookup keep their own (unprefixed) routes.
    final api = ApiClient(
      auth: auth,
      baseUrl: apiBaseUrl,
      readPathPrefix: '/api/v1/d2c',
    );
    final repo = LiveD2CRepository(api: api, auth: auth);
    runApp(D2CApp(auth: auth, repository: repo, d2cAuth: auth));
  } else {
    // Demo: mock repository + a pre-seeded mock session so the auth gate
    // lets us straight into the dashboard (no real Cognito / SMS).
    final auth = MockAuthService.instance;
    await auth.init();
    await auth.signIn('demo@gosteady.co', 'demo');
    runApp(D2CApp(auth: auth, repository: const D2CMockRepository()));
  }
}

/// Shown when `BUILD_MODE=live` but one or more required `--dart-define`s are
/// unset — refuses to silently fall back to demo or to sign in against the
/// wrong Cognito pool (per phase-2b-0-foundation.md D8; coord §C57.3 #2).
/// `deploy-d2c-app.sh` injects all of these, resolved from the target env's
/// stack outputs, so this screen only appears on a misconfigured hand-build.
class _MissingConfigScreen extends StatelessWidget {
  const _MissingConfigScreen({required this.missing});

  final List<String> missing;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GoSteady — Configuration Error',
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Configuration error',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                Text(
                  'BUILD_MODE=live requires --dart-define for: '
                  '${missing.join(', ')}',
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
                const SizedBox(height: 16),
                const SelectableText(
                  'flutter run -d chrome -t lib/main_d2c.dart \\\n'
                  '  --dart-define=BUILD_MODE=live \\\n'
                  '  --dart-define=API_BASE_URL=https://<api-gw-id>.execute-api.us-east-1.amazonaws.com \\\n'
                  '  --dart-define=D2C_USER_POOL_ID=us-east-1_xxxxxxxxx \\\n'
                  '  --dart-define=D2C_CLIENT_ID=xxxxxxxxxxxxxxxxxxxxxxxxxx\n'
                  '\n'
                  '(or just run ./tools/deploy-d2c-app.sh, which resolves all of\n'
                  'these from the D2C-Auth + Api stack outputs)',
                  style: TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
