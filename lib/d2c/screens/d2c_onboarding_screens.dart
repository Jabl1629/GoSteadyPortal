import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../theme/app_theme.dart';

/// Public / onboarding screens for the D2C flow. These render WITHOUT
/// the signed-in app shell — they're the screens a person sees before
/// (or while) joining a Care Circle:
///
///   - QR walk-up landing (4 states: unclaimed / claimed / request /
///     decommissioned)
///   - Claim-invite landing (from an emailed/texted invite link)
///   - Sign-in (email) → SMS-OTP code entry
///   - Sign-up (new walk-up)
///   - Welcome wizard (rare first-Admin "ops didn't pre-fill" path)
///
/// All share [_LandingScaffold]: centered card on warm-white, GoSteady
/// wordmark up top, no bottom nav. Mobile-first; max width 460.

// ─────────────────────────────────────────────────────────────────────
// Shared landing chrome
// ─────────────────────────────────────────────────────────────────────

class _LandingScaffold extends StatelessWidget {
  const _LandingScaffold({required this.child, this.onBack});
  final Widget child;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.warmWhite,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
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
                        'GoSteady',
                        style:
                            Theme.of(context).textTheme.headlineMedium?.copyWith(
                                  fontSize: 24,
                                  fontWeight: FontWeight.w600,
                                ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 36),
                  child,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Rounded white card used for the landing content block.
class _Card extends StatelessWidget {
  const _Card({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppTheme.cardRadius),
        boxShadow: AppTheme.cardShadow,
      ),
      child: child,
    );
  }
}

Widget _primaryButton(String label, VoidCallback onTap) {
  return SizedBox(
    width: double.infinity,
    child: FilledButton(
      onPressed: onTap,
      style: FilledButton.styleFrom(
        backgroundColor: AppTheme.sage,
        padding: const EdgeInsets.symmetric(vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(100)),
      ),
      child: Text(label,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15.5)),
    ),
  );
}

Widget _secondaryButton(String label, VoidCallback onTap) {
  return SizedBox(
    width: double.infinity,
    child: OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        foregroundColor: AppTheme.textDark,
        side: BorderSide(color: AppTheme.border),
        padding: const EdgeInsets.symmetric(vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(100)),
      ),
      child: Text(label,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15.5)),
    ),
  );
}

Widget _heroIcon(IconData icon, {Color? color}) {
  final c = color ?? AppTheme.sage;
  return Center(
    child: Container(
      width: 72,
      height: 72,
      decoration: BoxDecoration(
        color: c.withOpacity(0.10),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, size: 34, color: c),
    ),
  );
}

Widget _title(BuildContext context, String text, {TextAlign align = TextAlign.center}) {
  return Text(
    text,
    textAlign: align,
    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
          fontSize: 23,
          height: 1.2,
        ),
  );
}

Widget _body(String text, {TextAlign align = TextAlign.center}) {
  return Text(
    text,
    textAlign: align,
    style: const TextStyle(color: AppTheme.textSoft, fontSize: 15, height: 1.5),
  );
}

// ─────────────────────────────────────────────────────────────────────
// QR landing — unclaimed (fresh device, no owner yet)
// ─────────────────────────────────────────────────────────────────────

