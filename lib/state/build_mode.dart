/// Compile-time build mode for the GoSteady portal.
///
/// Toggled via `--dart-define=BUILD_MODE=demo|live`. Default is `demo`
/// so a forgetting-the-flag developer build looks like the demo, not
/// like a broken portal.
///
/// Per phase-2b-0-foundation.md L2.
enum BuildMode {
  /// Marketing demo build. Uses [FacilityMockData] + [MockAuthService].
  /// Deploys to `facilitydemo.gosteady.co`.
  demo,

  /// Production-shaped build. Uses [LiveFacilityRepository] + Cognito
  /// [AuthService]. Deploys to `dev.portal.gosteady.co` (and eventually
  /// `portal.gosteady.co` in Phase 3A).
  live;

  /// The build mode of the current binary. Read once at startup.
  static BuildMode get current {
    const raw = String.fromEnvironment('BUILD_MODE', defaultValue: 'demo');
    return BuildMode.values.firstWhere(
      (m) => m.name == raw,
      orElse: () => BuildMode.demo,
    );
  }

  bool get isLive => this == BuildMode.live;
  bool get isDemo => this == BuildMode.demo;
}
