import 'package:flutter/material.dart';
import 'package:url_strategy/url_strategy.dart';

import 'api/api_client.dart';
import 'auth/auth_service.dart';
import 'auth/mock_auth_service.dart';
import 'data/facility_repository.dart';
import 'data/live_facility_repository.dart';
import 'facility_demo/data/facility_mock_data.dart';
import 'shell/app_shell.dart';
import 'state/build_mode.dart';

/// Live-mode entry point for the GoSteady portal.
///
/// Builds:
///   flutter run -d chrome -t lib/main.dart \
///     --dart-define=BUILD_MODE=live \
///     --dart-define=API_BASE_URL=https://<api-gw-id>.execute-api.us-east-1.amazonaws.com
///
/// Falls back to demo mode if `BUILD_MODE` is unset (defensive default
/// per phase-2b-0-foundation.md L2).
///
/// Per phase-2b-0-foundation.md §Scope > Build invocations.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Path URLs by default. GH Pages can't rewrite arbitrary paths to
  // index.html, so the wireframe-preview deployment uses hash routing.
  // Pass `--dart-define=USE_HASH_URLS=true` at build time to opt in.
  const useHashUrls = bool.fromEnvironment('USE_HASH_URLS', defaultValue: false);
  if (!useHashUrls) {
    setPathUrlStrategy();
  }

  final mode = BuildMode.current;

  if (mode.isLive) {
    const apiBaseUrl = String.fromEnvironment('API_BASE_URL');
    if (apiBaseUrl.isEmpty) {
      runApp(const _MissingApiBaseUrlScreen());
      return;
    }
    final auth = AuthService.instance;
    await auth.init();
    final apiClient = ApiClient(auth: auth, baseUrl: apiBaseUrl);
    final FacilityRepository repo = LiveFacilityRepository(api: apiClient);
    runApp(AppShell(
      auth: auth,
      repository: repo,
      apiClient: apiClient,
      buildMode: mode,
    ));
  } else {
    // Demo mode (default when BUILD_MODE is unset).
    debugPrint(
      'BUILD_MODE not set — defaulting to demo. To run the live portal: '
      'flutter run -t lib/main.dart --dart-define=BUILD_MODE=live --dart-define=API_BASE_URL=…',
    );
    final auth = MockAuthService.instance;
    await auth.init();
    final FacilityRepository repo = FacilityMockData();
    runApp(AppShell(
      auth: auth,
      repository: repo,
      apiClient: null,
      buildMode: BuildMode.demo,
    ));
  }
}

/// Shown when `BUILD_MODE=live` but `API_BASE_URL` is unset. Refuses
/// to silently fall back to demo (per phase-2b-0-foundation.md D8).
class _MissingApiBaseUrlScreen extends StatelessWidget {
  const _MissingApiBaseUrlScreen();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GoSteady Portal — Configuration Error',
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
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'BUILD_MODE=live requires --dart-define=API_BASE_URL=…',
                  style: TextStyle(fontFamily: 'monospace'),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Example:',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                SelectableText(
                  'flutter run -d chrome -t lib/main.dart \\\n'
                  '  --dart-define=BUILD_MODE=live \\\n'
                  '  --dart-define=API_BASE_URL=https://<api-gw-id>.execute-api.us-east-1.amazonaws.com',
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
