import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../api/api_client.dart';
import '../auth/auth_service_interface.dart';
import '../data/facility_repository.dart';
import '../facility_demo/data/facility_mock_data.dart';
import '../facility_demo/screens/facility_shell.dart';
import '../state/app_router.dart';
import '../state/app_state.dart';
import '../state/build_mode.dart';
import '../theme/app_theme.dart';

/// Shared root widget for both build modes.
///
/// Takes the injected [AuthServiceInterface] + [FacilityRepository]
/// (+ optional [ApiClient] in live mode), provides them to descendants
/// via [AppState], and hosts the [GoRouter] config built from those
/// dependencies.
///
/// Per phase-2b-0-foundation.md §Files Changed > lib/shell/app_shell.dart.
class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.auth,
    required this.repository,
    required this.apiClient,
    required this.buildMode,
  });

  final AuthServiceInterface auth;
  final FacilityRepository repository;
  final ApiClient? apiClient;
  final BuildMode buildMode;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late final GoRouter _router;

  @override
  void initState() {
    super.initState();
    _router = buildAppRouter(
      auth: widget.auth,
      buildMode: widget.buildMode,
      facilityHomeBuilder: (_) {
        // The existing FacilityShell still expects a FacilityMockData
        // because it doesn't itself care about repository abstractness
        // until 2B-FAC-R. For 2B-0 we pass through whatever was injected
        // — in demo mode it's a real FacilityMockData; in live mode it's
        // a LiveFacilityRepository that throws UnimplementedError on
        // every screen call. That's the expected behavior for 2B-0
        // (we don't have live data wired yet — that's 2B-FAC-R).
        if (widget.repository is FacilityMockData) {
          return FacilityShell(data: widget.repository);
        }
        // Live mode pre-2B-FAC-R: render a stub explaining the state.
        return const _LiveFacilityShellStub();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return AppState(
      auth: widget.auth,
      repository: widget.repository,
      apiClient: widget.apiClient,
      buildMode: widget.buildMode,
      child: MaterialApp.router(
        title: widget.buildMode.isDemo
            ? 'GoSteady — Facility Demo'
            : 'GoSteady Portal',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.build(),
        routerConfig: _router,
      ),
    );
  }
}

/// Live-mode placeholder while 2B-FAC-R is still in flight. Renders a
/// "this is the foundation; business screens land in 2B-FAC-R" message
/// + a link to the smoke screen at `/dev/me`. Removed once 2B-FAC-R
/// wires real data through the repository.
class _LiveFacilityShellStub extends StatelessWidget {
  const _LiveFacilityShellStub();

  @override
  Widget build(BuildContext context) {
    final auth = AppState.of(context).auth;
    return Scaffold(
      appBar: AppBar(
        title: const Text('GoSteady Portal'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () => auth.signOut(),
            tooltip: 'Sign out',
          ),
        ],
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Foundation ready',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 12),
                Text(
                  'Sign-in works against real Cognito; the JWT pipeline + '
                  '/me smoke screen are wired. Business screens (Census, '
                  'Patient Detail, Device Detail) land in Phase 2B-FAC-R.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: () =>
                      GoRouter.of(context).go('/dev/me'),
                  child: const Text('Open /api/v1/me smoke'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
