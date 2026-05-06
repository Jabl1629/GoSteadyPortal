import 'package:flutter/material.dart';

import 'screens/dashboard_screen.dart';
import 'screens/login_screen.dart';
import 'services/auth_service.dart';
import 'theme/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AuthService.instance.init();
  runApp(const GoSteadyPortalApp());
}

class GoSteadyPortalApp extends StatelessWidget {
  const GoSteadyPortalApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GoSteady Portal',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.build(),
      home: const _AuthGate(),
    );
  }
}

/// Listens to [AuthService] and shows either the login or dashboard.
class _AuthGate extends StatefulWidget {
  const _AuthGate();

  @override
  State<_AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<_AuthGate> {
  final _auth = AuthService.instance;

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
      return const DashboardScreen();
    }
    return LoginScreen(
      onSignedIn: (_) => setState(() {}),
    );
  }
}
