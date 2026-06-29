import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../theme/app_theme.dart';
import 'data/d2c_mock_data.dart';
import 'screens/d2c_dashboard_screen.dart';

/// Dev-only preview harness for the D2C wireframe screens.
///
/// [D2CPreviewHub] is the index — a tappable directory of every mockup
/// screen, so the deployed build can be reviewed end-to-end on a phone.
/// Individual screen routes live in [app_router.dart] under
/// `/d2c/preview/*` (auth redirect is bypassed for that prefix).
///
/// Remove the whole preview surface once the real D2C entry points
/// (sign-in / QR landing / claim landing) are wired to live data.

// ─────────────────────────────────────────────────────────────────────
// Dashboard preview wrappers (carry the dev viewer toggle)
// ─────────────────────────────────────────────────────────────────────

class D2CDashboardPreview extends StatefulWidget {
  const D2CDashboardPreview({super.key, this.startAsWalkerUser = false});

  /// Which copy variant the dashboard opens in. The in-app person-icon
  /// toggle still flips between the two regardless. Defaults to the
  /// caregiver (Admin) view for the wireframe hub; the user demo
  /// (`main_userdemo.dart`) opens in the walker-user view.
  final bool startAsWalkerUser;

  @override
  State<D2CDashboardPreview> createState() => _D2CDashboardPreviewState();
}

class _D2CDashboardPreviewState extends State<D2CDashboardPreview> {
  late bool _asWalkerUser = widget.startAsWalkerUser;

  @override
  Widget build(BuildContext context) {
    final snap = _asWalkerUser
        ? D2CMockData.susanViewedBySelf()
        : D2CMockData.susanViewedBySarah();
    return D2CDashboardScreen(
      snapshot: snap,
      onSwitchViewer: () => setState(() => _asWalkerUser = !_asWalkerUser),
    );
  }
}

class D2CDashboardEmptyPreview extends StatelessWidget {
  const D2CDashboardEmptyPreview({super.key});
  @override
  Widget build(BuildContext context) =>
      D2CDashboardScreen(snapshot: D2CMockData.susanEmptyToday());
}

class D2CDashboardPreActivationPreview extends StatelessWidget {
  const D2CDashboardPreActivationPreview({super.key});
  @override
  Widget build(BuildContext context) =>
      D2CDashboardScreen(snapshot: D2CMockData.susanPreActivation());
}

// ─────────────────────────────────────────────────────────────────────
// Preview hub (index of all screens)
// ─────────────────────────────────────────────────────────────────────

class _PreviewItem {
  const _PreviewItem(this.label, this.route, {this.note});
  final String label;
  final String route;
  final String? note;
}

class _PreviewGroup {
  const _PreviewGroup(this.title, this.items);
  final String title;
  final List<_PreviewItem> items;
}

const _groups = <_PreviewGroup>[
  _PreviewGroup('Dashboard', [
    _PreviewItem('Home — activity', '/d2c/preview/dashboard',
        note: 'Tap the person icon to flip caregiver ↔ walker-user'),
    _PreviewItem('Home — no activity yet', '/d2c/preview/dashboard-empty'),
    _PreviewItem(
        'Home — walker on the way', '/d2c/preview/dashboard-preactivation'),
    _PreviewItem('History — 30 / 90 days', '/d2c/preview/history',
        note: 'Behind the trend "See more"'),
  ]),
  _PreviewGroup('Care Team', [
    _PreviewItem('Care Team — admin view', '/d2c/preview/care-team',
        note: 'Invite, approve requests, manage members'),
    _PreviewItem('Care Team — member view', '/d2c/preview/care-team-member',
        note: 'Read-only roster'),
  ]),
  _PreviewGroup('Onboarding — QR walk-up', [
    _PreviewItem('QR — unclaimed device', '/d2c/preview/onboarding/qr-unclaimed'),
    _PreviewItem('QR — already claimed', '/d2c/preview/onboarding/qr-claimed'),
    _PreviewItem('QR — request access', '/d2c/preview/onboarding/qr-request'),
    _PreviewItem(
        'QR — decommissioned', '/d2c/preview/onboarding/qr-decommissioned'),
  ]),
  _PreviewGroup('Onboarding — accounts', [
    _PreviewItem('Invite link landing', '/d2c/preview/onboarding/claim'),
    _PreviewItem('Sign in', '/d2c/preview/onboarding/sign-in'),
    _PreviewItem('Enter code (SMS)', '/d2c/preview/onboarding/otp'),
    _PreviewItem('Sign up', '/d2c/preview/onboarding/sign-up'),
    _PreviewItem('Welcome wizard', '/d2c/preview/onboarding/welcome'),
  ]),
  _PreviewGroup('Account', [
    _PreviewItem('Account settings', '/d2c/preview/account'),
    _PreviewItem('Notification preferences', '/d2c/preview/account/notifications'),
    _PreviewItem("Who's accessed the data", '/d2c/preview/account/audit'),
    _PreviewItem('Device settings', '/d2c/preview/account/device'),
  ]),
  _PreviewGroup('Edge cases', [
    _PreviewItem('Link expired', '/d2c/preview/states/link-expired'),
    _PreviewItem('Link already used', '/d2c/preview/states/link-used'),
    _PreviewItem('Request declined', '/d2c/preview/states/request-denied'),
  ]),
];

class D2CPreviewHub extends StatelessWidget {
  const D2CPreviewHub({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.warmWhite,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
              children: [
                Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: AppTheme.sage,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.accessibility_new_rounded,
                          color: Colors.white, size: 22),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      'D2C wireframes',
                      style:
                          Theme.of(context).textTheme.headlineMedium?.copyWith(
                                fontSize: 24,
                                fontWeight: FontWeight.w600,
                              ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  'Mock screens for the household / Care Circle product. '
                  'Tap any screen to view it. Everything is mock data — no '
                  'sign-in needed.',
                  style: TextStyle(
                      color: AppTheme.textSoft, fontSize: 14, height: 1.45),
                ),
                const SizedBox(height: 24),
                for (final g in _groups) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
                    child: Text(
                      g.title.toUpperCase(),
                      style: const TextStyle(
                        color: AppTheme.textSoft,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.0,
                      ),
                    ),
                  ),
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: AppTheme.cardShadow,
                    ),
                    child: Column(
                      children: [
                        for (var i = 0; i < g.items.length; i++) ...[
                          _HubRow(item: g.items[i]),
                          if (i < g.items.length - 1)
                            Divider(
                                height: 1,
                                color: AppTheme.border.withOpacity(0.5)),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HubRow extends StatelessWidget {
  const _HubRow({required this.item});
  final _PreviewItem item;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => context.go(item.route),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.label,
                      style: const TextStyle(
                          color: AppTheme.textDark,
                          fontSize: 15,
                          fontWeight: FontWeight.w500)),
                  if (item.note != null) ...[
                    const SizedBox(height: 2),
                    Text(item.note!,
                        style: const TextStyle(
                            color: AppTheme.textSoft, fontSize: 12, height: 1.3)),
                  ],
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                size: 20, color: AppTheme.textSoft.withOpacity(0.7)),
          ],
        ),
      ),
    );
  }
}
