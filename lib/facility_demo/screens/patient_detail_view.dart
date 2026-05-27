import 'package:flutter/material.dart';

import '../../data/facility_repository.dart';
import '../../models/activity.dart';
import '../../models/device.dart';
import '../../screens/device_screen.dart';
import '../../state/app_state.dart';
import '../../state/build_mode.dart';
import '../../state/polling_controller.dart';
import '../../theme/app_theme.dart';
import '../../widgets/patient_dashboard.dart';
import '../data/notification_engine.dart';
import '../models/notification.dart';
import '../models/patient.dart';
import '../state/facility_selection.dart';
import '../state/notification_state.dart';
import '../widgets/care_note_panel.dart';
import '../widgets/notification_review_panel.dart';
import '../widgets/pause_banner.dart';
import '../widgets/resident_settings_dialog.dart';

/// Right pane (or full-screen overlay on medium screens) of the facility
/// shell. Empty state when no patient selected; full reuse of the existing
/// `PatientDashboard` widget when one is. Per spec §5.6.
///
/// Per phase-2b-fac-r-facility-reads.md L9: all 3 detail endpoints fetch
/// in parallel via `Future.wait` (not serially). The loader spinner shows
/// until all loads complete.
class PatientDetailView extends StatelessWidget {
  const PatientDetailView({
    super.key,
    required this.data,
    required this.selection,
    required this.notifications,
    this.showBackButton = false,
  });

  final FacilityRepository data;
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
        return _PatientDetailLoader(
          key: ValueKey(id),
          data: data,
          patientId: id,
          notifications: notifications,
          showBackButton: showBackButton,
          onBack: selection.clearPatient,
        );
      },
    );
  }
}

/// Loads all the patient-detail data in parallel + renders the loaded
/// dashboard once everything resolves. Per L9 — `Future.wait` over
/// patientById + deviceFor + todayFor + last7DaysFor + last30DaysFor +
/// last6MonthsFor + notificationsForPatient.
class _PatientDetailLoader extends StatefulWidget {
  const _PatientDetailLoader({
    super.key,
    required this.data,
    required this.patientId,
    required this.notifications,
    required this.showBackButton,
    required this.onBack,
  });

  final FacilityRepository data;
  final String patientId;
  final NotificationState notifications;
  final bool showBackButton;
  final VoidCallback onBack;

  @override
  State<_PatientDetailLoader> createState() => _PatientDetailLoaderState();
}

class _PatientDetailLoaderState extends State<_PatientDetailLoader> {
  late Future<_PatientDetailBundle> _bundle;
  PollingController? _polling;

  @override
  void initState() {
    super.initState();
    _bundle = _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Per phase-2b-fac-r-facility-reads.md L3 — 30s Patient Detail
    // poll driven by the AppShell-mounted PollingController.
    final ctl = AppState.of(context).polling;
    if (ctl != _polling) {
      _polling?.patientTick.removeListener(_onPollTick);
      _polling?.stopPatientPolling();
      _polling = ctl;
      _polling!.patientTick.addListener(_onPollTick);
      _polling!.startPatientPolling(widget.patientId);
    }
  }

  @override
  void dispose() {
    _polling?.patientTick.removeListener(_onPollTick);
    _polling?.stopPatientPolling();
    super.dispose();
  }

  Future<_PatientDetailBundle> _load() async {
    final results = await Future.wait([
      widget.data.patientById(widget.patientId),
      widget.data.deviceFor(widget.patientId),
      widget.data.todayFor(widget.patientId),
      widget.data.last7DaysFor(widget.patientId),
      widget.data.last30DaysFor(widget.patientId),
      widget.data.last6MonthsFor(widget.patientId),
      notificationsForPatient(widget.data, widget.patientId),
    ]);
    return _PatientDetailBundle(
      patient: results[0] as Patient,
      device: results[1] as DeviceHealth,
      today: results[2] as DailyActivity,
      last7: results[3] as List<DailyActivity>,
      last30: results[4] as List<DailyActivity>,
      last6m: results[5] as List<WeeklyActivity>,
      notifications: results[6] as List<PatientNotification>,
    );
  }

  /// Polling tick: drop the per-patient caches and re-issue the
  /// parallel detail fetch. Errors are swallowed so the next tick
  /// retries; the FutureBuilder keeps showing the prior bundle.
  Future<void> _onPollTick() async {
    try {
      await widget.data.refreshPatientDetail(widget.patientId);
    } catch (_) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _bundle = _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_PatientDetailBundle>(
      future: _bundle,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const _LoadingState();
        }
        if (snap.hasError) {
          return _ErrorState(
            message: snap.error.toString(),
            onRetry: () => setState(() => _bundle = _load()),
          );
        }
        final b = snap.data!;
        return _PatientView(
          data: widget.data,
          bundle: b,
          notifications: widget.notifications,
          showBackButton: widget.showBackButton,
          onBack: widget.onBack,
          onRefresh: () => setState(() => _bundle = _load()),
        );
      },
    );
  }
}

class _PatientDetailBundle {
  final Patient patient;
  final DeviceHealth device;
  final DailyActivity today;
  final List<DailyActivity> last7;
  final List<DailyActivity> last30;
  final List<WeeklyActivity> last6m;
  final List<PatientNotification> notifications;

