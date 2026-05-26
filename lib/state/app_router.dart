import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../auth/auth_service_interface.dart';
import '../dev/me_smoke_screen.dart';
import '../facility_demo/screens/facility_login_screen.dart';
import '../screens/login_screen.dart';
import 'build_mode.dart';

/// Builds the GoRouter for the current [BuildMode].
///
/// Demo mode hides the live-only routes (`/forgot-password`,
/// `/mfa-setup`, `/mfa-verify`, `/dev/me`) — they return 404
/// in-app rather than ever rendering with a mock-auth session.
///
/// Per phase-2b-0-foundation.md L9 + L10 + §Scope > Routes table.
///
/// **2B-0 scope:** the `/patients/:patientId` deep-link route is stubbed
/// here (lands at the Census with the selected patient overlay). True
/// deep-link rendering polish is 2B-FAC-R / 2B-POL.
GoRouter buildAppRouter({
  required AuthServiceInterface auth,
  required BuildMode buildMode,
  required Widget Function(BuildContext) facilityHomeBuilder,
}) {
  return GoRouter(
    initialLocation: '/',
    refreshListenable: auth,
    redirect: (context, state) {
      final signedIn = auth.isSignedIn;
      final atLogin = state.matchedLocation == '/sign-in';
      if (!signedIn && !atLogin) return '/sign-in';
      if (signedIn && atLogin) return '/';
      return null;
    },
    routes: [
      GoRoute(
        path: '/sign-in',
        builder: (context, state) {
          if (buildMode.isDemo) {
            return const FacilityLoginScreen();
          }
          return LoginScreen(onSignedIn: (_) {
            // GoRouter's refreshListenable picks up the auth change
            // and re-runs the redirect; nothing more needed here.
          });
        },
      ),
      GoRoute(
        path: '/',
        redirect: (context, state) => '/census',
      ),
      GoRoute(
        path: '/census',
        builder: (context, state) => facilityHomeBuilder(context),
      ),
      GoRoute(
        path: '/patients/:patientId',
        builder: (context, state) {
          // 2B-0 stub: route resolves to the Facility shell. Selected-
          // patient deep-linking lands in 2B-FAC-R; for now this just
          // brings the user to the Census from a shared URL.
          return facilityHomeBuilder(context);
        },
      ),
      GoRoute(
        path: '/dev/me',
        redirect: (context, state) =>
            buildMode.isLive ? null : '/not-found',
        builder: (context, state) => const MeSmokeScreen(),
      ),
      GoRoute(
        path: '/not-found',
        builder: (context, state) => const _NotFoundScreen(),
      ),
    ],
    errorBuilder: (context, state) => const _NotFoundScreen(),
  );
}

class _NotFoundScreen extends StatelessWidget {
  const _NotFoundScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '404',
              style: Theme.of(context).textTheme.displayLarge,
            ),
            const SizedBox(height: 8),
            Text(
              'Page not found',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: () =>
                  Navigator.of(context).pushNamedAndRemoveUntil('/', (_) => false),
              child: const Text('Back to home'),
            ),
          ],
        ),
      ),
    );
  }
}
