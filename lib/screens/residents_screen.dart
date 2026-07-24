import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../api/api_client.dart';
import '../api/api_exception.dart';
import '../facility_demo/data/facility_mock_data.dart' show PatientRowStats;
import '../facility_demo/models/notification.dart';
import '../facility_demo/models/patient.dart';
import '../facility_demo/models/unit.dart';
import '../facility_demo/widgets/patient_list_view.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';

/// Internal "Pilot residents" — a cross-tenant roster of every active D2C
/// participant, rendered with the SAME list-view table the facility Census
/// uses ([PatientListView]): activity-minutes today/7d/trend, steps + trend,
/// gait + trend, notifications. Internal-only (gated in app_router.dart; the
/// patient-api enforces server-side). Tapping a row opens the existing
/// per-resident monitoring detail via `/residents/{patientId}`.
/// docs/specs/user-analytics.md §pilot view.
class ResidentsScreen extends StatefulWidget {
  const ResidentsScreen({super.key});

  @override
  State<ResidentsScreen> createState() => _ResidentsScreenState();
}

class _ResidentsScreenState extends State<ResidentsScreen> {
  Future<List<PatientListRow>>? _future;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _future ??= _load();
  }

  void _refresh() => setState(() => _future = _load());

  /// Builds the list-view rows. Live: the internal cross-tenant roster
  /// (`GET /admin/residents`) + per-patient stats/notifications (patientId-
  /// keyed, so they serve internal). Demo: reuses the mock census residents so
  /// the marketing-demo internal view still renders. Both feed the same
  /// [PatientRowStats]/[PatientNotification] pipeline the Census uses.
  Future<List<PatientListRow>> _load() async {
    final repo = AppState.of(context).repository;
    final ApiClient? api = AppState.of(context).apiClient;

    Future<PatientListRow> rowFor(
      Patient patient,
      String unitDisplay,
    ) async {
      final results = await Future.wait([
        repo.rowStatsFor(patient.id),
        repo.notificationsFor(patient.id),
      ]);
      return PatientListRow(
        patient: patient,
        unitDisplay: unitDisplay,
        stats: results[0] as PatientRowStats,
        activeNotifications: results[1] as List<PatientNotification>,
      );
    }

    if (api != null) {
      // LIVE — cross-tenant pilot roster. No real unit/room (D2C households),
      // so the Location column shows the cap serial (the useful per-participant
      // identifier for internal monitoring).
      final res = await api.getResidents();
      return Future.wait(res.residents.map((r) {
        final patient = Patient(
          id: r.patientId,
          displayName: r.displayName.isEmpty ? '(no name)' : r.displayName,
          facilityId: '',
          unitId: '',
          room: '', // D2C: no room — the list view omits "· Rm" when empty
          deviceSerial: r.deviceSerial.isEmpty ? null : r.deviceSerial,
        );
        return rowFor(patient, r.deviceSerial.isEmpty ? 'D2C' : r.deviceSerial);
      }));
    }

    // DEMO — reuse the mock census residents (so an internal demo login still
    // sees a populated table, matching the facility demo).
    final units = repo.allUnits();
    final summaries =
        repo.patientsForSelection(units.map((u) => u.id).toSet());
    return Future.wait(summaries.map((s) {
      return rowFor(s.patient, _unitName(units, s.patient.unitId));
    }));
  }

  @override
  Widget build(BuildContext context) {
    final auth = AppState.of(context).auth;
    return Scaffold(
      backgroundColor: AppTheme.cream,
      appBar: AppBar(
        title: const Text('Residents — internal'),
        actions: [
          TextButton.icon(
            onPressed: () => context.go('/fleet'),
            icon: const Icon(Icons.dns_outlined, size: 18),
            label: const Text('Fleet'),
            style: TextButton.styleFrom(foregroundColor: AppTheme.textSoft),
          ),
          TextButton.icon(
            onPressed: () => context.go('/analytics'),
            icon: const Icon(Icons.insights_outlined, size: 18),
            label: const Text('Analytics'),
            style: TextButton.styleFrom(foregroundColor: AppTheme.textSoft),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _refresh,
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Sign out',
            onPressed: () => auth.signOut(),
          ),
        ],
      ),
      body: FutureBuilder<List<PatientListRow>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(
                child: CircularProgressIndicator(color: AppTheme.sage));
          }
          if (snap.hasError) {
            return _ErrorPanel(error: snap.error, onRetry: _refresh);
          }
          final rows = snap.data ?? const <PatientListRow>[];
          return SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1240),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Header(count: rows.length),
                    const SizedBox(height: 16),
                    if (rows.isEmpty)
                      const _EmptyPanel()
                    else
                      PatientListView(
                        rows: rows,
                        selectedPatientId: null,
                        onSelect: (pid) => context.go('/residents/$pid'),
                        // Rollator pilot: no steps on these devices, and the
                        // low/high active-minute bands aren't calibrated yet.
                        showSteps: false,
                        colorMetrics: false,
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

String _unitName(List<Unit> units, String unitId) {
  for (final u in units) {
    if (u.id == unitId) return u.displayName;
  }
  return unitId;
}

class _Header extends StatelessWidget {
  const _Header({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text('Pilot residents',
            style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: AppTheme.textDark)),
        const SizedBox(width: 12),
        Text('$count ${count == 1 ? 'resident' : 'residents'}',
            style: TextStyle(fontSize: 14, color: AppTheme.textSoft)),
      ],
    );
  }
}

class _EmptyPanel extends StatelessWidget {
  const _EmptyPanel();
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 60),
      child: Center(
        child: Text('No active pilot residents.',
            style: TextStyle(color: AppTheme.textSoft, fontSize: 15)),
      ),
    );
  }
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.error, required this.onRetry});
  final Object? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final msg = error is ApiException
        ? '${(error as ApiException).code}: ${(error as ApiException).message}'
        : '$error';
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, color: AppTheme.statusAlert, size: 40),
          const SizedBox(height: 12),
          Text('Couldn\'t load residents',
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textDark)),
          const SizedBox(height: 6),
          Text(msg, style: TextStyle(fontSize: 13, color: AppTheme.textSoft)),
          const SizedBox(height: 16),
          FilledButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}
