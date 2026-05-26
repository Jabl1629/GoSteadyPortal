import 'package:flutter/material.dart';

import '../auth/auth_service.dart';
import '../auth/auth_service_interface.dart';
import '../models/user.dart';
import '../theme/app_theme.dart';

/// GoSteady portal sign-in. Handles four modes:
///   - signIn: email + password
///   - mfaVerify: 6-digit TOTP code after Cognito returns an MFA challenge
///   - forgotEmail: enter email to request reset code
///   - forgotConfirm: enter code + new password to complete reset
///
/// Per phase-2b-0-foundation.md §Files Changed > lib/screens/login_screen.dart.
/// Sign-up was removed from the portal — D2C onboarding lives on the
/// marketing site; facility users are admin-created.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.onSignedIn});

  /// Called after successful sign-in. GoRouter's `refreshListenable`
  /// also picks up the auth change automatically; this callback exists
  /// for callers that want imperative knowledge of the event.
  final ValueChanged<GoSteadyUser> onSignedIn;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

enum _Mode { signIn, mfaVerify, forgotEmail, forgotConfirm }

class _LoginScreenState extends State<LoginScreen> {
  final _auth = AuthService.instance;

  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  final _newPasswordCtrl = TextEditingController();

  _Mode _mode = _Mode.signIn;
  bool _loading = false;
  String? _error;
  String? _info;
  bool _obscurePassword = true;
  bool _obscureNewPassword = true;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _codeCtrl.dispose();
    _newPasswordCtrl.dispose();
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
      _info = null;
    });

    try {
      final user = await _auth.signIn(
        _emailCtrl.text.trim(),
        _passwordCtrl.text,
      );
      widget.onSignedIn(user);
    } on MfaChallengeRequired {
      setState(() {
        _mode = _Mode.mfaVerify;
        _info = 'Enter the 6-digit code from your authenticator app.';
      });
    } on AuthException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _handleMfaVerify() async {
    if (_codeCtrl.text.trim().length < 6) {
      setState(() => _error = 'Enter the 6-digit code.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final user = await _auth.completeMfaChallenge(_codeCtrl.text.trim());
      widget.onSignedIn(user);
    } on AuthException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _handleForgotEmail() async {
    if (_emailCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Enter your email to receive a reset code.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      await _auth.forgotPassword(_emailCtrl.text.trim());
      setState(() {
        _mode = _Mode.forgotConfirm;
        _info = 'We sent a reset code to ${_emailCtrl.text.trim()}.';
      });
    } on AuthException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _handleForgotConfirm() async {
    if (_codeCtrl.text.trim().isEmpty || _newPasswordCtrl.text.isEmpty) {
      setState(() => _error = 'Enter the code and your new password.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      await _auth.confirmForgotPassword(
        _emailCtrl.text.trim(),
        _codeCtrl.text.trim(),
        _newPasswordCtrl.text,
      );
      // Sign in directly with the new password.
      final user = await _auth.signIn(
        _emailCtrl.text.trim(),
        _newPasswordCtrl.text,
      );
      widget.onSignedIn(user);
    } on MfaChallengeRequired {
      setState(() {
        _mode = _Mode.mfaVerify;
        _info = 'Password reset. Enter the 6-digit code from your authenticator app.';
      });
    } on AuthException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  VoidCallback get _handleSubmit {
    switch (_mode) {
      case _Mode.signIn:
        return _handleSignIn;
      case _Mode.mfaVerify:
        return _handleMfaVerify;
      case _Mode.forgotEmail:
        return _handleForgotEmail;
      case _Mode.forgotConfirm:
        return _handleForgotConfirm;
    }
  }

  String get _submitLabel {
    switch (_mode) {
      case _Mode.signIn:
        return 'Sign In';
      case _Mode.mfaVerify:
        return 'Verify';
      case _Mode.forgotEmail:
        return 'Send Reset Code';
      case _Mode.forgotConfirm:
        return 'Reset Password';
    }
  }

  String get _heading {
    switch (_mode) {
      case _Mode.signIn:
        return 'Sign in to your portal';
      case _Mode.mfaVerify:
        return 'Two-factor verification';
      case _Mode.forgotEmail:
        return 'Reset your password';
      case _Mode.forgotConfirm:
        return 'Enter reset code';
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
                    _heading,
                    style: const TextStyle(
                      color: AppTheme.textSoft,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 36),
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
                        if (_info != null) ...[
                          Text(
                            _info!,
                            style: const TextStyle(
                              color: AppTheme.textSoft,
                              fontSize: 13,
                              height: 1.5,
                            ),
                          ),
                          const SizedBox(height: 20),
                        ],
                        ..._buildFormFields(),
                        if (_error != null) ...[
                          const SizedBox(height: 16),
                          _ErrorBanner(_error!),
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
                                    _submitLabel,
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
                  if (_mode == _Mode.signIn) ...[
                    TextButton(
                      onPressed: () => setState(() {
                        _mode = _Mode.forgotEmail;
                        _error = null;
                        _info = null;
                      }),
                      child: const Text(
                        'Forgot password?',
                        style: TextStyle(
                          color: AppTheme.sage,
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ] else ...[
                    TextButton(
                      onPressed: () => setState(() {
                        _mode = _Mode.signIn;
                        _error = null;
                        _info = null;
                        _codeCtrl.clear();
                        _newPasswordCtrl.clear();
                      }),
                      child: const Text(
                        'Back to sign in',
                        style: TextStyle(
                          color: AppTheme.sage,
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
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

  List<Widget> _buildFormFields() {
    switch (_mode) {
      case _Mode.signIn:
        return [
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
            suffix: _ObscureToggle(
              obscured: _obscurePassword,
              onTap: () =>
                  setState(() => _obscurePassword = !_obscurePassword),
            ),
          ),
        ];
      case _Mode.mfaVerify:
        return [
          _buildField(
            controller: _codeCtrl,
            label: 'Authenticator code',
            hint: '123456',
            icon: Icons.pin_rounded,
            keyboardType: TextInputType.number,
          ),
        ];
      case _Mode.forgotEmail:
        return [
          _buildField(
            controller: _emailCtrl,
            label: 'Email',
            hint: 'you@example.com',
            icon: Icons.email_outlined,
            keyboardType: TextInputType.emailAddress,
          ),
        ];
      case _Mode.forgotConfirm:
        return [
          _buildField(
            controller: _codeCtrl,
            label: 'Reset code',
            hint: '123456',
            icon: Icons.pin_rounded,
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 16),
          _buildField(
            controller: _newPasswordCtrl,
            label: 'New password',
            hint: 'Enter new password',
            icon: Icons.lock_outline_rounded,
            obscure: _obscureNewPassword,
            suffix: _ObscureToggle(
              obscured: _obscureNewPassword,
              onTap: () => setState(
                  () => _obscureNewPassword = !_obscureNewPassword),
            ),
          ),
        ];
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
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner(this.message);
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
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
              message,
              style: const TextStyle(
                color: AppTheme.statusAlert,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ObscureToggle extends StatelessWidget {
  const _ObscureToggle({required this.obscured, required this.onTap});
  final bool obscured;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(
        obscured
            ? Icons.visibility_off_outlined
            : Icons.visibility_outlined,
        size: 18,
        color: AppTheme.textSoft,
      ),
      onPressed: onTap,
    );
  }
}
