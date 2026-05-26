import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../auth/auth_service_interface.dart';
import '../data/facility_repository.dart';
import 'build_mode.dart';
import 'polling_controller.dart';

/// Container for the four injected dependencies the [AppShell] threads
/// through the widget tree: auth service, facility data, (in live mode)
/// the ApiClient, and the [PollingController] that drives foreground-
/// only Census + Patient Detail refresh ticks.
///
/// Picked up by descendant widgets via `AppState.of(context)`.
///
/// Per phase-2b-0-foundation.md §Files Changed > lib/state/app_state.dart
/// + phase-2b-fac-r-facility-reads.md L3 + L11 (polling).
class AppState extends InheritedNotifier<AuthServiceInterface> {
  final AuthServiceInterface auth;
  final FacilityRepository repository;
  final ApiClient? apiClient;
  final BuildMode buildMode;
  final PollingController polling;

  AppState({
    super.key,
    required this.auth,
    required this.repository,
    required this.apiClient,
    required this.buildMode,
    required this.polling,
    required super.child,
  }) : super(notifier: auth);

  static AppState of(BuildContext context) {
    final state = context.dependOnInheritedWidgetOfExactType<AppState>();
    if (state == null) {
      throw StateError(
        'AppState.of() called outside an AppState provider. '
        'Wrap your root widget in AppState(...) (see lib/shell/app_shell.dart).',
      );
    }
    return state;
  }
}