class QrUnclaimedScreen extends StatelessWidget {
  const QrUnclaimedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return _LandingScaffold(
      child: _Card(
        child: Column(
          children: [
            _heroIcon(Icons.directions_walk_rounded),
            const SizedBox(height: 22),
            _title(context, 'Set up this walker'),
            const SizedBox(height: 12),
            _body(
              "You've scanned a GoSteady cap that hasn't been set up yet. "
              'Create an account or sign in to connect it and start seeing '
              'activity.',
            ),
            const SizedBox(height: 24),
            _primaryButton('Get started', () => context.go('/d2c/preview/onboarding/sign-up')),
            const SizedBox(height: 12),
            _secondaryButton('I already have an account',
                () => context.go('/d2c/preview/onboarding/sign-in')),
            const SizedBox(height: 18),
            Text(
              'Device GS0000004421',
              style: TextStyle(
                color: AppTheme.textSoft.withOpacity(0.7),
                fontSize: 12,
                fontFamily: 'monospace',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// QR landing — claimed (pre-claim race / wrong person)
// ─────────────────────────────────────────────────────────────────────

class QrClaimedScreen extends StatelessWidget {
  const QrClaimedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return _LandingScaffold(
      child: _Card(
        child: Column(
          children: [
            _heroIcon(Icons.lock_outline_rounded),
            const SizedBox(height: 22),
            _title(context, 'This walker is already set up'),
            const SizedBox(height: 12),
            _body(
              'It\'s registered to s•••@gmail.com. If that\'s you, sign in '
              'to manage it. Otherwise, ask the person who set it up to add '
              'you to the Care Team.',
            ),
            const SizedBox(height: 24),
            _primaryButton('Sign in to manage',
                () => context.go('/d2c/preview/onboarding/sign-in')),
            const SizedBox(height: 12),
            _secondaryButton('Ask to be added',
                () => context.go('/d2c/preview/onboarding/qr-request')),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// QR landing — request access (with required note)
// ─────────────────────────────────────────────────────────────────────

class QrRequestAccessScreen extends StatefulWidget {
  const QrRequestAccessScreen({super.key});

  @override
  State<QrRequestAccessScreen> createState() => _QrRequestAccessScreenState();
}

class _QrRequestAccessScreenState extends State<QrRequestAccessScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _relationship = TextEditingController();
  final _note = TextEditingController();
  bool _sent = false;

  @override
  void dispose() {
    _name.dispose();
    _relationship.dispose();
    _note.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _sent = true);
  }

  @override
  Widget build(BuildContext context) {
    if (_sent) {
      return _LandingScaffold(
        child: _Card(
          child: Column(
            children: [
              _heroIcon(Icons.mark_email_read_outlined),
              const SizedBox(height: 22),
              _title(context, 'Request sent'),
              const SizedBox(height: 12),
              _body(
                'We let the walker\'s admin know you\'d like access. '
                'You\'ll get a text as soon as they approve it.',
              ),
              const SizedBox(height: 24),
              _primaryButton('Done', () => context.go('/d2c/preview')),
            ],
          ),
        ),
      );
    }
    return _LandingScaffold(
      child: _Card(
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _title(context, "Ask to follow Susan's walker"),
              const SizedBox(height: 10),
              _body(
                "This walker belongs to Sarah's household. Send a quick note "
                'and they can add you to the Care Team.',
              ),
              const SizedBox(height: 22),
              _LabeledField(
                controller: _name,
                label: 'Your name',
                hint: 'e.g. Tom',
                textCapitalization: TextCapitalization.words,
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              const SizedBox(height: 14),
              _LabeledField(
                controller: _relationship,
                label: 'Relationship to Susan',
                hint: 'e.g. Grandson',
                textCapitalization: TextCapitalization.words,
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              const SizedBox(height: 14),
              _LabeledField(
                controller: _note,
                label: 'Add a note',
                hint: "Hi Grandma, it's Tom — I'd like to keep an eye on "
                    'your walks.',
                maxLines: 3,
                textCapitalization: TextCapitalization.sentences,
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Please add a short note' : null,
              ),
              const SizedBox(height: 22),
              _primaryButton('Send request', _submit),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// QR landing — decommissioned
// ─────────────────────────────────────────────────────────────────────

class QrDecommissionedScreen extends StatelessWidget {
  const QrDecommissionedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return _LandingScaffold(
      child: _Card(
        child: Column(
          children: [
            _heroIcon(Icons.power_off_rounded, color: AppTheme.textSoft),
            const SizedBox(height: 22),
            _title(context, 'This walker is no longer active'),
            const SizedBox(height: 12),
            _body(
              'This GoSteady cap has been retired and can\'t be set up. '
              'If you think this is a mistake, reach out to support.',
            ),
            const SizedBox(height: 24),
            _secondaryButton('Contact support', () {}),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Claim-invite landing (from emailed / texted invite link)
// ─────────────────────────────────────────────────────────────────────

class ClaimInviteScreen extends StatelessWidget {
  const ClaimInviteScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return _LandingScaffold(
      child: _Card(
        child: Column(
          children: [
            _heroIcon(Icons.favorite_outline_rounded),
            const SizedBox(height: 22),
            _title(context, 'Sarah invited you'),
            const SizedBox(height: 12),
            _body(
              "Sarah added you to Susan's Care Team so you can follow her "
              'walking activity and get alerts. Set up your account to get '
              'started.',
            ),
            const SizedBox(height: 24),
            _primaryButton('Accept & continue',
                () => context.go('/d2c/preview/onboarding/sign-up')),
            const SizedBox(height: 14),
            Text(
              'Invited as a Member · expires in 12 days',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppTheme.textSoft.withOpacity(0.8),
                fontSize: 12.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Sign-in (email entry → OTP)
// ─────────────────────────────────────────────────────────────────────

class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key});

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    context.go('/d2c/preview/onboarding/otp');
  }

  @override
  Widget build(BuildContext context) {
    return _LandingScaffold(
      child: _Card(
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _title(context, 'Welcome back'),
              const SizedBox(height: 10),
              _body("Enter your email and we'll text you a code to sign in."),
              const SizedBox(height: 22),
              _LabeledField(
                controller: _email,
                label: 'Email',
                hint: 'name@example.com',
                keyboardType: TextInputType.emailAddress,
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return 'Required';
                  if (!v.contains('@')) return 'Enter a valid email';
                  return null;
                },
              ),
              const SizedBox(height: 22),
              _primaryButton('Send code', _submit),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// SMS-OTP code entry
// ─────────────────────────────────────────────────────────────────────

class OtpScreen extends StatelessWidget {
  const OtpScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return _LandingScaffold(
      child: _Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _title(context, 'Enter your code'),
            const SizedBox(height: 10),
            _body('We texted a 6-digit code to your phone.'),
            const SizedBox(height: 24),
            const _OtpBoxes(),
            const SizedBox(height: 24),
            _primaryButton('Verify & sign in',
                () => context.go('/d2c/preview/dashboard')),
            const SizedBox(height: 16),
            Center(
              child: TextButton(
                onPressed: () {},
                style: TextButton.styleFrom(foregroundColor: AppTheme.sage),
                child: const Text('Resend code',
                    style: TextStyle(fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OtpBoxes extends StatelessWidget {
  const _OtpBoxes();

  @override
  Widget build(BuildContext context) {
    // Static visual mock — 6 boxes, first 3 "filled".
    final filled = ['4', '8', '2', '', '', ''];
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        for (var i = 0; i < 6; i++)
          Container(
            width: 46,
            height: 56,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: i == 3 ? AppTheme.sage : AppTheme.border,
                width: i == 3 ? 2 : 1,
              ),
            ),
            child: Text(
              filled[i],
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: AppTheme.textDark,
              ),
            ),
          ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Sign-up (new walk-up account)
// ─────────────────────────────────────────────────────────────────────

class SignUpScreen extends StatefulWidget {
  const SignUpScreen({super.key});

  @override
  State<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends State<SignUpScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _phone.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    context.go('/d2c/preview/onboarding/otp');
  }

  @override
  Widget build(BuildContext context) {
    return _LandingScaffold(
      child: _Card(
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _title(context, 'Create your account'),
              const SizedBox(height: 10),
              _body("We'll text you a code to confirm your number."),
              const SizedBox(height: 22),
              _LabeledField(
                controller: _name,
                label: 'Your name',
                hint: 'e.g. Michael',
                textCapitalization: TextCapitalization.words,
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              const SizedBox(height: 14),
              _LabeledField(
                controller: _email,
                label: 'Email',
                hint: 'name@example.com',
                keyboardType: TextInputType.emailAddress,
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return 'Required';
                  if (!v.contains('@')) return 'Enter a valid email';
                  return null;
                },
              ),
              const SizedBox(height: 14),
              _LabeledField(
                controller: _phone,
                label: 'Mobile number',
                hint: '(555) 123-4567',
                keyboardType: TextInputType.phone,
                validator: (v) =>
                    (v == null || v.trim().length < 7) ? 'Enter a valid number' : null,
              ),
              const SizedBox(height: 14),
              const _ConsentLine(),
              const SizedBox(height: 20),
              _primaryButton('Continue', _submit),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConsentLine extends StatelessWidget {
  const _ConsentLine();

  @override
  Widget build(BuildContext context) {
    return Text(
      'By continuing you agree to receive account and alert texts from '
      'GoSteady. Message and data rates may apply. Reply STOP to opt out.',
      style: TextStyle(
        color: AppTheme.textSoft.withOpacity(0.85),
        fontSize: 11.5,
        height: 1.4,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Welcome wizard — first-Admin path (ops didn't pre-fill walker info)
// ─────────────────────────────────────────────────────────────────────

class WelcomeWizardScreen extends StatefulWidget {
  const WelcomeWizardScreen({super.key});

  @override
  State<WelcomeWizardScreen> createState() => _WelcomeWizardScreenState();
}

class _WelcomeWizardScreenState extends State<WelcomeWizardScreen> {
  final _formKey = GlobalKey<FormState>();
  final _walkerName = TextEditingController();
  final _relationship = TextEditingController();

  @override
  void dispose() {
    _walkerName.dispose();
    _relationship.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    context.go('/d2c/preview/dashboard');
  }

  @override
  Widget build(BuildContext context) {
    return _LandingScaffold(
      child: _Card(
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _heroIcon(Icons.waving_hand_outlined),
              const SizedBox(height: 22),
              _title(context, "Who's using the walker?"),
              const SizedBox(height: 10),
              _body(
                "Tell us a little about the person you're setting this up "
                'for. You can always change this later.',
              ),
              const SizedBox(height: 22),
              _LabeledField(
                controller: _walkerName,
                label: 'Their first name',
                hint: 'e.g. Susan',
                textCapitalization: TextCapitalization.words,
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              const SizedBox(height: 14),
              _LabeledField(
                controller: _relationship,
                label: 'Your relationship to them',
                hint: 'e.g. Daughter',
                textCapitalization: TextCapitalization.words,
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              const SizedBox(height: 22),
              _primaryButton('Finish setup', _submit),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Shared labeled field
// ─────────────────────────────────────────────────────────────────────

class _LabeledField extends StatelessWidget {
  const _LabeledField({
    required this.controller,
    required this.label,
    this.hint,
    this.keyboardType,
    this.textCapitalization = TextCapitalization.none,
    this.validator,
    this.maxLines = 1,
    this.inputFormatters,
  });

  final TextEditingController controller;
  final String label;
  final String? hint;
  final TextInputType? keyboardType;
  final TextCapitalization textCapitalization;
  final String? Function(String?)? validator;
  final int maxLines;
  final List<TextInputFormatter>? inputFormatters;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: AppTheme.textDark,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        TextFormField(
          controller: controller,
          keyboardType: keyboardType,
          textCapitalization: textCapitalization,
          validator: validator,
          maxLines: maxLines,
          inputFormatters: inputFormatters,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          style: const TextStyle(fontSize: 15, color: AppTheme.textDark),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(
                color: AppTheme.textSoft.withOpacity(0.7), fontSize: 14.5),
            isDense: true,
            filled: true,
            fillColor: AppTheme.cream,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: AppTheme.border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: AppTheme.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: AppTheme.sage, width: 1.5),
            ),
          ),
        ),
      ],
    );
  }
}
