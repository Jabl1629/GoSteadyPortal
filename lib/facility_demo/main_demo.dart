import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'data/facility_mock_data.dart';
import 'screens/facility_login_screen.dart';
import 'screens/facility_shell.dart';
import 'services/mock_facility_auth.dart';

/// Entry point for the facility demo build.
///
/// Build:
///   flutter build web -t lib/facility_demo/main_demo.dart
///
/// Run locally:
///   flutter run -d chrome -t lib/facility_demo/main_demo.dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FacilityMockAuthService.instance.init();
  runApp(const _GoSteadyFacilityDemoApp());
}

class _GoSteadyFacilityDemoApp extends StatelessWidget {
  const _GoSteadyFacilityDemoApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GoSteady — Facility Demo',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.build(),
      home: _AuthGate(),
    );
  }
}

/// Listens to FacilityMockAuthService and swaps between the login screen
/// and the facility shell. Mirrors the pattern used by the real AuthService
/// gate in the legacy `main.dart`.
class _AuthGate extends StatefulWidget {
  @override
  State<_AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<_AuthGate> {
  final _auth = FacilityMockAuthService.instance;
  // Single FacilityMockData instance for the session — generated patient
  // data caches inside it for determinism and perf.
  final FacilityMockData _data = FacilityMockData();

  @override
  void initState() {
    super.initState();
    _auth.addListener(_onAuthChanged);
  }

  @override
  void dispose() {
    _auth.removeListener(_onAuthChanged);
    super.dispose();
  }

  void _onAuthChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (_auth.isSignedIn) {
      return FacilityShell(data: _data);
    }
    return const FacilityLoginScreen();
  }
}
