import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_strategy/url_strategy.dart';

import '../auth/mock_auth_service.dart';
import '../theme/app_theme.dart';
import 'd2c_preview.dart';
import 'd2c_routes.dart';
import 'data/d2c_repository.dart';
import 'live/d2c_live_screens.dart';
import 'screens/d2c_account_screens.dart';
import 'screens/d2c_care_team_screen.dart';
import 'screens/d2c_history_screen.dart';

/// Entry point for the **D2C user demo** — the public, mock-data consumer
/// demo deployed to `gosteady.co/userdemo/`. The household / Care Circle
/// equivalent of the facility demo (`lib/facility_demo/main_demo.dart`).
///
/// Build:
///   flutter build web -t lib/d2c/main_userdemo.dart --base-href /userdemo/
///
/// Run locally:
///   flutter run -d chrome -t lib/d2c/main_userdemo.dart
///
/// Self-contained: one-click mock sign-in → the polished signed-in app
/// (Activity / Care Team / Account) rendered against [D2CMockData]. No
/// Cognito, no API, no SMS. Opens in the walker-user's point of view
/// (Susan Davis); the dashboard's person-icon toggle flips to the
/// caregiver/Admin view live.
///
/// **Mobile framing**: the D2C product is a mobile-first PWA. By default
/// the demo adapts to the window: phone-sized windows run the app natively
/// (someone opened the demo on their actual phone), larger windows render
/// it inside a phone-shaped frame — scaled down when the window is too
/// short for the full mock device, so desktop visitors never see a clipped
/// frame. Re-evaluated live on resize. Force a mode via the URL:
///   ?w=390    force a 390px frame — iPhone 14 / 13 Pro
///   ?w=430    force a 430px frame — iPhone 15 Pro Max (the auto default)
///   ?w=744    force a 744px frame — iPad mini portrait
///   ?w=full   force no frame — fill the window
///
/// Reuses the polished wireframe screens verbatim (the same widgets the
/// `/d2c/preview` design-review hub renders); this entry just presents
/// them as a dashboard-first app behind a sign-in instead of an index.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  setPathUrlStrategy();

  // The polished screens cross-link via `/d2c/preview/*` paths and the
  // shared bottom nav resolves against [D2CRoutes]. Keep the default
  // prefix so all of that wiring works without touching screen code.
  D2CRoutes.prefix = '/d2c/preview';

  final auth = MockAuthService.instance;
  await auth.init();

  // Built once: the adaptive frame rebuilds on window resize, and a
  // rebuilt router would reset navigation state mid-demo.
  final router = _buildRouter(auth);
  runApp(_AdaptiveDeviceFrame(
    mode: _FrameMode.fromUrl(),
    child: _UserDemoApp(router: router),
  ));
}

/// Path the account screen's "Sign out" routes to (see
/// `d2c_account_screens.dart`). The demo mounts its login screen here so
/// signing out returns to the demo's front door.
const _loginPath = '/d2c/preview/onboarding/sign-in';

class _UserDemoApp extends StatelessWidget {
  const _UserDemoApp({required this.router});

  final GoRouter router;

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'GoSteady',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.build(),
      routerConfig: router,
    );
  }
}

GoRouter _buildRouter(MockAuthService auth) {
  return GoRouter(
    initialLocation: D2CRoutes.dashboard,
    refreshListenable: auth,
    redirect: (context, state) {
      final signedIn = auth.isSignedIn;
      final atLogin = state.matchedLocation == _loginPath;
      if (!signedIn) return atLogin ? null : _loginPath;
      if (atLogin) return D2CRoutes.dashboard;
      return null;
    },
    routes: [
      GoRoute(path: _loginPath, builder: (_, __) => const _UserDemoLogin()),

      // ── Activity ──────────────────────────────────────────────────
      GoRoute(
        path: D2CRoutes.dashboard,
        builder: (_, __) => const D2CDashboardPreview(startAsWalkerUser: true),
      ),
      GoRoute(
        path: D2CRoutes.history,
        builder: (_, __) => const D2CHistoryScreen(isWalkerUser: true),
      ),

      // ── Care Team (Admin view — the solo walker-user-is-Admin case) ─
      GoRoute(
        path: D2CRoutes.careTeam,
        builder: (_, __) => const D2CCareTeamScreen(
          repository: D2CMockRepository(),
          viewerIsAdmin: true,
        ),
      ),

      // ── Coach ("Steady") — mock-backed hosts (same as the live app) ─
      GoRoute(
        path: D2CRoutes.coach,
        builder: (_, __) =>
            const D2CCoachHost(repository: D2CMockRepository()),
      ),
      GoRoute(
        path: D2CRoutes.coachMemory,
        builder: (_, __) =>
            const D2CCoachMemoryHost(repository: D2CMockRepository()),
      ),

      // ── Account + drill-downs ─────────────────────────────────────
      GoRoute(
        path: D2CRoutes.account,
        builder: (_, __) => const D2CAccountSettingsScreen(),
      ),
      GoRoute(
        path: '/d2c/preview/account/notifications',
        builder: (_, __) => const D2CNotificationPrefsScreen(),
      ),
      GoRoute(
        path: '/d2c/preview/account/audit',
        builder: (_, __) => const D2CAuditScreen(),
      ),
      GoRoute(
        path: '/d2c/preview/account/device',
        builder: (_, __) => const D2CDeviceSettingsScreen(),
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      backgroundColor: AppTheme.warmWhite,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Page not found', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => context.go(D2CRoutes.dashboard),
              child: const Text('Go home'),
            ),
          ],
        ),
      ),
    ),
  );
}

