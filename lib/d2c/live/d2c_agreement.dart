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

  /// [_who] at the start of a sentence ("Your family member's household…").
  String get _whoStart => _who[0].toUpperCase() + _who.substring(1);

  /// (bold lead-in, plain body) per point. The assistance + location points
  /// track PRD V2.3 §5 (Family Assistance Alert): GPS only on a button press
  /// or test, family notification only — never 911 / a monitoring center
  /// (AST-SW-07). "Once … set up" keeps the copy true before the feature is
  /// armed for a household (AST-SW-05 gates it on consent + a contact).
  List<(String, String)> get _points => audience == AgreementAudience.walker
      ? [
          (
            'Your activity.',
            'GoSteady notices how much you move each day, so you — and the '
                'family you choose — can see how your walking is going.',
          ),
          (
            'Asking for help.',
            'Once assistance alerts are set up, press the assistance button on '
                'your $deviceNoun. It beeps for 20 seconds, then GoSteady calls '
                'and texts your Care Circle. To cancel, hold the button down for '
                '3 seconds.',
          ),
          (
            'Your location.',
            'GPS is used only when the assistance button is pressed or tested '
                '— to help your Care Circle find you. It never tracks where you '
                "go. There's no microphone or camera.",
          ),
          (
            'Family, not 911.',
            'Alerts go to your family — not to 911 or a monitoring center — and '
                "someone may not answer. GoSteady isn't a doctor and doesn't "
                'detect falls. In an emergency, call 911.',
          ),
          (
            'Text messages.',
            "We'll text a code when you sign in, and — if you'd like — "
                'occasional notes about your activity. Reply STOP anytime. We '
                'never sell your number.',
          ),
          (
            'Who sees it.',
            'You choose who sees your information, and you can remove them '
                'anytime. We never sell your information.',
          ),
          (
            'Your choices.',
            'You can ask us to delete your data and stop using GoSteady '
                'whenever you want. You should be 18 or older to set up an '
                'account.',
          ),
        ]
      : [
          (
            'What you see.',
            "$_whoStart's household invited you to see how they're getting around — "
                'activity and device health, read-only.',
          ),
          (
            'Assistance alerts.',
            'If you turn them on, GoSteady will call and text you when $_who '
                'presses their assistance button, with their location when '
                "it's available. These are automated calls and texts.",
          ),
          (
            'Family, not 911.',
            "GoSteady doesn't contact 911 or a monitoring center, doesn't detect "
                "falls, and isn't a doctor. When $_who asks for help, you decide "
                "what to do — including calling 911. If you're worried, don't "
                'wait on the app.',
          ),
          (
            'Acknowledging.',
            'You can view activity and acknowledge a notification — a note for '
                'the family that you saw it, not a medical action.',
          ),
          (
            'Text messages.',
            "We'll text you a code, a note confirming your access, and — if "
                "you'd like — updates about $_who's activity. Reply STOP anytime. "
                'We never sell your number.',
          ),
          (
            'Leaving.',
            'You can leave the Care Circle anytime, and an Admin can remove you. '
                'You should be 18 or older to join.',
          ),
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
          for (final (lead, body) in _points)
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
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: '$lead ',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          TextSpan(text: body),
                        ],
                      ),
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
    // One paragraph with the links as inline spans, so it wraps like prose — a
    // Wrap of separate Text widgets left a stray leading space on line two.
    const link = PlaceholderAlignment.baseline;
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: lead),
          const WidgetSpan(
            alignment: link,
            baseline: TextBaseline.alphabetic,
            child: _LegalLink('Terms of Service', D2CLegal.termsUrl),
          ),
          const TextSpan(text: ' and '),
          const WidgetSpan(
            alignment: link,
            baseline: TextBaseline.alphabetic,
            child: _LegalLink('Privacy Policy', D2CLegal.privacyUrl),
          ),
          TextSpan(text: tail),
        ],
      ),
      style: const TextStyle(
        color: AppTheme.textSoft,
        fontSize: 12.5,
        height: 1.45,
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
