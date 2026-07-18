import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../api/api_exception.dart';
import '../../api/d2c_api_models.dart';
import '../../auth/auth_service_interface.dart';
import '../../theme/app_theme.dart';
import '../auth/d2c_auth_service.dart';
import '../d2c_routes.dart';
import '../data/d2c_mock_data.dart';
import '../data/d2c_repository.dart';
import '../rendering/metric_registry.dart';
import '../screens/d2c_dashboard_screen.dart';
import '../widgets/d2c_bottom_nav.dart';

/// Live (API-backed) D2C screens for the production walker-user flow:
/// QR `/setup` landing → sign-up → email confirm → SMS-OTP → claim →
/// dashboard. These drive [D2CAuthService] + [D2CRepository] directly,
/// distinct from the static wireframe screens under `lib/d2c/screens/`
/// (which remain the design-review preview hub). Per d2c-phase1 §6.
///
/// Functional, not pixel-final: the visual polish of the wireframes is a
/// later pass. The goal here is a correct, live end-to-end flow.

// ════════════════════════════════════════════════════════════════════
// Shared UI helpers
// ════════════════════════════════════════════════════════════════════

/// Centered, max-width card scaffold used by every onboarding step.
class _OnboardScaffold extends StatelessWidget {
  const _OnboardScaffold({required this.title, required this.children, this.onBack});

  final String title;
  final List<Widget> children;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.warmWhite,
      appBar: AppBar(
        backgroundColor: AppTheme.warmWhite,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: onBack == null
            ? null
            : IconButton(
                icon: const Icon(Icons.arrow_back_rounded, color: AppTheme.textDark),
                onPressed: onBack,
              ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 48),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: AppTheme.textDark,
                      ),
                ),
                const SizedBox(height: 20),
                ...children,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Widget _field(
  TextEditingController c, {
  required String label,
  TextInputType? keyboard,
  bool obscure = false,
}) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: TextField(
      controller: c,
      keyboardType: keyboard,
      obscureText: obscure,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        filled: true,
        fillColor: Colors.white,
      ),
    ),
  );
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({required this.label, required this.onPressed, this.busy = false});

  final String label;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppTheme.sage,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        onPressed: busy ? null : onPressed,
        child: busy
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white),
              )
            : Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
      ),
    );
  }
}

String _errText(Object e) =>
    e is AuthException ? e.message : (e is ApiException ? e.message : 'Something went wrong. Please try again.');

void _snack(BuildContext context, String msg) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg)));
}

// ════════════════════════════════════════════════════════════════════
// /setup/:walkerId — public QR landing
// ════════════════════════════════════════════════════════════════════

class D2CSetupLandingScreen extends StatefulWidget {
  const D2CSetupLandingScreen({
    super.key,
    required this.walkerId,
    required this.repository,
    required this.signedIn,
  });

  final String walkerId;
  final D2CRepository repository;
  final bool signedIn;

  @override
  State<D2CSetupLandingScreen> createState() => _D2CSetupLandingScreenState();
}

class _D2CSetupLandingScreenState extends State<D2CSetupLandingScreen> {
  late Future<PublicWalkerLookup> _future;
  bool _claiming = false;
  final _phone = TextEditingController();

  @override
  void initState() {
    super.initState();
    _future = widget.repository.lookupWalker(widget.walkerId);
  }

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  Future<void> _claimNow() async {
    setState(() => _claiming = true);
    try {
      await widget.repository.claim(widget.walkerId);
      if (mounted) context.go(D2CRoutes.dashboard);
    } catch (e) {
      if (mounted) {
        setState(() => _claiming = false);
        _snack(context, _errText(e));
      }
    }
  }

