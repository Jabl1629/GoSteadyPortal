/// Build-mode-aware route paths for the signed-in D2C **display** surface
/// (dashboard, history, care team, account) that is shared between two
/// shells:
///   • the wireframe **preview hub** (`app_router.dart`, `main.dart`),
///     which mounts these screens under `/d2c/preview/*`; and
///   • the **live app** (`main_d2c.dart` / `buildD2CRouter`), which mounts
///     them at the root.
///
/// Each binary runs exactly one entry point, which sets [prefix] once at
/// startup — so the shared [D2CBottomNav] and the dashboard's intra-screen
/// links navigate to the right place without threading route config
/// through every widget constructor. The live entry sets `prefix = ''`.
class D2CRoutes {
  D2CRoutes._();

  /// `/d2c/preview` for the preview hub (default); `''` for the live app.
  static String prefix = '/d2c/preview';

  static String get dashboard => '$prefix/dashboard';
  static String get history => '$prefix/history';
  static String get careTeam => '$prefix/care-team';
  static String get account => '$prefix/account';

  /// The Coach ("Steady") tab + its "What Steady knows about you" memory
  /// sub-route (ai-coach-c1-text-chat.md §5.7). Getters — resolved against
  /// [prefix] so both the preview hub and the live app route correctly.
  static String get coach => '$prefix/coach';
  static String get coachMemory => '$prefix/coach/memory';
}
