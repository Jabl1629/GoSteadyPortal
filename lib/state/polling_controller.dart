import 'dart:async';

import 'package:flutter/material.dart';

/// Drives the foreground-only polling cadence for Census + Patient
/// Detail per phase-2b-fac-r-facility-reads.md L3 + L11.
///
/// - Census refresh tick fires every [censusInterval] (default 60 s).
/// - Patient Detail refresh tick fires every [patientInterval]
///   (default 30 s) for the currently-active patientId.
/// - Both timers pause when [AppLifecycleState] leaves `resumed`
///   (tab backgrounded / window blurred / app minimized) and resume
///   immediately when it returns. Honors the audit-cost ceiling
///   spelled out in phase-2b umbrella A4.
///
/// Consumers subscribe to [censusTick] / [patientTick] (both
/// `ValueNotifier<int>`); each tick is just a counter increment.
/// Listeners call the matching repository `refresh*()` method on
/// every fire — there is no special tick payload.
///
/// Lifecycle:
/// - Construct once in [AppShell], call [attach] in initState,
///   [detach] in dispose. The controller registers itself as a
///   [WidgetsBindingObserver] for app-lifecycle events.
/// - Screens call [startCensusPolling] / [startPatientPolling]
///   when they mount, and [stopCensusPolling] /
///   [stopPatientPolling] when they unmount. Calling start when
///   backgrounded is a no-op until the app returns to foreground.
class PollingController extends ChangeNotifier with WidgetsBindingObserver {
  PollingController({
    this.censusInterval = const Duration(seconds: 60),
    this.patientInterval = const Duration(seconds: 30),
  });

  final Duration censusInterval;
  final Duration patientInterval;

  /// Ticks consumed by the Census view.
  final ValueNotifier<int> censusTick = ValueNotifier(0);

  /// Ticks consumed by the Patient Detail view.
  final ValueNotifier<int> patientTick = ValueNotifier(0);

  bool _isForeground = true;

  /// True when the app is in [AppLifecycleState.resumed]. Mainly
  /// exposed for tests; production consumers just react to ticks.
  bool get isForeground => _isForeground;

  bool _censusActive = false;
  bool _patientActive = false;
  String? _activePatientId;
  Timer? _censusTimer;
  Timer? _patientTimer;

  bool _attached = false;

  void attach() {
    if (_attached) return;
    WidgetsBinding.instance.addObserver(this);
    _attached = true;
  }

  void detach() {
    if (!_attached) return;
    WidgetsBinding.instance.removeObserver(this);
    _attached = false;
    _cancelTimers();
  }

  @override
  void dispose() {
    detach();
    censusTick.dispose();
    patientTick.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (foreground == _isForeground) return;
    _isForeground = foreground;
    if (!_isForeground) {
      _cancelTimers();
    } else {
      _maybeStartCensusTimer();
      _maybeStartPatientTimer();
    }
    notifyListeners();
  }

  void startCensusPolling() {
    _censusActive = true;
    _maybeStartCensusTimer();
  }

  void stopCensusPolling() {
    _censusActive = false;
    _censusTimer?.cancel();
    _censusTimer = null;
  }

  void startPatientPolling(String patientId) {
    _activePatientId = patientId;
    _patientActive = true;
    _maybeStartPatientTimer();
  }

  void stopPatientPolling() {
    _patientActive = false;
    _activePatientId = null;
    _patientTimer?.cancel();
    _patientTimer = null;
  }

  /// Currently-tracked patient (or null if no Patient Detail is open).
  /// Exposed for tests + assertions.
  String? get activePatientId => _activePatientId;

  void _maybeStartCensusTimer() {
    if (!_censusActive || !_isForeground) return;
    _censusTimer?.cancel();
    _censusTimer = Timer.periodic(censusInterval, (_) => censusTick.value++);
  }

  void _maybeStartPatientTimer() {
    if (!_patientActive || !_isForeground || _activePatientId == null) return;
    _patientTimer?.cancel();
    _patientTimer = Timer.periodic(patientInterval, (_) => patientTick.value++);
  }

  void _cancelTimers() {
    _censusTimer?.cancel();
    _censusTimer = null;
    _patientTimer?.cancel();
    _patientTimer = null;
  }
}
