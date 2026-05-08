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
///
/// **Mobile testing**: append `?w=NUMBER` to the URL to wrap the app in
/// a phone-shaped device frame so the layout behaves as if the window
/// were that wide. Useful values:
///   ?w=390   iPhone 14 / 13 Pro          (390 x 844)
///   ?w=430   iPhone 14 / 15 Pro Max      (430 x 932)
///   ?w=744   iPad mini portrait          (744 x 1133)
///   ?w=1024  iPad Pro portrait           (1024 x 1366)
/// No param = full-window desktop layout.
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FacilityMockAuthService.instance.init();
  runApp(const _GoSteadyFacilityDemoApp());
}

class _GoSteadyFacilityDemoApp extends StatelessWidget {
  const _GoSteadyFacilityDemoApp();

  @override
  Widget build(BuildContext context) {
    final deviceOverride = _DeviceOverride.fromUrl();
    return MaterialApp(
      title: 'GoSteady — Facility Demo',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.build(),
      home: deviceOverride == null
          ? _AuthGate()
          : _DeviceFrame(deviceOverride: deviceOverride, child: _AuthGate()),
    );
  }
}

/// Optional viewport deviceOverride read from the page URL. When present, the
/// app is laid out as if the window were `width` x `height` even though
/// the surrounding canvas may be much larger — lets us iterate on phone
/// layouts on a desktop without resizing the window each time.
class _DeviceOverride {
  final double width;
  final double height;
  const _DeviceOverride(this.width, this.height);

  /// Parses `?w=NUMBER` from the current page URL. Returns null if the
  /// param is absent or unparseable. Heights are picked to feel like a
  /// real device of that width.
  static _DeviceOverride? fromUrl() {
    try {
      final w = Uri.base.queryParameters['w'];
      if (w == null) return null;
      final width = double.tryParse(w);
      if (width == null || width < 200 || width > 2000) return null;
      // Pair with a sensible aspect: phones lean tall (~9:19.5),
      // tablets squarer (~3:4).
      final height = width <= 500
          ? width * (19.5 / 9.0) // ~390 -> 845, 430 -> 932
          : width * (4.0 / 3.0); // ~744 -> 992, 1024 -> 1365
      return _DeviceOverride(width, height);
    } catch (_) {
      return null;
    }
  }
}

/// Centers the app inside a fixed-size box and deviceOverrides MediaQuery so
/// downstream layout code sees the smaller viewport. The surrounding
/// area stays grey (like a device frame on a laptop screen).
class _DeviceFrame extends StatelessWidget {
  const _DeviceFrame({required this.deviceOverride, required this.child});
  final _DeviceOverride deviceOverride;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final size = Size(deviceOverride.width, deviceOverride.height);
    final outerMq = MediaQuery.of(context);
    return ColoredBox(
      color: const Color(0xFFE5E0D8), // matches AppTheme.border, neutral
      child: Center(
        child: Container(
          width: size.width,
          height: size.height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(28),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.12),
                blurRadius: 28,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: MediaQuery(
            data: outerMq.copyWith(
              size: size,
              padding: EdgeInsets.zero,
              viewInsets: EdgeInsets.zero,
              viewPadding: EdgeInsets.zero,
            ),
            child: child,
          ),
        ),
      ),
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
