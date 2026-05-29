import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../theme/app_theme.dart';

/// Terminal / edge-case state screens — simple centered messages with a
/// single recovery action. Reused for expired/used magic links and
/// declined access requests.

class _StateScreen extends StatelessWidget {
  const _StateScreen({
    required this.icon,
    required this.title,
    required this.body,
    required this.actionLabel,
    required this.onAction,
    this.iconColor,
    this.secondaryLabel,
    this.onSecondary,
  });

  final IconData icon;
  final String title;
  final String body;
  final String actionLabel;
  final VoidCallback onAction;
  final Color? iconColor;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) {
    final c = iconColor ?? AppTheme.textSoft;
    return Scaffold(
      backgroundColor: AppTheme.warmWhite,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 76,
                    height: 76,
                    decoration: BoxDecoration(
                      color: c.withOpacity(0.10),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(icon, size: 36, color: c),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          fontSize: 23,
                          height: 1.2,
                        ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    body,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: AppTheme.textSoft, fontSize: 15, height: 1.5),
                  ),
                  const SizedBox(height: 28),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: onAction,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTheme.sage,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(100)),
                      ),
                      child: Text(actionLabel,
                          style: const TextStyle(
                              fontWeight: FontWeight.w600, fontSize: 15.5)),
                    ),
                  ),
                  if (secondaryLabel != null) ...[
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: onSecondary,
                      style:
                          TextButton.styleFrom(foregroundColor: AppTheme.textSoft),
                      child: Text(secondaryLabel!,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class LinkExpiredScreen extends StatelessWidget {
  const LinkExpiredScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return _StateScreen(
      icon: Icons.hourglass_disabled_rounded,
      title: 'This link has expired',
      body: 'Invite links are good for 14 days. Ask Sarah to send you a fresh '
          'one — it only takes a second.',
      actionLabel: 'Back to sign in',
      onAction: () => context.go('/d2c/preview/onboarding/sign-in'),
    );
  }
}

class LinkUsedScreen extends StatelessWidget {
  const LinkUsedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return _StateScreen(
      icon: Icons.check_circle_outline_rounded,
      iconColor: AppTheme.sage,
      title: 'This link was already used',
      body: 'Looks like this invite has already been accepted. Try signing in '
          'with the email it was sent to.',
      actionLabel: 'Sign in',
      onAction: () => context.go('/d2c/preview/onboarding/sign-in'),
    );
  }
}

class RequestDeniedScreen extends StatelessWidget {
  const RequestDeniedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return _StateScreen(
      icon: Icons.do_not_disturb_alt_rounded,
      title: 'Request not approved',
      body: "Your request to follow Susan's walker wasn't approved. If you "
          'think this is a mistake, reach out to the family directly.',
      actionLabel: 'Done',
      onAction: () => context.go('/d2c/preview'),
    );
  }
}
