import 'package:flutter/material.dart';

import '../models/user.dart';
import '../services/auth_service.dart';
import '../theme/app_theme.dart';

/// Login / sign-up screen. Matches GoSteady branding with sage green
/// accent and warm whites. Handles sign-in, sign-up, and email confirmation.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.onSignedIn});

  /// Called after successful sign-in with the authenticated user.
  final ValueChanged<GoSteadyUser> onSignedIn;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

enum _Mode { signIn, signUp, confirm }

class _LoginScreenState extends State<LoginScreen> {
  final _auth = AuthService.instance;

  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();

  _Mode _mode = _Mode.signIn;
  UserRole _selectedRole = UserRole.walker;
  bool _loading = false;
  String? _error;
  bool _obscurePassword = true;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _nameCtrl.dispose();
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _handleSignIn() async {
    if (_emailCtrl.text.trim().isEmpty || _passwordCtrl.text.isEmpty) {
      setState(() => _error = 'Please enter your email and password.');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final user = await _auth.signIn(
        _emailCtrl.text.trim(),
        _passwordCtrl.text,
      );
      widget.onSignedIn(user);
    } on AuthException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _handleSignUp() async {
    if (_nameCtrl.text.trim().isEmpty ||
        _emailCtrl.text.trim().isEmpty ||
        _passwordCtrl.text.isEmpty) {
      setState(() => _error = 'Please fill in all fields.');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final needsConfirmation = await _auth.signUp(
        email: _emailCtrl.text.trim(),
        password: _passwordCtrl.text,
        fullName: _nameCtrl.text.trim(),
        role: _selectedRole,
      );

      if (needsConfirmation) {
        setState(() => _mode = _Mode.confirm);
      } else {
        // Auto-confirmed — sign in directly
        final user = await _auth.signIn(
          _emailCtrl.text.trim(),
          _passwordCtrl.text,
        );
        widget.onSignedIn(user);
      }
    } on AuthException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _handleConfirm() async {
    if (_codeCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Please enter the verification code.');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      await _auth.confirmSignUp(
        _emailCtrl.text.trim(),
        _codeCtrl.text.trim(),
      );
      // Confirmed — now sign in
      final user = await _auth.signIn(
        _emailCtrl.text.trim(),
        _passwordCtrl.text,
      );
      widget.onSignedIn(user);
    } on AuthException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.warmWhite,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // ── Logo + brand ─────────────────────────────
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: AppTheme.sage,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: AppTheme.sage.withOpacity(0.25),
                          blurRadius: 20,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.accessibility_new_rounded,
                      color: Colors.white,
                      size: 32,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'GoSteady',
                    style: Theme.of(context)
                        .textTheme
                        .headlineMedium
                        ?.copyWith(fontSize: 32),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _mode == _Mode.signIn
                        ? 'Sign in to your portal'
                        : _mode == _Mode.signUp
                            ? 'Create your account'
                            : 'Verify your email',
                    style: const TextStyle(
                      color: AppTheme.textSoft,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 36),

                  // ── Form card ────────────────────────────────
                  Container(
                    padding: const EdgeInsets.all(28),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(AppTheme.cardRadius),
                      boxShadow: AppTheme.cardShadow,
                      border: Border.all(
                        color: AppTheme.border.withOpacity(0.5),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_mode == _Mode.confirm) ...[
                          const Text(
                            'We sent a verification code to your email. Enter it below to complete sign-up.',
                            style: TextStyle(
                              color: AppTheme.textSoft,
                              fontSize: 13,
                              height: 1.5,
                            ),
                          ),
                          const SizedBox(height: 20),
                          _buildField(
                            controller: _codeCtrl,
                            label: 'Verification code',
                            hint: '123456',
                            icon: Icons.pin_rounded,
                            keyboardType: TextInputType.number,
                          ),
                        ] else ...[
                          if (_mode == _Mode.signUp) ...[
                            _buildField(
                              controller: _nameCtrl,
                              label: 'Full name',
                              hint: 'Jane Smith',
                              icon: Icons.person_outline_rounded,
                            ),
                            const SizedBox(height: 16),
                          ],
                          _buildField(
                            controller: _emailCtrl,
                            label: 'Email',
                            hint: 'you@example.com',
                            icon: Icons.email_outlined,
                            keyboardType: TextInputType.emailAddress,
                          ),
                          const SizedBox(height: 16),
                          _buildField(
                            controller: _passwordCtrl,
                            label: 'Password',
                            hint: 'Enter your password',
                            icon: Icons.lock_outline_rounded,
                            obscure: _obscurePassword,
                            suffix: IconButton(
                              icon: Icon(
                                _obscurePassword
                                    ? Icons.visibility_off_outlined
                                    : Icons.visibility_outlined,
                                size: 18,
                                color: AppTheme.textSoft,
                              ),
                              onPressed: () => setState(
                                  () => _obscurePassword = !_obscurePassword),
                            ),
                          ),
                          if (_mode == _Mode.signUp) ...[
                            const SizedBox(height: 20),
                            _buildRoleSelector(),
                          ],
                        ],
                        if (_error != null) ...[
                          const SizedBox(height: 16),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 10),
                            decoration: BoxDecoration(
                              color: AppTheme.statusAlert.withOpacity(0.08),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: AppTheme.statusAlert.withOpacity(0.2),
                              ),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.error_outline_rounded,
                                    color: AppTheme.statusAlert, size: 18),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    _error!,
                                    style: const TextStyle(
                                      color: AppTheme.statusAlert,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                        const SizedBox(height: 24),
                        SizedBox(
                          height: 48,
                          child: ElevatedButton(
                            onPressed: _loading ? null : _handleSubmit,
                            child: _loading
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : Text(
                                    _mode == _Mode.signIn
                                        ? 'Sign In'
                                        : _mode == _Mode.signUp
                                            ? 'Create Account'
                                            : 'Verify',
                                    style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 20),

                  // ── Toggle sign-in / sign-up ─────────────────
                  if (_mode != _Mode.confirm)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          _mode == _Mode.signIn
                              ? "Don't have an account?"
                              : 'Already have an account?',
                          style: const TextStyle(
                            color: AppTheme.textSoft,
                            fontSize: 13,
                          ),
                        ),
                        TextButton(
                          onPressed: () => setState(() {
                            _error = null;
                            _mode = _mode == _Mode.signIn
                                ? _Mode.signUp
                                : _Mode.signIn;
                          }),
                          child: Text(
                            _mode == _Mode.signIn ? 'Sign Up' : 'Sign In',
                            style: const TextStyle(
                              color: AppTheme.sage,
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  VoidCallback get _handleSubmit {
    switch (_mode) {
      case _Mode.signIn:
        return _handleSignIn;
      case _Mode.signUp:
        return _handleSignUp;
      case _Mode.confirm:
        return _handleConfirm;
    }
  }

  Widget _buildField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    TextInputType? keyboardType,
    bool obscure = false,
    Widget? suffix,
  }) {
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
        TextField(
          controller: controller,
          keyboardType: keyboardType,
          obscureText: obscure,
          onSubmitted: (_) => _handleSubmit(),
          style: const TextStyle(
            color: AppTheme.textDark,
            fontSize: 14,
          ),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(
              color: AppTheme.textSoft.withOpacity(0.5),
              fontSize: 14,
            ),
            prefixIcon: Icon(icon, size: 18, color: AppTheme.textSoft),
            suffixIcon: suffix,
            filled: true,
            fillColor: AppTheme.cream,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: AppTheme.border.withOpacity(0.5)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: AppTheme.border.withOpacity(0.5)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: AppTheme.sage, width: 1.5),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRoleSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'I am a...',
          style: TextStyle(
            color: AppTheme.textDark,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _RoleChip(
                label: 'Walker',
                subtitle: 'I use the device',
                icon: Icons.directions_walk_rounded,
                selected: _selectedRole == UserRole.walker,
                onTap: () => setState(() => _selectedRole = UserRole.walker),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _RoleChip(
                label: 'Caregiver',
                subtitle: 'I monitor a walker',
                icon: Icons.favorite_outline_rounded,
                selected: _selectedRole == UserRole.caregiver,
                onTap: () =>
                    setState(() => _selectedRole = UserRole.caregiver),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _RoleChip extends StatelessWidget {
  const _RoleChip({
    required this.label,
    required this.subtitle,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String subtitle;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: selected ? AppTheme.sage.withOpacity(0.08) : AppTheme.cream,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? AppTheme.sage : AppTheme.border.withOpacity(0.5),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 20,
              color: selected ? AppTheme.sage : AppTheme.textSoft,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      color: selected ? AppTheme.sage : AppTheme.textDark,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      color: AppTheme.textSoft,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            if (selected)
              const Icon(Icons.check_circle_rounded,
                  color: AppTheme.sage, size: 18),
          ],
        ),
      ),
    );
  }
}
