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

  @override
  void initState() {
    super.initState();
    _future = widget.repository.lookupWalker(widget.walkerId);
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
                                  'phone number it was registered for?'
                              : 'Set up this $noun for the phone ending in '
                                  '$mask? You\'ll verify that number by text.')
                          : 'This $noun is ready to set up.',
                    ),
                    const SizedBox(height: 20),
                    if (widget.signedIn)
                      _PrimaryButton(
                        label: reserved
                            ? 'Yes — set up this $noun'
                            : 'Claim this $noun',
                        busy: _claiming,
                        onPressed: _claimNow,
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
    this.repository,
  });

  final D2CAuthService auth;
  final String? walkerId;

  /// Optional — when arriving from a reserved-device QR, used to look up the
  /// masked recipient so the form can guide the user to the reserved number
  /// (claim-binding §5.5). Absent in previews / non-reserved flows.
  final D2CRepository? repository;

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
    _maybeLoadReservation();
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
    if (_name.text.trim().isEmpty || _phone.text.trim().isEmpty) {
      _snack(context, 'Please enter your name and mobile phone.');
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.auth.signUp(
        name: _name.text,
        phone: _phone.text,
        email: _email.text.trim().isEmpty ? null : _email.text,
      );
      // The pool auto-confirms the account — straight to SMS-OTP, no email
      // confirmation step (phone-first, d2c-phone-only-signin.md).
      final challenge = await widget.auth.startSignIn(_phone.text);
      if (!mounted) return;
      final q = StringBuffer('phoneHint=${Uri.encodeComponent(challenge.phoneHint)}');
      if (widget.walkerId != null) q.write('&walkerId=${Uri.encodeComponent(widget.walkerId!)}');
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
      title: 'Create your account',
      onBack: () => context.go('/sign-in'),
      children: [
        const Padding(
          padding: EdgeInsets.only(bottom: 18),
          child: Text(
            "We'll text a code to verify your phone. Standard message rates apply; reply STOP to opt out.",
            style: TextStyle(color: AppTheme.textSoft, height: 1.4),
          ),
        ),
        // Reserved-device guidance (claim-binding §5.5): this walker is held
        // for a specific phone — using a different one won't be able to claim
        // it, so steer the user to the reserved number.
        if (_reservedMask != null)
          Container(
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
                  child: Text(
                    'This walker is reserved for the phone ending in '
                    '$_reservedMask. Sign up with that number.',
                    style: const TextStyle(
                        color: AppTheme.textDark, height: 1.35, fontSize: 13.5),
                  ),
                ),
              ],
            ),
          ),
        _field(_name, label: 'Your name'),
        _field(_phone, label: 'Mobile phone', keyboard: TextInputType.phone),
        _field(_email, label: 'Email (optional)', keyboard: TextInputType.emailAddress),
        const SizedBox(height: 6),
        _PrimaryButton(label: 'Continue', busy: _busy, onPressed: _submit),
      ],
    );
  }
}

// ════════════════════════════════════════════════════════════════════
// /sign-in — phone → start SMS-OTP
// ════════════════════════════════════════════════════════════════════

class D2CSignInScreen extends StatefulWidget {
  const D2CSignInScreen({super.key, required this.auth});

  final D2CAuthService auth;

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
      context.go('/otp?phoneHint=${Uri.encodeComponent(challenge.phoneHint)}');
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
  });

  final D2CAuthService auth;
  final D2CRepository repository;
  final String phoneHint;
  final String? walkerId;

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

class D2CDashboardHost extends StatefulWidget {
  const D2CDashboardHost({super.key, required this.repository});

  final D2CRepository repository;

  @override
  State<D2CDashboardHost> createState() => _D2CDashboardHostState();
}

class _D2CDashboardHostState extends State<D2CDashboardHost> {
  late Future<D2CDashboardSnapshot?> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<D2CDashboardSnapshot?> _load() async {
    final patientId = await widget.repository.myWalkerPatientId();
    if (patientId == null) return null;
    return widget.repository.dashboard(patientId);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<D2CDashboardSnapshot?>(
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
              onRetry: () => setState(() => _future = _load()),
            ),
          );
        }
        final data = snap.data;
        if (data == null) {
          return const _HostScaffold(
            tab: D2CTab.activity,
            child: _Message(
              icon: Icons.directions_walk_outlined,
              text: "You haven't set up a walker yet. Scan the QR code on your GoSteady cap to get started.",
            ),
          );
        }
        return D2CDashboardScreen(snapshot: data);
      },
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
// /care-team — Phase-5 placeholder
// ════════════════════════════════════════════════════════════════════

class D2CCareTeamPlaceholder extends StatelessWidget {
  const D2CCareTeamPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    return const _HostScaffold(
      tab: D2CTab.careTeam,
      child: _Message(
        icon: Icons.group_outlined,
        text: 'Inviting family and caregivers is coming in a future update.',
      ),
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
