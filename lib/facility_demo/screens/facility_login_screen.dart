import 'package:flutter/material.dart';

import '../../auth/mock_auth_service.dart';
import '../../theme/app_theme.dart';

/// Minimal login screen for the demo build. Per spec §9: no email/password
/// fields — investors don't sign up at booths. One button signs in as the
/// canned facility_admin persona.
class FacilityLoginScreen extends StatefulWidget {
  const FacilityLoginScreen({super.key});

  @override
  State<FacilityLoginScreen> createState() => _FacilityLoginScreenState();
}

class _FacilityLoginScreenState extends State<FacilityLoginScreen> {
  bool _busy = false;

  Future<void> _handleSignIn() async {
    if (_busy) return;
    setState(() => _busy = true);
    await MockAuthService.instance.signIn('demo', 'demo');
    // No need to clear _busy — _AuthGate swaps screens immediately.
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.warmWhite,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: AppTheme.sage,
                      borderRadius: BorderRadius.circular(18),
                      boxShadow: AppTheme.cardShadowElevated,
                    ),
                    child: const Icon(
                      Icons.accessibility_new_rounded,
                      color: Colors.white,
                      size: 32,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'GoSteady',
                    style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                          fontSize: 36,
                          fontWeight: FontWeight.w500,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Facility activity-monitoring portal',
                    style: TextStyle(
                      color: AppTheme.textSoft,
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0.1,
                    ),
                  ),
                  const SizedBox(height: 48),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _busy ? null : _handleSignIn,
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 18),
                        textStyle: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.2,
                        ),
                      ),
                      child: _busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text('Sign in to demo'),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Demo build · static data, no real authentication',
                    style: TextStyle(
                      color: AppTheme.textSoft.withOpacity(0.7),
                      fontSize: 12,
                      letterSpacing: 0.2,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