  /// Reserved flow: the phone is collected HERE (where the reserved mask is
  /// known) so the account page is name + email only — the participant never
  /// enters a phone that could differ from the bound one (§5.5). Validates
  /// the entered number's last-4 against the mask for immediate feedback,
  /// then carries the raw number to /sign-up via router `extra` (never the
  /// URL — no PII in query strings). The full E.164 canonicalization + the
  /// authoritative match happen downstream (signUp normalizes; claim enforces).
  void _continueReserved(String noun, String mask) {
    final typed = _phone.text.replaceAll(RegExp(r'\D'), '');
    final maskDigits = mask.replaceAll(RegExp(r'\D'), '');
    if (typed.length < 10) {
      _snack(context, 'Enter your 10-digit mobile number.');
      return;
    }
    if (maskDigits.isNotEmpty && !typed.endsWith(maskDigits)) {
      _snack(context,
          'This $noun is reserved for a phone ending in $mask. Use that number.');
      return;
    }
    context.go(
      '/sign-up?walkerId=${Uri.encodeComponent(widget.walkerId)}',
      extra: _phone.text.trim(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _OnboardScaffold(
      title: 'Set up your walker',
      children: [
        FutureBuilder<PublicWalkerLookup>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snap.hasError) {
              return _Message(
                icon: Icons.wifi_off_rounded,
                text: "Couldn't reach GoSteady. Check your connection and try again.",
              );
            }
            final lookup = snap.data!;
            // DT-4: device-appropriate noun — a rollator isn't a "walker".
            final noun =
                lookup.deviceType == 'rollator_platform' ? 'rollator' : 'walker';
            switch (lookup.status) {
              case PublicWalkerStatus.unclaimed:
              case PublicWalkerStatus.reserved:
                // Reserved (claim-binding §5.5): the device is held for a
                // specific phone. Show WHO it's for + an explicit question,
                // so a claim is never silent — the button IS the confirm.
                final reserved =
                    lookup.status == PublicWalkerStatus.reserved;
                final mask = lookup.recipientMask ?? '';
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Message(
                      icon: reserved
                          ? Icons.phone_iphone
                          : Icons.check_circle_outline,
                      text: reserved
                          ? (mask.isEmpty
                              ? 'This $noun is reserved. Set it up with the '
                                  'phone number it was registered for.'
                              : 'This $noun is reserved for the phone ending in '
                                  '$mask. Enter that number to set it up — '
                                  "we'll text a code to verify it.")
                          : 'This $noun is ready to set up.',
                    ),
                    const SizedBox(height: 20),
                    if (widget.signedIn)
                      // Already signed in → claim directly (their verified
                      // phone is enforced against the binding server-side).
                      _PrimaryButton(
                        label: reserved
                            ? 'Yes — set up this $noun'
                            : 'Claim this $noun',
                        busy: _claiming,
                        onPressed: _claimNow,
                      )
                    else if (reserved)
                      // Reserved + new user: collect the phone HERE so the
                      // account page is name + email only (§5.5).
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _field(_phone,
                              label: 'Your mobile number',
                              keyboard: TextInputType.phone),
                          _PrimaryButton(
                            label: 'Continue',
                            onPressed: () => _continueReserved(noun, mask),
                          ),
                        ],
                      )
                    else
                      _PrimaryButton(
                        label: 'Get started',
                        onPressed: () => context.go(
                          '/sign-up?walkerId=${Uri.encodeComponent(widget.walkerId)}',
                        ),
                      ),
                    if (!widget.signedIn)
                      TextButton(
                        onPressed: () => context.go('/sign-in'),
                        child: const Text('I already have an account'),
                      ),
                  ],
                );
              case PublicWalkerStatus.claimed:
                return _Message(
                  icon: Icons.lock_outline,
                  text: lookup.ownerMasked == null
                      ? 'This $noun is already registered to another account.'
                      : 'This $noun is already registered to ${lookup.ownerMasked}.',
                );
              case PublicWalkerStatus.decommissioned:
                return _Message(
                  icon: Icons.block,
                  text: 'This $noun has been retired and can no longer be set up.',
                );
              case PublicWalkerStatus.unknown:
                return _Message(
                  icon: Icons.help_outline,
                  text: "This link doesn't look right. Double-check the code on your $noun's sticker.",
                );
            }
          },
        ),
      ],
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon, size: 48, color: AppTheme.sage),
        const SizedBox(height: 16),
        Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 16, color: AppTheme.textDark, height: 1.4),
        ),
      ],
    );
  }
}

// ════════════════════════════════════════════════════════════════════
// /sign-up — name + email + phone (live signUp → email confirm)
// ════════════════════════════════════════════════════════════════════

class D2CSignUpScreen extends StatefulWidget {
  const D2CSignUpScreen({
    super.key,
    required this.auth,
    this.walkerId,
    this.joinInviteId,
    this.repository,
    this.prefilledPhone,
  });

  final D2CAuthService auth;
  final String? walkerId;

