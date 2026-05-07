import 'package:flutter/material.dart';

import '../../screens/device_screen.dart';
import '../../theme/app_theme.dart';
import '../../widgets/patient_dashboard.dart';
import '../data/facility_mock_data.dart';
import '../data/notification_engine.dart';
import '../models/patient.dart';
import '../state/facility_selection.dart';
import '../state/notification_state.dart';
import '../widgets/notification_review_panel.dart';

/// Right pane (or full-screen overlay on medium screens) of the facility
/// shell. Empty state when no patient selected; full reuse of the existing
/// `PatientDashboard` widget when one is. Per spec §5.6.
class PatientDetailView extends StatelessWidget {
  const PatientDetailView({
    super.key,
    required this.data,
    required this.selection,
    required this.notifications,
    this.showBackButton = false,
  });

  final FacilityMockData data;
  final FacilitySelection selection;
  final NotificationState notifications;
  final bool showBackButton;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([selection, notifications]),
      builder: (context, _) {
        final id = selection.selectedPatientId;
        if (id == null) {
          return const _EmptyState();
        }
        final patient = data.patientById(id);
        return _PatientView(
          data: data,
          patient: patient,
          notifications: notifications,
          showBackButton: showBackButton,
          onBack: selection.clearPatient,
        );
      },
    );
  }
}

class _PatientView extends StatelessWidget {
  const _PatientView({
    required this.data,
    required this.patient,
    required this.notifications,
    required this.showBackButton,
    required this.onBack,
  });

  final FacilityMockData data;
  final Patient patient;
  final NotificationState notifications;
  final bool showBackButton;
  final VoidCallback onBack;

  void _openDeviceScreen(BuildContext context) {
    final device = data.deviceFor(patient.id);
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => DeviceScreen(device: device)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final today = data.todayFor(patient.id);
    final last7 = data.last7DaysFor(patient.id);
    final last30 = data.last30DaysFor(patient.id);
    final last6m = data.last6MonthsFor(patient.id);
    final device = data.deviceFor(patient.id);
    final unitDisplay =
        data.allUnits().firstWhere((u) => u.id == patient.unitId).displayName;

    final computed = notificationsForPatient(data, patient.id);
    final active = notifications.activeOf(computed);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(36, 28, 36, 48),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showBackButton) ...[
            _BackToCensusButton(onTap: onBack),
            const SizedBox(height: 12),
          ],
          _PatientHeader(
            name: patient.displayName,
            unit: unitDisplay,
            room: patient.room,
          ),
          const SizedBox(height: 20),
          if (active.isNotEmpty) ...[
            NotificationReviewPanel(
              notifications: active,
              state: notifications,
            ),
            const SizedBox(height: 24),
          ],
          PatientDashboard(
            device: device,
            today: today,
            last7: last7,
            last30: last30,
            last6Months: last6m,
            onDeviceTap: () => _openDeviceScreen(context),
          ),
        ],
      ),
    );
  }
}

class _PatientHeader extends StatelessWidget {
  const _PatientHeader({
    required this.name,
    required this.unit,
    required this.room,
  });

  final String name;
  final String unit;
  final String room;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          name,
          style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                fontSize: 30,
                fontWeight: FontWeight.w500,
              ),
        ),
        const SizedBox(height: 4),
        Text(
          '$unit  ·  Room $room',
          style: const TextStyle(
            color: AppTheme.textSoft,
            fontSize: 15,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

class _BackToCensusButton extends StatelessWidget {
  const _BackToCensusButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: const [
              Icon(Icons.arrow_back_rounded, color: AppTheme.sage, size: 18),
              SizedBox(width: 6),
              Text(
                'Back to Census',
                style: TextStyle(
                  color: AppTheme.sage,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.person_outline_rounded,
              size: 56,
              color: AppTheme.textSoft.withOpacity(0.35),
            ),
            const SizedBox(height: 18),
            Text(
              'Select a resident',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontSize: 20,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              'Choose a resident from the census to see their\ndaily activity, trends, and device health.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppTheme.textSoft,
                fontSize: 14,
                height: 1.55,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