  const _PatientDetailBundle({
    required this.patient,
    required this.device,
    required this.today,
    required this.last7,
    required this.last30,
    required this.last6m,
    required this.notifications,
  });
}

class _PatientView extends StatelessWidget {
  const _PatientView({
    required this.data,
    required this.bundle,
    required this.notifications,
    required this.showBackButton,
    required this.onBack,
    required this.onRefresh,
  });

  final FacilityRepository data;
  final _PatientDetailBundle bundle;
  final VoidCallback onRefresh;
  final NotificationState notifications;
  final bool showBackButton;
  final VoidCallback onBack;

  void _openDeviceScreen(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => DeviceScreen(device: bundle.device)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final patient = bundle.patient;
    final units = data.allUnits();
    final unitDisplay = units
        .firstWhere(
          (u) => u.id == patient.unitId,
          orElse: () => units.isNotEmpty
              ? units.first
              : throw StateError('no units in repository'),
        )
        .displayName;

    final active = notifications.activeOf(bundle.notifications);

    return LayoutBuilder(
      builder: (context, constraints) {
        final isPhone = constraints.maxWidth < 600;
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            isPhone ? 18 : 36,
            isPhone ? 56 : 28, // extra top room for the close X on phone
            isPhone ? 18 : 36,
            isPhone ? 28 : 48,
          ),
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
                compact: isPhone,
                onSettingsTap: () => ResidentSettingsDialog.show(
                  context,
                  patient: patient,
                  data: data,
                  onCompleted: onRefresh,
                ),
              ),
              const SizedBox(height: 20),
              // 2B-FAC-W: pause banner appears whenever notifications
              // are currently paused. Stacks above the care-note +
              // notification-review panels so caregivers see the
              // pause state before anything else.
              if (patient.notificationsPaused != null &&
                  patient.notificationsPaused!.isActive) ...[
                PauseBanner(
                  patientId: patient.id,
                  paused: patient.notificationsPaused!,
                  data: data,
                  onResumed: onRefresh,
                ),
                const SizedBox(height: 16),
              ],
              // 2B-FAC-W: care-note panel between header and
              // notifications. Always rendered (empty-state shows
              // "Tap to add" placeholder).
              CareNotePanel(
                patientId: patient.id,
                note: patient.careNote,
                data: data,
                onUpdated: onRefresh,
              ),
              const SizedBox(height: 20),
              if (active.isNotEmpty) ...[
                NotificationReviewPanel(
                  notifications: active,
                  state: notifications,
                  data: data,
                  onAcked: onRefresh,
                ),
                const SizedBox(height: 24),
              ],
              PatientDashboard(
                device: bundle.device,
                today: bundle.today,
                last7: bundle.last7,
                last30: bundle.last30,
                last6Months: bundle.last6m,
                onDeviceTap: () => _openDeviceScreen(context),
                // Per phase-2b-fac-r L4 + L8: hide gait chart + 6M tab in
                // live mode. Demo build keeps showing both.
                hideGait: BuildMode.current.isLive,
                hide6MonthTab: BuildMode.current.isLive,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _LoadingState extends StatelessWidget {
  const _LoadingState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(48),
        child: CircularProgressIndicator(color: AppTheme.sage),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.error_outline_rounded,
              size: 56,
              color: AppTheme.statusAlert,
            ),
            const SizedBox(height: 18),
            Text(
              'Could not load resident',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontSize: 20,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppTheme.textSoft,
                fontSize: 13,
                height: 1.55,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

class _PatientHeader extends StatelessWidget {
  const _PatientHeader({
    required this.name,
    required this.unit,
    required this.room,
    required this.onSettingsTap,
    this.compact = false,
  });

  final String name;
  final String unit;
  final String room;
  final VoidCallback onSettingsTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Text(
                name,
                style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                      fontSize: compact ? 24 : 30,
                      fontWeight: FontWeight.w500,
                    ),
              ),
            ),
            const SizedBox(width: 8),
            _SettingsGearButton(
              onTap: onSettingsTap,
              compact: compact,
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          room.isEmpty ? unit : '$unit  ·  Room $room',
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

class _SettingsGearButton extends StatefulWidget {
  const _SettingsGearButton({required this.onTap, this.compact = false});

  final VoidCallback onTap;
  final bool compact;

  @override
  State<_SettingsGearButton> createState() => _SettingsGearButtonState();
}

class _SettingsGearButtonState extends State<_SettingsGearButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final size = widget.compact ? 36.0 : 40.0;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Tooltip(
          message: 'Resident settings',
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: _hover
                  ? AppTheme.sage.withOpacity(0.10)
                  : AppTheme.sage.withOpacity(0.06),
              borderRadius: BorderRadius.circular(100),
              border: Border.all(
                color: AppTheme.sage.withOpacity(_hover ? 0.35 : 0.2),
                width: 1,
              ),
            ),
            child: Icon(
              Icons.settings_rounded,
              size: widget.compact ? 17 : 19,
              color: AppTheme.sage,
            ),
          ),
        ),
      ),
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