  /// Care Circle invite context (`/join/{inviteId}` → sign-up). Threaded
  /// through to /otp, which accepts the invite right after the OTP lands —
  /// the invite parallel of [walkerId]'s claim (d2c-care-circle.md §5.9).
  final String? joinInviteId;

  /// Optional — when arriving from a reserved-device QR, used to look up the
  /// masked recipient so the form can guide the user to the reserved number
  /// (claim-binding §5.5). Absent in previews / non-reserved flows.
  final D2CRepository? repository;

  /// The phone already collected on the reserved landing (§5.5). When set,
  /// this page is name + optional email ONLY — no phone field — so the user
  /// can't enter a number that differs from the reserved one. When null
  /// (retail, or a reload that dropped router state), the phone field is
  /// shown as a graceful fallback.
  final String? prefilledPhone;

  @override
  State<D2CSignUpScreen> createState() => _D2CSignUpScreenState();
}

class _D2CSignUpScreenState extends State<D2CSignUpScreen> {
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  bool _busy = false;
  String? _reservedMask; // •••-1234 when this walker is reserved for a phone

  @override
  void initState() {
    super.initState();
    // When the phone was already collected on the reserved landing we know
    // the reservation — no lookup needed. Only retail / reload-fallback
    // (phone field shown) benefits from the guidance hint.
    if ((widget.prefilledPhone ?? '').trim().isEmpty) _maybeLoadReservation();
  }

  Future<void> _maybeLoadReservation() async {
    final repo = widget.repository;
    final wid = widget.walkerId;
    if (repo == null || wid == null || wid.isEmpty) return;
    try {
      final lookup = await repo.lookupWalker(wid);
      if (!mounted) return;
      if (lookup.status == PublicWalkerStatus.reserved &&
          (lookup.recipientMask ?? '').isNotEmpty) {
        setState(() => _reservedMask = lookup.recipientMask);
      }
    } catch (_) {
      // Best-effort guidance; a lookup hiccup just omits the hint.
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    // Reserved flow: phone came from the landing (no field here). Retail flow:
    // phone is on this page.
    final phone = ((widget.prefilledPhone ?? '').trim().isNotEmpty
            ? widget.prefilledPhone!
            : _phone.text)
        .trim();
    if (_name.text.trim().isEmpty) {
      _snack(context, 'Please enter your name.');
      return;
    }
    if (phone.isEmpty) {
      _snack(context, 'Please enter your mobile phone.');
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.auth.signUp(
        name: _name.text,
        phone: phone,
        email: _email.text.trim().isEmpty ? null : _email.text,
      );
      // The pool auto-confirms the account — straight to SMS-OTP, no email
      // confirmation step (phone-first, d2c-phone-only-signin.md).
      final challenge = await widget.auth.startSignIn(phone);
      if (!mounted) return;
      final q = StringBuffer('phoneHint=${Uri.encodeComponent(challenge.phoneHint)}');
      if (widget.walkerId != null) q.write('&walkerId=${Uri.encodeComponent(widget.walkerId!)}');
      if (widget.joinInviteId != null) {
        q.write('&join=${Uri.encodeComponent(widget.joinInviteId!)}');
      }
      context.go('/otp?$q');
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        _snack(context, _errText(e));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final prefill = (widget.prefilledPhone ?? '').trim();
    final hasPrefill = prefill.isNotEmpty;
    final prefillDigits = prefill.replaceAll(RegExp(r'\D'), '');
    final prefillTail = prefillDigits.length >= 4
        ? prefillDigits.substring(prefillDigits.length - 4)
        : prefillDigits;
    return _OnboardScaffold(
      title: 'Create your account',
      onBack: () => context.go('/sign-in'),
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 18),
          child: Text(
            hasPrefill
                ? "We'll text a code to verify your phone. Just your name to "
                    "finish. Standard message rates apply; reply STOP to opt out."
                : "We'll text a code to verify your phone. Standard message "
                    "rates apply; reply STOP to opt out.",
            style: const TextStyle(color: AppTheme.textSoft, height: 1.4),
          ),
        ),
        // Reserved flow: the phone was collected + last-4-checked on the
        // landing (§5.5), so this page is name + email ONLY — no phone field,
        // so the account can't be created against a different number. Confirm
        // which number we'll use.
        if (hasPrefill)
          _InfoBanner(
              'Setting up for the phone ending in •••-$prefillTail.'),
        // Retail / reload fallback (phone field shown): guide toward the
        // reserved number if we know it.
        if (!hasPrefill && _reservedMask != null)
          _InfoBanner(
              'This walker is reserved for the phone ending in $_reservedMask. '
              'Sign up with that number.'),
        _field(_name, label: 'Your name'),
        if (!hasPrefill)
          _field(_phone, label: 'Mobile phone', keyboard: TextInputType.phone),
        _field(_email,
            label: 'Email (optional)', keyboard: TextInputType.emailAddress),
        const SizedBox(height: 6),
        _PrimaryButton(label: 'Continue', busy: _busy, onPressed: _submit),
      ],
    );
  }
}

