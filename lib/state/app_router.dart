import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../auth/auth_service_interface.dart';
import '../d2c/d2c_preview.dart';
import '../d2c/data/d2c_repository.dart';
import '../d2c/live/d2c_live_screens.dart';
import '../d2c/screens/d2c_account_screens.dart';
import '../d2c/screens/d2c_care_team_screen.dart';
import '../d2c/screens/d2c_history_screen.dart';
import '../d2c/screens/d2c_onboarding_screens.dart';
import '../d2c/screens/d2c_state_screens.dart';
import '../dev/me_smoke_screen.dart';
import '../facility_demo/screens/facility_login_screen.dart';
import '../screens/analytics_screen.dart';
import '../screens/fleet_screen.dart';
import '../screens/login_screen.dart';
import '../screens/resident_detail_host.dart';
import '../screens/residents_screen.dart';
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
      // Dev preview routes for the D2C wireframe screens — accessible
      // without auth so we can iterate on screen design without a
      // real Cognito session. Remove once real D2C entry points
      // (sign-in / QR landing / claim landing) ship.
      if (state.matchedLocation.startsWith('/d2c/preview')) return null;

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
        // Internal users have no patients/census of their own — land them on
        // the fleet board, not the (customer-only) census, which 400s for
        // internal-tier callers (MISSING_CLIENT_PARAM).
        redirect: (context, state) =>
            auth.currentUser?.isInternal == true ? '/fleet' : '/census',
      ),
      GoRoute(
        path: '/census',
        // Guard: bounce internal users to /fleet so they never hit the
        // customer patient-list error if they land here directly.
        redirect: (context, state) =>
            auth.currentUser?.isInternal == true ? '/fleet' : null,
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
      // Internal fleet board — internal_admin (write) + internal_support
      // (read). Gated on the signed-in user's role (the first role-gated
      // route in the app); the device-api enforces server-side too.
      GoRoute(
        path: '/fleet',
        redirect: (context, state) =>
            auth.currentUser?.isInternal == true ? null : '/not-found',
        builder: (context, state) => const FleetScreen(),
      ),
      // Internal user & population analytics — same internal-only gate as
      // /fleet; the analytics-api enforces server-side too.
      // docs/specs/user-analytics.md.
      GoRoute(
        path: '/analytics',
        redirect: (context, state) =>
            auth.currentUser?.isInternal == true ? null : '/not-found',
        builder: (context, state) => const AnalyticsScreen(),
      ),
      // Internal "Pilot residents" — cross-tenant roster of active D2C
      // participants + per-resident monitoring detail. Same internal-only gate
      // as /fleet + /analytics; patient-api enforces server-side.
      // docs/specs/user-analytics.md §pilot view.
      GoRoute(
        path: '/residents',
        redirect: (context, state) =>
            auth.currentUser?.isInternal == true ? null : '/not-found',
        builder: (context, state) => const ResidentsScreen(),
      ),
      GoRoute(
        path: '/residents/:patientId',
        redirect: (context, state) =>
            auth.currentUser?.isInternal == true ? null : '/not-found',
        builder: (context, state) =>
            ResidentDetailHost(patientId: state.pathParameters['patientId']!),
      ),
      GoRoute(
        path: '/not-found',
        builder: (context, state) => const _NotFoundScreen(),
      ),
      // ── D2C wireframe preview (dev-only) ──────────────────────────
      // Mounted at /d2c/preview/* so the auth redirect in this router
      // can carve it out cleanly. Throwaway entry point; the real
      // /d2c routes will be added once we have backend wiring.
      GoRoute(
        path: '/d2c/preview',
        builder: (context, state) => const D2CPreviewHub(),
      ),
      // Dashboard
      GoRoute(
        path: '/d2c/preview/dashboard',
        builder: (context, state) => const D2CDashboardPreview(),
      ),
      GoRoute(
        path: '/d2c/preview/dashboard-empty',
        builder: (context, state) => const D2CDashboardEmptyPreview(),
      ),
      GoRoute(
        path: '/d2c/preview/dashboard-preactivation',
        builder: (context, state) => const D2CDashboardPreActivationPreview(),
      ),
      GoRoute(
        path: '/d2c/preview/history',
        builder: (context, state) => const D2CHistoryScreen(),
      ),
      // Care Team
      GoRoute(
        path: '/d2c/preview/care-team',
        builder: (context, state) => const D2CCareTeamScreen(
          repository: D2CMockRepository(),
          viewerIsAdmin: true,
        ),
      ),
      GoRoute(
        path: '/d2c/preview/care-team-member',
        builder: (context, state) => const D2CCareTeamScreen(
          repository: D2CMockRepository(),
          viewerIsAdmin: false,
        ),
      ),
      // Coach ("Steady") — mock-backed hosts. Kept in sync with the shared
      // D2CBottomNav's Coach tab so it resolves in this preview hub too.
      GoRoute(
        path: '/d2c/preview/coach',
        builder: (context, state) =>
            const D2CCoachHost(repository: D2CMockRepository()),
      ),
      GoRoute(
        path: '/d2c/preview/coach/memory',
        builder: (context, state) =>
            const D2CCoachMemoryHost(repository: D2CMockRepository()),
      ),
      // Onboarding — QR walk-up
      GoRoute(
        path: '/d2c/preview/onboarding/qr-unclaimed',
        builder: (context, state) => const QrUnclaimedScreen(),
      ),
      GoRoute(
        path: '/d2c/preview/onboarding/qr-claimed',
        builder: (context, state) => const QrClaimedScreen(),
      ),
      GoRoute(
        path: '/d2c/preview/onboarding/qr-request',
        builder: (context, state) => const QrRequestAccessScreen(),
      ),
      GoRoute(
        path: '/d2c/preview/onboarding/qr-decommissioned',
        builder: (context, state) => const QrDecommissionedScreen(),
      ),
      // Onboarding — accounts
      GoRoute(
        path: '/d2c/preview/onboarding/claim',
        builder: (context, state) => const ClaimInviteScreen(),
      ),
      GoRoute(
        path: '/d2c/preview/onboarding/sign-in',
        builder: (context, state) => const SignInScreen(),
      ),
      GoRoute(
        path: '/d2c/preview/onboarding/otp',
        builder: (context, state) => const OtpScreen(),
      ),
      GoRoute(
        path: '/d2c/preview/onboarding/sign-up',
        builder: (context, state) => const SignUpScreen(),
      ),
      GoRoute(
        path: '/d2c/preview/onboarding/welcome',
        builder: (context, state) => const WelcomeWizardScreen(),
      ),
      // Account
      GoRoute(
        path: '/d2c/preview/account',
        builder: (context, state) => const D2CAccountSettingsScreen(),
      ),
      GoRoute(
        path: '/d2c/preview/account/notifications',
        builder: (context, state) => const D2CNotificationPrefsScreen(),
      ),
      GoRoute(
        path: '/d2c/preview/account/audit',
        builder: (context, state) => const D2CAuditScreen(),
      ),
      GoRoute(
        path: '/d2c/preview/account/device',
        builder: (context, state) => const D2CDeviceSettingsScreen(),
      ),
      // Edge-case states
      GoRoute(
        path: '/d2c/preview/states/link-expired',
        builder: (context, state) => const LinkExpiredScreen(),
      ),
      GoRoute(
        path: '/d2c/preview/states/link-used',
        builder: (context, state) => const LinkUsedScreen(),
      ),
      GoRoute(
        path: '/d2c/preview/states/request-denied',
        builder: (context, state) => const RequestDeniedScreen(),
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
