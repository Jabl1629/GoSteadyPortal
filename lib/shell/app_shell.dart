import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../api/api_client.dart';
import '../auth/auth_service_interface.dart';
import '../data/facility_repository.dart';
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
/// Per phase-2b-0-foundation.md §Files Changed > lib/shell/app_shell.dart
/// + phase-2b-fac-r-facility-reads.md (both modes now route to
/// FacilityShell; live mode primes the repository on sign-in).
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

  /// Future for the repository prime call. Null until sign-in fires
  /// the listener that kicks it off. Replaced on each new sign-in.
  Future<void>? _primeFuture;

  bool _wasSignedIn = false;

  @override
  void initState() {
    super.initState();
    _wasSignedIn = widget.auth.isSignedIn;
    if (_wasSignedIn) {
      _primeFuture = widget.repository.primeAtSignIn();
    }
    widget.auth.addListener(_onAuthChanged);
    _router = buildAppRouter(
      auth: widget.auth,
      buildMode: widget.buildMode,
      facilityHomeBuilder: (_) => _FacilityHome(
        primeFuture: _primeFuture,
        repository: widget.repository,
      ),
    );
  }

  @override
  void dispose() {
    widget.auth.removeListener(_onAuthChanged);
    super.dispose();
  }

  void _onAuthChanged() {
    final nowSignedIn = widget.auth.isSignedIn;
    if (nowSignedIn && !_wasSignedIn) {
      // Just signed in — prime the repository.
      setState(() {
        _primeFuture = widget.repository.primeAtSignIn();
      });
    } else if (!nowSignedIn && _wasSignedIn) {
      // Just signed out — clear the cache so the next session starts
      // fresh (different user → different scope).
      widget.repository.clearOnSignOut();
      setState(() {
        _primeFuture = null;
      });
    }
    _wasSignedIn = nowSignedIn;
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

/// Facility home — wraps [FacilityShell] in a FutureBuilder against
/// the repository's prime call. Shows a brief spinner while
/// `/me/patients` loads on cold sign-in; immediate render on
/// subsequent navigations to the same shell (the prime Future
/// resolves once and the FutureBuilder's `connectionState` is `done`
/// from then on).
class _FacilityHome extends StatelessWidget {
  const _FacilityHome({
    required this.primeFuture,
    required this.repository,
  });

  final Future<void>? primeFuture;
  final FacilityRepository repository;

  @override
  Widget build(BuildContext context) {
    if (primeFuture == null) {
      // Not signed in (shouldn't normally reach here — router redirects);
      // render the shell against empty cache as a defensive fallback.
      return FacilityShell(data: repository);
    }
    return FutureBuilder<void>(
      future: primeFuture,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(
              child: CircularProgressIndicator(color: AppTheme.sage),
            ),
          );
        }
        if (snap.hasError) {
          return Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(48),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.error_outline_rounded,
                      size: 56,
                      color: AppTheme.statusAlert,
                    ),
                    const SizedBox(height: 18),
                    Text(
                      'Could not load your patients',
                      style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                            fontSize: 20,
                          ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${snap.error}',
                      style: const TextStyle(
                        color: AppTheme.textSoft,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }
        return FacilityShell(data: repository);
      },
    );
  }
}