/// Small sage info banner (reused by the signup guidance / confirmation).
class _InfoBanner extends StatelessWidget {
  const _InfoBanner(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.sage.withOpacity(0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.sage.withOpacity(0.35)),
      ),
      child: Row(
        children: [
          const Icon(Icons.phone_iphone, size: 18, color: AppTheme.sage),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                style: const TextStyle(
                    color: AppTheme.textDark, height: 1.35, fontSize: 13.5)),
          ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
// /sign-in — phone → start SMS-OTP
// ════════════════════════════════════════════════════════════════════

class D2CSignInScreen extends StatefulWidget {
  const D2CSignInScreen({super.key, required this.auth, this.joinInviteId});

  final D2CAuthService auth;

  /// Care Circle invite context — threaded through to /otp so a returning
  /// user who tapped a /join link accepts right after sign-in.
  final String? joinInviteId;

  @override
  State<D2CSignInScreen> createState() => _D2CSignInScreenState();
}

class _D2CSignInScreenState extends State<D2CSignInScreen> {
  final _phone = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_phone.text.trim().isEmpty) {
      _snack(context, 'Enter your mobile phone to continue.');
      return;
    }
    setState(() => _busy = true);
    try {
      final challenge = await widget.auth.startSignIn(_phone.text);
      if (!mounted) return;
      final q = StringBuffer('phoneHint=${Uri.encodeComponent(challenge.phoneHint)}');
      if (widget.joinInviteId != null) {
        q.write('&join=${Uri.encodeComponent(widget.joinInviteId!)}');
      }
      context.go('/otp?$q');
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        _snack(context, _errText(e));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return _OnboardScaffold(
      title: 'Sign in',
      children: [
        const Padding(
          padding: EdgeInsets.only(bottom: 18),
          child: Text(
            "We'll text a one-time code to your phone.",
            style: TextStyle(color: AppTheme.textSoft, height: 1.4),
          ),
        ),
        _field(_phone, label: 'Mobile phone', keyboard: TextInputType.phone),
        const SizedBox(height: 6),
        _PrimaryButton(label: 'Send code', busy: _busy, onPressed: _submit),
        TextButton(
          onPressed: () => context.go('/sign-up'),
          child: const Text("I'm setting up a new walker"),
        ),
      ],
    );
  }
}

// ════════════════════════════════════════════════════════════════════
// /otp — SMS code entry → (optional claim) → dashboard
// ════════════════════════════════════════════════════════════════════

class D2COtpEntryScreen extends StatefulWidget {
  const D2COtpEntryScreen({
    super.key,
    required this.auth,
    required this.repository,
    required this.phoneHint,
    this.walkerId,
    this.joinInviteId,
  });

  final D2CAuthService auth;
  final D2CRepository repository;
  final String phoneHint;
  final String? walkerId;

  /// Care Circle invite to accept right after the OTP lands (the invite
  /// parallel of [walkerId]'s claim).
  final String? joinInviteId;

