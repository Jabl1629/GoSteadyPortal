import 'package:flutter/material.dart';
import 'package:url_strategy/url_strategy.dart';

import '../auth/mock_auth_service.dart';
import '../data/facility_repository.dart';
import '../shell/app_shell.dart';
import '../state/build_mode.dart';
import 'data/facility_mock_data.dart';

/// Entry point for the facility demo build.
///
/// Build:
///   flutter build web -t lib/facility_demo/main_demo.dart \
///     --dart-define=BUILD_MODE=demo
///
/// Run locally:
///   flutter run -d chrome -t lib/facility_demo/main_demo.dart \
///     --dart-define=BUILD_MODE=demo
///
/// **Mobile testing**: append `?w=NUMBER` to the URL to wrap the app in
/// a phone-shaped device frame so the layout behaves as if the window
/// were that wide. Useful values:
///   ?w=390   iPhone 14 / 13 Pro          (390 x 844)
///   ?w=430   iPhone 14 / 15 Pro Max      (430 x 932)
///   ?w=744   iPad mini portrait          (744 x 1133)
///   ?w=1024  iPad Pro portrait           (1024 x 1366)
/// No param = full-window desktop layout.
///
/// Per phase-2b-0-foundation.md D1 (two thin entry points share an
/// AppShell).
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  setPathUrlStrategy();

  final auth = MockAuthService.instance;
  await auth.init();
  final FacilityRepository repo = FacilityMockData();

  final deviceOverride = _DeviceOverride.fromUrl();
  final shell = AppShell(
    auth: auth,
    repository: repo,
    apiClient: null,
    buildMode: BuildMode.demo,
  );

  runApp(
    deviceOverride == null
        ? shell
        : _DeviceFrame(deviceOverride: deviceOverride, child: shell),
  );
}

/// Optional viewport override read from the page URL. When present, the
/// app is laid out as if the window were `width` x `height` even though
/// the surrounding canvas may be much larger.
class _DeviceOverride {
  final double width;
  final double height;
  const _DeviceOverride(this.width, this.height);

  static _DeviceOverride? fromUrl() {
    try {
      final w = Uri.base.queryParameters['w'];
      if (w == null) return null;
      final width = double.tryParse(w);
      if (width == null || width < 200 || width > 2000) return null;
      final height = width <= 500
          ? width * (19.5 / 9.0)
          : width * (4.0 / 3.0);
      return _DeviceOverride(width, height);
    } catch (_) {
      return null;
    }
  }
}

/// Centers the app inside a fixed-size box so downstream layout sees a
/// smaller viewport. Surrounding area stays a neutral grey.
class _DeviceFrame extends StatelessWidget {
  const _DeviceFrame({required this.deviceOverride, required this.child});
  final _DeviceOverride deviceOverride;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final size = Size(deviceOverride.width, deviceOverride.height);
    return ColoredBox(
      color: const Color(0xFFE5E0D8),
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
            data: MediaQuery.of(context).copyWith(
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
