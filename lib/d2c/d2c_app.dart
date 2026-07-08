import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../auth/auth_service_interface.dart';
import '../theme/app_theme.dart';
import 'auth/d2c_auth_service.dart';
import 'd2c_routes.dart';
import 'data/d2c_repository.dart';
import 'live/d2c_live_screens.dart';

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
      loc == '/sign-in' ||
      loc == '/sign-up' ||
      loc == '/otp';

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
      GoRoute(
        path: '/sign-up',
        redirect: requireD2CAuth,
        builder: (context, state) => D2CSignUpScreen(
          auth: d2cAuth!,
          walkerId: state.uri.queryParameters['walkerId'],
        ),
      ),
      GoRoute(
        path: '/sign-in',
        redirect: requireD2CAuth,
        builder: (context, state) => D2CSignInScreen(auth: d2cAuth!),
      ),
      GoRoute(
        path: '/otp',
        redirect: requireD2CAuth,
        builder: (context, state) => D2COtpEntryScreen(
          auth: d2cAuth!,
          repository: repository,
          phoneHint: state.uri.queryParameters['phoneHint'] ?? '',
          walkerId: state.uri.queryParameters['walkerId'],
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
        builder: (context, state) => const D2CCareTeamPlaceholder(),
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