  @override
  State<D2COtpEntryScreen> createState() => _D2COtpEntryScreenState();
}

class _D2COtpEntryScreenState extends State<D2COtpEntryScreen> {
  final _code = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _busy = true);
    try {
      await widget.auth.submitOtp(_code.text);
      // Signed in. If we arrived from a /setup link, claim now.
      if (widget.walkerId != null) {
        try {
          await widget.repository.claim(widget.walkerId!);
        } catch (e) {
          // Claim failure shouldn't strand a signed-in user on the OTP
          // screen — surface it but proceed to the dashboard.
          if (mounted) _snack(context, _errText(e));
        }
      }
      // If we arrived from a /join link, accept the invite now (the
      // server matches this account's just-verified phone — fail-closed).
      if (widget.joinInviteId != null) {
        try {
          final joined =
              await widget.repository.acceptInvite(widget.joinInviteId!);
          if (mounted) {
            _snack(
              context,
              joined.walkerName.isEmpty
                  ? "You're in the Care Circle."
                  : "You're in ${joined.walkerName}'s Care Circle.",
            );
          }
        } catch (e) {
          // Non-fatal — the dashboard's pending-invite prompt is the
          // recovery path (organic match by verified phone).
          if (mounted) _snack(context, _errText(e));
        }
      }
      if (mounted) context.go(D2CRoutes.dashboard);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        _snack(context, _errText(e));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hint = widget.phoneHint.isEmpty ? 'your phone' : widget.phoneHint;
    return _OnboardScaffold(
      title: 'Enter your code',
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 18),
          child: Text(
            'We sent a 6-digit code to $hint.',
            style: const TextStyle(color: AppTheme.textSoft, height: 1.4),
          ),
        ),
        _field(_code, label: '6-digit code', keyboard: TextInputType.number),
        const SizedBox(height: 6),
        _PrimaryButton(label: 'Verify', busy: _busy, onPressed: _submit),
        TextButton(
          onPressed: _busy
              ? null
              : () async {
                  try {
                    final c = await widget.auth.resendOtp();
                    if (mounted) {
                      _snack(context, 'New code sent to ${c.phoneHint.isEmpty ? "your phone" : c.phoneHint}.');
                    }
                  } catch (e) {
                    if (mounted) _snack(context, _errText(e));
                  }
                },
          child: const Text('Resend code'),
        ),
      ],
    );
  }
}

// ════════════════════════════════════════════════════════════════════
// /dashboard — live monitoring (reuses the wireframe dashboard screen)
// ════════════════════════════════════════════════════════════════════

class _DashState {
  const _DashState({this.patientId, this.snapshot, this.joinable = const []});
  final String? patientId;
  final D2CDashboardSnapshot? snapshot;

  /// Live invites addressed to this account's verified phone — the organic
  /// join path ("got the text, signed up from the app instead of the link";
  /// d2c-care-circle.md §5.3). Only checked when the account has no walker.
  final List<JoinableInvite> joinable;
}

class D2CDashboardHost extends StatefulWidget {
  const D2CDashboardHost({super.key, required this.repository});

  final D2CRepository repository;

  @override
  State<D2CDashboardHost> createState() => _D2CDashboardHostState();
}

class _D2CDashboardHostState extends State<D2CDashboardHost> {
  late Future<_DashState> _future;
  bool _joining = false;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_DashState> _load() async {
    final patientId = await widget.repository.myWalkerPatientId();
    if (patientId == null) {
      // No walker in this household — before showing the empty state,
      // check for Care Circle invites matched to this verified phone.
      var joinable = const <JoinableInvite>[];
      try {
        joinable = await widget.repository.pendingInvitesForMe();
      } catch (_) {
        // Best-effort — a hiccup just falls back to the empty state.
      }
      return _DashState(joinable: joinable);
    }
    final snapshot = await widget.repository.dashboard(patientId);
    return _DashState(patientId: patientId, snapshot: snapshot);
  }

  void _reload() => setState(() => _future = _load());

