import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../auth/auth_service_interface.dart';
import '../theme/app_theme.dart';
import 'auth/d2c_auth_service.dart';
import 'd2c_routes.dart';
import 'data/d2c_repository.dart';
import 'live/d2c_live_screens.dart';
import 'screens/d2c_care_team_screen.dart';

/// Root of the live D2C consumer app (entry: `lib/main_d2c.dart`).
/// Self-contained — its own [GoRouter], distinct from the facility
/// `AppShell` + `app_router`. Reuses the shared theme + the injectable
/// dashboard screen. Per d2c-phase1 §6.
class D2CApp extends StatelessWidget {
  const D2CApp({
    super.key,
    required this.auth,
    required this.repository,
    this.d2cAuth,
  });

  final AuthServiceInterface auth;
  final D2CRepository repository;

  /// Concrete D2C auth (SMS-OTP flow) — non-null in the live build,
  /// null in demo (where [auth] is a pre-seeded mock and the onboarding
  /// routes are never reached).
  final D2CAuthService? d2cAuth;

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'GoSteady',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.build(),
      routerConfig: buildD2CRouter(
        auth: auth,
        repository: repository,
        d2cAuth: d2cAuth,
      ),
    );
  }
}

/// Builds the live D2C router. Public (no-auth) routes: `/setup/:walkerId`
/// + the onboarding flow (sign-up / sign-in / otp — phone-first SMS-OTP, no
/// email confirm step). Everything else requires a signed-in session.
GoRouter buildD2CRouter({
  required AuthServiceInterface auth,
  required D2CRepository repository,
  D2CAuthService? d2cAuth,
}) {
  bool isPublic(String loc) =>
      loc.startsWith('/setup') ||
      loc.startsWith('/join') ||
      loc == '/sign-in' ||
      loc == '/sign-up' ||
      loc == '/otp' ||
      loc == '/relogin-otp';

  // Onboarding routes need the concrete D2C auth service; in demo it's
  // absent (and the user is already signed in), so bounce to the dashboard.
  String? requireD2CAuth(BuildContext _, GoRouterState __) =>
      d2cAuth == null ? D2CRoutes.dashboard : null;

  return GoRouter(
    initialLocation: D2CRoutes.dashboard,
    refreshListenable: auth,
    redirect: (context, state) {
      final loc = state.matchedLocation;
      final signedIn = auth.isSignedIn;
      if (!signedIn && !isPublic(loc)) return '/sign-in';
      if (signedIn && (loc == '/sign-in' || loc == '/sign-up')) {
        return D2CRoutes.dashboard;
      }
      return null;
    },
    routes: [
      GoRoute(
        path: '/setup/:walkerId',
        builder: (context, state) => D2CSetupLandingScreen(
          walkerId: state.pathParameters['walkerId'] ?? '',
          repository: repository,
          signedIn: auth.isSignedIn,
        ),
      ),
      // QR re-login brokered-OTP (d2c-qr-relogin). Args (incl. the long
      // Cognito session) ride `extra`; on a reload that loses them, bounce to
      // phone sign-in. Needs the concrete D2C auth to adopt the session.
      GoRoute(
        path: '/relogin-otp',
        redirect: (context, state) {
          if (d2cAuth == null) return D2CRoutes.dashboard;
          if (state.extra is! ReloginArgs) return '/sign-in';
          return null;
        },
        builder: (context, state) => D2CReloginOtpScreen(
          auth: d2cAuth!,
          repository: repository,
          args: state.extra as ReloginArgs,
        ),
      ),
      // Care Circle invite landing (d2c-care-circle.md §5.9). Public: the
      // screen routes signed-out users into phone-first onboarding carrying
      // the invite id; membership is only granted server-side on a
      // verified-phone match, so the link itself is just a pointer.
      GoRoute(
        path: '/join/:inviteId',
        builder: (context, state) => D2CJoinScreen(
          inviteId: state.pathParameters['inviteId'] ?? '',
          repository: repository,
          signedIn: auth.isSignedIn,
        ),
      ),
      GoRoute(
        path: '/sign-up',
        redirect: requireD2CAuth,
        builder: (context, state) => D2CSignUpScreen(
          auth: d2cAuth!,
          walkerId: state.uri.queryParameters['walkerId'],
          joinInviteId: state.uri.queryParameters['join'],
          repository: repository,
          // Phone collected on the reserved landing, passed via router `extra`
          // (never the URL — no PII in query strings). Null on retail / reload.
          prefilledPhone: state.extra is String ? state.extra as String : null,
        ),
      ),
      GoRoute(
        path: '/sign-in',
        redirect: requireD2CAuth,
        builder: (context, state) => D2CSignInScreen(
          auth: d2cAuth!,
          joinInviteId: state.uri.queryParameters['join'],
        ),
      ),
      GoRoute(
        path: '/otp',
        redirect: requireD2CAuth,
        builder: (context, state) => D2COtpEntryScreen(
          auth: d2cAuth!,
          repository: repository,
          phoneHint: state.uri.queryParameters['phoneHint'] ?? '',
          walkerId: state.uri.queryParameters['walkerId'],
          joinInviteId: state.uri.queryParameters['join'],
        ),
      ),
      GoRoute(
        path: D2CRoutes.dashboard,
        builder: (context, state) => D2CDashboardHost(repository: repository),
      ),
      GoRoute(
        path: D2CRoutes.history,
        builder: (context, state) => D2CHistoryHost(repository: repository),
      ),
      GoRoute(
        path: D2CRoutes.careTeam,
        builder: (context, state) =>
            D2CCareTeamScreen(repository: repository),
      ),
      GoRoute(
        path: D2CRoutes.coach,
        builder: (context, state) => D2CCoachHost(repository: repository),
      ),
      GoRoute(
        path: D2CRoutes.coachMemory,
        builder: (context, state) =>
            D2CCoachMemoryHost(repository: repository),
      ),
      GoRoute(
        path: D2CRoutes.account,
        builder: (context, state) => D2CAccountHost(auth: auth),
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      backgroundColor: AppTheme.warmWhite,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
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
    ),
  );
}
