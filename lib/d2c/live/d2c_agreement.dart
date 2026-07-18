import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../config/d2c_legal.dart';
import '../../theme/app_theme.dart';

/// Which plain-language agreement to render (d2c-user-agreement.md vs
/// d2c-caregiver-agreement.md).
enum AgreementAudience { walker, caregiver }

/// On-screen plain-language user-agreement panel shown at onboarding.
///
/// A concise, large-type-friendly summary of what the person is agreeing to,
/// with tappable links to the full published Terms + Privacy pages and a
/// clickwrap acknowledgment line. The primary onboarding button ("Continue"
/// for the walker, "Join Care Circle" for the caregiver) is the acknowledgment
/// — this panel renders directly above it. The full agreements live in
/// `docs/specs/d2c-user-agreement.md` + `d2c-caregiver-agreement.md`; this is
/// the summary-and-link surface those docs specify.
class D2CAgreementPanel extends StatelessWidget {
  const D2CAgreementPanel({
    super.key,
    required this.audience,
    this.walkerName,
    this.deviceNoun = 'GoSteady device',
  });

  final AgreementAudience audience;

  /// Caregiver variant: the walker user's first name, if known. Falls back to
  /// "your family member" so the copy still reads.
  final String? walkerName;

  /// Walker variant: "walker", "rollator", or the neutral default — a Care
  /// Circle member may follow either form factor, so the caregiver copy stays
  /// device-neutral.
  final String deviceNoun;

  String get _who =>
      (walkerName != null && walkerName!.trim().isNotEmpty)
          ? walkerName!.trim()
          : 'your family member';

  List<String> get _points => audience == AgreementAudience.walker
      ? [
          'GoSteady notices how much you move each day, so you — and the '
              'family you choose — can see how your walking is going.',
          "It's not a doctor and it's not for emergencies. It does not detect "
              'falls. If you ever feel unwell, hurt, or unsafe, call 911 or a '
              'family member right away — don\'t wait on the app.',
          'No microphone, camera, or GPS — the $deviceNoun only senses '
              'movement.',
          "We'll text a code when you sign in, and — if you'd like — occasional "
              'notes about your activity. Reply STOP anytime. We never sell '
              'your number.',
          'You choose who sees your information, and you can remove them '
              'anytime. We never sell your information.',
          'You can ask us to delete your data and stop using GoSteady whenever '
              'you want. You should be 18 or older to set up an account.',
        ]
      : [
          "$_who's household invited you to see how they're getting around — "
              'activity and device health, read-only.',
          "This is $_who's personal information. Use it to support them — not "
              'to share, post, or screenshot.',
          "It's not a doctor and it's not for emergencies. It does not detect "
              "falls. If you're ever worried $_who is unwell or unsafe, call "
              'them or 911 right away — don\'t wait on the app.',
          'You can view activity and acknowledge a notification (a note for '
              'the family that you saw it — not a medical action).',
          "We'll text you a code, a note confirming your access, and — if "
              "you'd like — updates about $_who's activity. Reply STOP anytime. "
              'We never sell your number.',
          'You can leave the Care Circle anytime, and an Admin can remove you. '
              'You should be 18 or older to join.',
        ];

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.border),
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            audience == AgreementAudience.walker
                ? 'Before you start'
                : 'Before you join',
            style: const TextStyle(
              color: AppTheme.textDark,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          for (final p in _points)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 6, right: 10),
                    child: Container(
                      width: 5,
                      height: 5,
                      decoration: const BoxDecoration(
                        color: AppTheme.sage,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      p,
                      style: const TextStyle(
                        color: AppTheme.textDark,
                        fontSize: 14,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 4),
          _AcknowledgmentLine(audience: audience, who: _who),
        ],
      ),
    );
  }
}

/// The clickwrap line under the summary: "By continuing/joining, you agree to
/// the [Terms of Service] and [Privacy Policy]…" with tappable links.
class _AcknowledgmentLine extends StatelessWidget {
  const _AcknowledgmentLine({required this.audience, required this.who});

  final AgreementAudience audience;
  final String who;

  @override
  Widget build(BuildContext context) {
    final lead = audience == AgreementAudience.walker
        ? 'By continuing, you agree to the '
        : 'By joining, you agree to the ';
    final tail = audience == AgreementAudience.walker
        ? '.'
        : ", and to use $who's information only to support them.";
    return DefaultTextStyle(
      style: const TextStyle(
        color: AppTheme.textSoft,
        fontSize: 12.5,
        height: 1.45,
      ),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(lead),
          const _LegalLink('Terms of Service', D2CLegal.termsUrl),
          const Text(' and '),
          const _LegalLink('Privacy Policy', D2CLegal.privacyUrl),
          Text(tail),
        ],
      ),
    );
  }
}

class _LegalLink extends StatelessWidget {
  const _LegalLink(this.label, this.url);

  final String label;
  final String url;

  Future<void> _open() async {
    final uri = Uri.parse(url);
    // Web: opens a new tab. Best-effort — a launch failure just leaves the
    // acknowledgment text visible (the links are informational, the button
    // is the gate).
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _open,
      child: Text(
        label,
        style: const TextStyle(
          color: AppTheme.sage,
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          decoration: TextDecoration.underline,
          decorationColor: AppTheme.sage,
        ),
      ),
    );
  }
}