  Future<void> _acceptInvite(JoinableInvite invite) async {
    setState(() => _joining = true);
    try {
      final joined = await widget.repository.acceptInvite(invite.inviteId);
      if (!mounted) return;
      _snack(
        context,
        joined.walkerName.isEmpty
            ? "You're in the Care Circle."
            : "You're in ${joined.walkerName}'s Care Circle.",
      );
      _reload();
    } catch (e) {
      if (mounted) _snack(context, _errText(e));
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }

  Future<void> _ackAlert(String patientId, WalkerAlert alert) async {
    try {
      await widget.repository.ackAlert(patientId, alert.id);
      if (!mounted) return;
      _snack(context, 'Marked as handled.');
      _reload();
    } catch (e) {
      if (mounted) _snack(context, _errText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_DashState>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const _HostScaffold(
            tab: D2CTab.activity,
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (snap.hasError) {
          return _HostScaffold(
            tab: D2CTab.activity,
            child: _RetryView(
              message: _errText(snap.error!),
              onRetry: _reload,
            ),
          );
        }
        final state = snap.data ?? const _DashState();
        final data = state.snapshot;
        if (data == null) {
          if (state.joinable.isNotEmpty) {
            return _HostScaffold(
              tab: D2CTab.activity,
              child: _JoinPrompt(
                invites: state.joinable,
                busy: _joining,
                onAccept: _acceptInvite,
              ),
            );
          }
          return const _HostScaffold(
            tab: D2CTab.activity,
            child: _Message(
              icon: Icons.directions_walk_outlined,
              text: "You haven't set up a walker yet. Scan the QR code on your GoSteady cap to get started.",
            ),
          );
        }
        return D2CDashboardScreen(
          snapshot: data,
          onAckAlert: state.patientId == null
              ? null
              : (alert) => _ackAlert(state.patientId!, alert),
        );
      },
    );
  }
}

/// "You've been invited" card list — shown instead of the no-walker empty
/// state when live invites match this account's verified phone.
class _JoinPrompt extends StatelessWidget {
  const _JoinPrompt({
    required this.invites,
    required this.busy,
    required this.onAccept,
  });

  final List<JoinableInvite> invites;
  final bool busy;
  final void Function(JoinableInvite) onAccept;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(24),
          children: [
            const Icon(Icons.group_add_outlined, size: 48, color: AppTheme.sage),
            const SizedBox(height: 16),
            Text(
              invites.length == 1
                  ? "You've been invited to a Care Circle"
                  : "You've been invited to Care Circles",
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: AppTheme.textDark,
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const SizedBox(height: 20),
            for (final inv in invites)
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppTheme.sage.withOpacity(0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      inv.inviterName.isEmpty
                          ? "Join ${inv.walkerName.isEmpty ? 'this' : "${inv.walkerName}'s"} Care Circle"
                          : "${inv.inviterName} invited you to follow ${inv.walkerName.isEmpty ? 'their walker' : inv.walkerName}",
                      style: const TextStyle(
                        color: AppTheme.textDark,
                        fontSize: 15.5,
                        fontWeight: FontWeight.w600,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 12),
                    _PrimaryButton(
                      label: 'Join Care Circle',
                      busy: busy,
                      onPressed: () => onAccept(inv),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
// /history — live daily history (lean; 30-day window per 2A-RD cap)
// ════════════════════════════════════════════════════════════════════

class D2CHistoryHost extends StatefulWidget {
  const D2CHistoryHost({super.key, required this.repository});

  final D2CRepository repository;

  @override
  State<D2CHistoryHost> createState() => _D2CHistoryHostState();
}

class _D2CHistoryHostState extends State<D2CHistoryHost> {
  late Future<List<HistoryDay>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<HistoryDay>> _load() async {
    final patientId = await widget.repository.myWalkerPatientId();
    if (patientId == null) return const [];
    return widget.repository.history(patientId, days: 30);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.warmWhite,
      appBar: AppBar(
        backgroundColor: AppTheme.warmWhite,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: AppTheme.textDark),
          onPressed: () => context.go(D2CRoutes.dashboard),
        ),
        title: const Text('History', style: TextStyle(color: AppTheme.textDark)),
      ),
      bottomNavigationBar: const D2CBottomNav(active: D2CTab.activity),
      body: FutureBuilder<List<HistoryDay>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return _RetryView(
              message: _errText(snap.error!),
              onRetry: () => setState(() => _future = _load()),
            );
          }
          final days = snap.data ?? const [];
          if (days.isEmpty) {
            return const _Message(
              icon: Icons.show_chart_rounded,
              text: 'No activity recorded yet.',
            );
          }
          // Per-type (DT-4): a rollator has no steps → show active-minutes.
          final isActiveMin = deviceTypeView(days.first.deviceType).hero ==
              ActivityMetric.activeMinutes;
          int val(HistoryDay d) => isActiveMin ? d.activeMinutes : d.steps;
          final noun = isActiveMin ? 'active min' : 'steps';
          final total = days.fold<int>(0, (a, d) => a + val(d));
          final avg = (total / days.length).round();
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 96),
            children: [
              Text('Last ${days.length} days', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text('Average $avg $noun/day', style: const TextStyle(color: AppTheme.textSoft)),
              const SizedBox(height: 16),
              for (final d in days.reversed)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '${d.date.month}/${d.date.day}',
                        style: const TextStyle(color: AppTheme.textSoft),
                      ),
                      Text('${val(d)} $noun', style: const TextStyle(color: AppTheme.textDark)),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
// /join/:inviteId — Care Circle invite landing (d2c-care-circle.md §5.9)
// ════════════════════════════════════════════════════════════════════

/// Landing for the invite SMS link. The link is a **durable re-entry
/// point**, not a one-time credential: the server only grants membership
/// on a VERIFIED-phone match, so the link is safe to re-open forever.
///
/// Routing:
///   • signed-out → phone-first sign-up/sign-in carrying the invite id
///     (a fresh OTP re-verifies the phone; the post-OTP accept is
///     idempotent, so a returning member who timed out lands on the
///     dashboard — d2c-care-circle.md §5.3a).
///   • signed-in → resolve the invite against the caller's identity:
///       – a live invite for them → confirm-and-join (first-time);
///       – already a member via this invite → straight to the dashboard
///         ("get me back to the data" — the reported re-entry fix);
///       – belongs to another Care Circle → neutral, with a link home;
///       – genuinely unavailable (wrong phone / revoked / expired-unused)
///         → neutral not-available copy (no oracle).
class D2CJoinScreen extends StatefulWidget {
  const D2CJoinScreen({
    super.key,
    required this.inviteId,
    required this.repository,
    required this.signedIn,
  });

  final String inviteId;
  final D2CRepository repository;
  final bool signedIn;

  @override
  State<D2CJoinScreen> createState() => _D2CJoinScreenState();
}

/// How a signed-in caller's invite resolved (see [_resolve]).
enum _JoinKind { firstTime, alreadyMember, otherHousehold, unavailable, error }

class _JoinResolution {
  const _JoinResolution(this.kind,
      {this.invite, this.walkerName = '', this.message = ''});
  final _JoinKind kind;
  final JoinableInvite? invite; // firstTime
  final String walkerName; // alreadyMember
  final String message; // error
}

class _D2CJoinScreenState extends State<D2CJoinScreen> {
  Future<_JoinResolution>? _resolution;
  bool _busy = false;
  bool _redirecting = false;

  @override
  void initState() {
    super.initState();
    if (widget.signedIn) _resolution = _resolve();
  }

  /// Signed-in resolution. A first-time join surfaces in the caller's
  /// pending list (server matches by verified-phone hash). If it's NOT
  /// pending, we attempt the **idempotent** accept to tell a returning
  /// member (already accepted → 200 alreadyMember) apart from a genuinely
  /// unavailable invite — without leaking which is which.
  Future<_JoinResolution> _resolve() async {
    try {
      final pending = await widget.repository.pendingInvitesForMe();
      final match =
          pending.where((i) => i.inviteId == widget.inviteId).toList();
      if (match.isNotEmpty) {
        return _JoinResolution(_JoinKind.firstTime, invite: match.first);
      }
      try {
        final joined = await widget.repository.acceptInvite(widget.inviteId);
        return _JoinResolution(_JoinKind.alreadyMember,
            walkerName: joined.walkerName);
      } on ApiException catch (e) {
        if (e.code == 'ALREADY_IN_HOUSEHOLD') {
          return const _JoinResolution(_JoinKind.otherHousehold);
        }
        // INVITE_PHONE_MISMATCH / INVITE_NOT_FOUND / INVITE_NOT_ACTIVE →
        // neutral (no oracle — mirrors the server's fail-closed accept).
        return const _JoinResolution(_JoinKind.unavailable);
      }
    } catch (e) {
      return _JoinResolution(_JoinKind.error, message: _errText(e));
    }
  }

  Future<void> _accept() async {
    setState(() => _busy = true);
    try {
      final joined = await widget.repository.acceptInvite(widget.inviteId);
      if (!mounted) return;
      _snack(
        context,
        joined.walkerName.isEmpty
            ? "You're in the Care Circle."
            : "You're in ${joined.walkerName}'s Care Circle.",
      );
      context.go(D2CRoutes.dashboard);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        _snack(context, _errText(e));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.signedIn) {
      final joinQ = 'join=${Uri.encodeComponent(widget.inviteId)}';
      return _OnboardScaffold(
        title: "You're invited",
        children: [
          const _Message(
            icon: Icons.group_add_outlined,
            text: "You've been invited to follow a family member's walker "
                'on GoSteady. Continue with the phone number that received '
                "the invite text — we'll verify it with a code.",
          ),
          const SizedBox(height: 20),
          _PrimaryButton(
            label: 'Create my account',
            onPressed: () => context.go('/sign-up?$joinQ'),
          ),
          TextButton(
            onPressed: () => context.go('/sign-in?$joinQ'),
            child: const Text('I already have an account'),
          ),
        ],
      );
    }

    return _OnboardScaffold(
      title: "You're invited",
      children: [
        FutureBuilder<_JoinResolution>(
          future: _resolution,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final res = snap.data ??
                const _JoinResolution(_JoinKind.unavailable);
            switch (res.kind) {
              case _JoinKind.alreadyMember:
                // Returning member — take them straight to the data (the
                // reported re-entry fix). Redirect once, post-frame.
                if (!_redirecting) {
                  _redirecting = true;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) context.go(D2CRoutes.dashboard);
                  });
                }
                return _Message(
                  icon: Icons.check_circle_outline,
                  text: res.walkerName.isEmpty
                      ? 'Welcome back — opening your dashboard…'
                      : "Welcome back — opening ${res.walkerName}'s activity…",
                );
              case _JoinKind.otherHousehold:
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _Message(
                      icon: Icons.info_outline,
                      text: 'This account is already part of another Care '
                          'Circle. Contact support to move it.',
                    ),
                    const SizedBox(height: 20),
                    _PrimaryButton(
                      label: 'Go to my dashboard',
                      onPressed: () => context.go(D2CRoutes.dashboard),
                    ),
                  ],
                );
              case _JoinKind.error:
                return _Message(
                    icon: Icons.wifi_off_rounded, text: res.message);
              case _JoinKind.unavailable:
                return const _Message(
                  icon: Icons.help_outline,
                  text: "This invite isn't available for this account. It "
                      'may have been sent to a different phone number, '
                      'already used, or expired — ask the sender for a '
                      'fresh one.',
                );
              case _JoinKind.firstTime:
                final inv = res.invite!;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Message(
                      icon: Icons.group_add_outlined,
                      text: inv.inviterName.isEmpty
                          ? "Join ${inv.walkerName.isEmpty ? 'this' : "${inv.walkerName}'s"} Care Circle?"
                          : "${inv.inviterName} invited you to follow "
                              "${inv.walkerName.isEmpty ? 'their walker' : inv.walkerName}. Join the Care Circle?",
                    ),
                    const SizedBox(height: 20),
                    _PrimaryButton(
                      label: 'Join Care Circle',
                      busy: _busy,
                      onPressed: _accept,
                    ),
                    TextButton(
                      onPressed: () => context.go(D2CRoutes.dashboard),
                      child: const Text('Not now'),
                    ),
                  ],
                );
            }
          },
        ),
      ],
    );
  }
}

