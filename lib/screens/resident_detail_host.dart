import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../facility_demo/screens/patient_detail_view.dart';
import '../facility_demo/state/facility_selection.dart';
import '../facility_demo/state/notification_state.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';

/// Route host for `/residents/{patientId}` — mounts the EXISTING per-resident
/// monitoring UI ([PatientDetailView]) for an internal user, driven by just a
/// patientId (the whole loader→repository→API path is patientId-keyed; internal
/// callers can read any patient). No census/clientId needed. user-analytics.md
/// §pilot view.
///
/// Reuses the shared [FacilityRepository] that AppState injected app-wide (same
/// instance the polling controller drives), so activity/alerts/device all load
/// exactly as they do in the customer census — just reached by URL instead of
/// the in-memory census overlay.
class ResidentDetailHost extends StatefulWidget {
  const ResidentDetailHost({super.key, required this.patientId});

  final String patientId;

  @override
  State<ResidentDetailHost> createState() => _ResidentDetailHostState();
}

class _ResidentDetailHostState extends State<ResidentDetailHost> {
  FacilitySelection? _selection;
  final NotificationState _notifications = NotificationState();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_selection == null) {
      final repo = AppState.of(context).repository;
      _selection = FacilitySelection(repo)..selectPatient(widget.patientId);
    }
  }

  @override
  void dispose() {
    _selection?.dispose();
    _notifications.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final repo = AppState.of(context).repository;
    final auth = AppState.of(context).auth;
    return Scaffold(
      backgroundColor: AppTheme.cream,
      appBar: AppBar(
        title: const Text('Resident — internal'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Back to residents',
          onPressed: () => context.go('/residents'),
        ),
        actions: [
          TextButton.icon(
            onPressed: () => context.go('/fleet'),
            icon: const Icon(Icons.dns_outlined, size: 18),
            label: const Text('Fleet'),
            style: TextButton.styleFrom(foregroundColor: AppTheme.textSoft),
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Sign out',
            onPressed: () => auth.signOut(),
          ),
        ],
      ),
      // showBackButton: false — our AppBar handles navigation; the built-in
      // back only clears the selection (→ empty state), not a route pop.
      body: PatientDetailView(
        data: repo,
        selection: _selection!,
        notifications: _notifications,
      ),
    );
  }
}