/// One-click mock sign-in. Mirrors the facility demo's login (no fields —
/// partners don't sign up at a booth), with consumer copy.
class _UserDemoLogin extends StatefulWidget {
  const _UserDemoLogin();

  @override
  State<_UserDemoLogin> createState() => _UserDemoLoginState();
}

class _UserDemoLoginState extends State<_UserDemoLogin> {
  bool _busy = false;

  Future<void> _signIn() async {
    if (_busy) return;
    setState(() => _busy = true);
    // The router's redirect swaps to the dashboard on the auth change.
    await MockAuthService.instance.signIn('demo', 'demo');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.warmWhite,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: AppTheme.sage,
                      borderRadius: BorderRadius.circular(18),
                      boxShadow: AppTheme.cardShadowElevated,
                    ),
                    child: const Icon(
                      Icons.accessibility_new_rounded,
                      color: Colors.white,
                      size: 32,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'GoSteady',
                    style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                          fontSize: 36,
                          fontWeight: FontWeight.w500,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Stay connected to the people you care for',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppTheme.textSoft,
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0.1,
                    ),
                  ),
                  const SizedBox(height: 48),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _busy ? null : _signIn,
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 18),
                        textStyle: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.2,
                        ),
                      ),
                      child: _busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text('Enter the demo'),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Demo build · static data, no real authentication',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppTheme.textSoft.withOpacity(0.7),
                      fontSize: 12,
                      letterSpacing: 0.2,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Adaptive phone-frame viewport (phones run native; desktop gets a
// scaled-to-fit phone frame; `?w=` forces a mode)
// ─────────────────────────────────────────────────────────────────────

/// Framing requested via the page URL. Default is [auto] — decided per
/// window size in [_AdaptiveDeviceFrame] rather than once at startup.
class _FrameMode {
  const _FrameMode._({this.explicitWidth, this.forceFull = false});

  /// `?w=NNN` — always frame at this width, whatever the window.
  final double? explicitWidth;

  /// `?w=full` — never frame; the app fills the window.
  final bool forceFull;

  static const auto = _FrameMode._();

  static _FrameMode fromUrl() {
    try {
      final w = Uri.base.queryParameters['w'];
      if (w == null) return auto;
      if (w == 'full') return const _FrameMode._(forceFull: true);
      final width = double.tryParse(w);
      if (width == null || width < 200 || width > 2000) return auto;
      return _FrameMode._(explicitWidth: width);
    } catch (_) {
      return auto;
    }
  }
}

/// Renders [child] either natively (phone-sized windows — the app IS the
/// page) or centered inside a phone-shaped frame (desktop / tablet
/// windows). The frame is scaled down via [FittedBox] when the window is
/// shorter than the mock device, so it is never clipped. [LayoutBuilder]
/// re-decides on every window resize.
class _AdaptiveDeviceFrame extends StatelessWidget {
  const _AdaptiveDeviceFrame({required this.mode, required this.child});
  final _FrameMode mode;
  final Widget child;

  static const double _defaultPhoneWidth = 430;

  /// Auto mode: windows narrower than this are a real phone (or a
  /// deliberately phone-sized window) — run the app natively. The frame
  /// needs ~430px + margins before it stops looking cramped anyway.
  static const double _nativeMaxWidth = 520;

  /// Keeps the app subtree's element (router state, scroll positions,
  /// in-progress text) alive when a resize crosses the framed ↔ native
  /// threshold and the wrapper tree around it changes shape.
  static final GlobalKey _appKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        double? frameWidth;
        if (mode.forceFull) {
          frameWidth = null;
        } else if (mode.explicitWidth != null) {
          frameWidth = mode.explicitWidth;
        } else {
          frameWidth = constraints.maxWidth >= _nativeMaxWidth
              ? _defaultPhoneWidth
              : null;
        }

        final app = KeyedSubtree(key: _appKey, child: child);
        if (frameWidth == null) return app;

        final frameHeight = frameWidth <= 500
            ? frameWidth * (19.5 / 9.0)
            : frameWidth * (4.0 / 3.0);
        return ColoredBox(
          color: const Color(0xFFE5E0D8),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(20),
              // scaleDown: full size when it fits, shrunk to the window
              // when it doesn't — never clipped.
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Container(
                  width: frameWidth,
                  height: frameHeight,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(28),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.12),
                        blurRadius: 28,
                        offset: const Offset(0, 12),
                      ),
                    ],
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: MediaQuery(
                    data: MediaQuery.of(context).copyWith(
                      size: Size(frameWidth, frameHeight),
                      padding: EdgeInsets.zero,
                      viewInsets: EdgeInsets.zero,
                      viewPadding: EdgeInsets.zero,
                    ),
                    child: app,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