// ════════════════════════════════════════════════════════════════════
// /account — basic profile + sign out
// ════════════════════════════════════════════════════════════════════

class D2CAccountHost extends StatelessWidget {
  const D2CAccountHost({super.key, required this.auth});

  final AuthServiceInterface auth;

  @override
  Widget build(BuildContext context) {
    final user = auth.currentUser;
    return _HostScaffold(
      tab: D2CTab.account,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.account_circle_outlined, size: 64, color: AppTheme.sage),
            const SizedBox(height: 16),
            Text(
              user?.displayName ?? 'Your account',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(color: AppTheme.textDark),
            ),
            if (user?.email != null) ...[
              const SizedBox(height: 4),
              Text(user!.email, textAlign: TextAlign.center, style: const TextStyle(color: AppTheme.textSoft)),
            ],
            const SizedBox(height: 32),
            OutlinedButton(
              onPressed: () => auth.signOut(),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.textDark,
                minimumSize: const Size.fromHeight(50),
              ),
              child: const Text('Sign out'),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Shared host scaffold (bottom nav + body) ──────────────────────────

class _HostScaffold extends StatelessWidget {
  const _HostScaffold({required this.tab, required this.child});
  final D2CTab tab;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.warmWhite,
      bottomNavigationBar: D2CBottomNav(active: tab),
      body: SafeArea(child: child),
    );
  }
}

class _RetryView extends StatelessWidget {
  const _RetryView({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 44, color: AppTheme.textSoft),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center, style: const TextStyle(color: AppTheme.textDark)),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
