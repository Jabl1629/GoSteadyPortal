import 'package:flutter/material.dart';

import 'screens/dashboard_screen.dart';
import 'theme/app_theme.dart';

void main() {
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
      home: const DashboardScreen(),
    );
  }
}
