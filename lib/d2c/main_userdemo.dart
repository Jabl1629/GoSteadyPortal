import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_strategy/url_strategy.dart';
import 'package:web/web.dart' as web;

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
/// **Framing**: by default the app simply fills the window at every size —
/// a phone visitor gets the native PWA feel, a desktop visitor gets a
/// full-window web app (screens cap their content width themselves). For
/// pitch decks / screenshots a phone-shaped frame can be forced via the
/// URL (scaled down if the window is too short for the mock device):
///   ?w=390    phone frame — iPhone 14 / 13 Pro
///   ?w=430    phone frame — iPhone 15 Pro Max
///   ?w=744    phone frame — iPad mini portrait
///   ?w=full   explicit no-frame (same as the default; kept for old links)
///
/// **Get in touch**: a persistent banner above the app links to the
/// marketing site's interest form (gosteady.co/get-in-touch) — the demo
/// doubles as a lead-capture surface for QR-code handouts.
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

  runApp(_UserDemoShell(
    forcedFrameWidth: _forcedFrameWidthFromUrl(),
    child: _UserDemoApp(router: _buildRouter(auth)),
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
// Demo shell: "Get in touch" banner over the app; optional forced phone
// frame via `?w=` (default is the app filling the window at any size)
// ─────────────────────────────────────────────────────────────────────

/// `?w=NNN` from the page URL, or null for the default no-frame fill
/// (absent, `full`, or an out-of-range value all mean null).
double? _forcedFrameWidthFromUrl() {
  try {
    final w = Uri.base.queryParameters['w'];
    if (w == null || w == 'full') return null;
    final width = double.tryParse(w);
    if (width == null || width < 200 || width > 2000) return null;
    return width;
  } catch (_) {
    return null;
  }
}

/// Root of the demo page: the lead-capture banner pinned above the app,
/// which renders natively (default) or inside a forced phone frame.
/// Sits above [MaterialApp], hence the explicit [Directionality].
class _UserDemoShell extends StatelessWidget {
  const _UserDemoShell({required this.forcedFrameWidth, required this.child});
  final double? forcedFrameWidth;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Column(
        children: [
          const _GetInTouchBanner(),
          Expanded(
            child: forcedFrameWidth == null
                ? child
                : _DeviceFrame(width: forcedFrameWidth!, child: child),
          ),
        ],
      ),
    );
  }
}

/// Where the banner sends interested visitors — the marketing site's
/// Netlify interest form. `src=userdemo` tags the lead's origin.
const _getInTouchUrl = 'https://gosteady.co/get-in-touch?src=userdemo';

/// Same-tab navigation via `location.assign`, deliberately NOT
/// url_launcher / `window.open`: popup blockers in embedded and some
/// mobile browsers silently swallow `window.open` (even `_self`, once the
/// plugin's async hop loses the tap's user-gesture context), and
/// url_launcher reports success regardless — verified in the in-app
/// browser pane, where the tap fired but nothing opened. A location
/// assignment is plain navigation and is never blocked. The form's
/// success page links back to the demo, so same-tab isn't a dead end —
/// and the demo is stateless mock data anyway.
void _openGetInTouch() => web.window.location.assign(_getInTouchUrl);

/// Full-width sage strip above the app on every screen (login included —
/// QR-code recipients land there). Whole banner is tappable; opens the
/// interest form in a new tab so the demo stays where it was.
class _GetInTouchBanner extends StatelessWidget {
  const _GetInTouchBanner();

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.sage,
      child: SafeArea(
        bottom: false,
        child: InkWell(
          onTap: _openGetInTouch,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
            child: Row(
              children: [
                const Icon(Icons.favorite_rounded,
                    size: 16, color: Colors.white),
                const SizedBox(width: 9),
                const Expanded(
                  child: Text(
                    'Want GoSteady for your family?',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0.1,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Get in touch',
                        style: TextStyle(
                          color: AppTheme.sage,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.2,
                        ),
                      ),
                      SizedBox(width: 4),
                      Icon(Icons.arrow_forward_rounded,
                          size: 13, color: AppTheme.sage),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Centers the app inside a fixed phone-shaped box (`?w=` only), scaled
/// down via [FittedBox] when the window is too short — never clipped.
class _DeviceFrame extends StatelessWidget {
  const _DeviceFrame({required this.width, required this.child});
  final double width;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final height = width <= 500 ? width * (19.5 / 9.0) : width * (4.0 / 3.0);
    return ColoredBox(
      color: const Color(0xFFE5E0D8),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Container(
              width: width,
              height: height,
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
                  size: Size(width, height),
                  padding: EdgeInsets.zero,
                  viewInsets: EdgeInsets.zero,
                  viewPadding: EdgeInsets.zero,
                ),
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
