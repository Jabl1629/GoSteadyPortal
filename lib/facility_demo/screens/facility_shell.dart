import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../data/facility_mock_data.dart';
import '../state/facility_selection.dart';
import '../state/notification_state.dart';
import '../widgets/facility_top_bar.dart';
import 'patient_census_view.dart';
import 'patient_detail_view.dart';

/// Container for the facility demo. Top bar always visible; the Patient
/// Census fills the full content width below it. Selecting a patient
/// brings up a full-screen overlay (with a backdrop) containing the
/// patient detail; tap the backdrop or the back affordance to dismiss.
class FacilityShell extends StatefulWidget {
  const FacilityShell({super.key, required this.data});
  final FacilityMockData data;

  @override
  State<FacilityShell> createState() => _FacilityShellState();
}

class _FacilityShellState extends State<FacilityShell> {
  late final FacilitySelection _selection;
  late final NotificationState _notifications;

  @override
  void initState() {
    super.initState();
    _selection = FacilitySelection(widget.data);
    _notifications = NotificationState();
  }

  @override
  void dispose() {
    _selection.dispose();
    _notifications.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.warmWhite,
      body: SafeArea(
        child: Column(
          children: [
            FacilityTopBar(data: widget.data, selection: _selection),
            Expanded(
              child: Stack(
                children: [
                  // Census fills the full content area, always rendered.
                  PatientCensusView(
                    data: widget.data,
                    selection: _selection,
                    notifications: _notifications,
                  ),
                  // Patient overlay when one is selected.
                  ListenableBuilder(
                    listenable: _selection,
                    builder: (context, _) {
                      return AnimatedSwitcher(
                        duration: const Duration(milliseconds: 220),
                        switchInCurve: Curves.easeOutCubic,
                        switchOutCurve: Curves.easeInCubic,
                        transitionBuilder: (child, anim) {
                          return FadeTransition(
                            opacity: anim,
                            child: ScaleTransition(
                              scale: Tween(begin: 0.985, end: 1.0).animate(anim),
                              child: child,
                            ),
                          );
                        },
                        child: _selection.selectedPatientId == null
                            ? const SizedBox.shrink(key: ValueKey('empty'))
                            : _PatientOverlay(
                                key: ValueKey(_selection.selectedPatientId),
                                data: widget.data,
                                selection: _selection,
                                notifications: _notifications,
                              ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Backdrop + centered card that wraps PatientDetailView. Backdrop click
/// dismisses; the card itself swallows taps.
class _PatientOverlay extends StatelessWidget {
  const _PatientOverlay({
    super.key,
    required this.data,
    required this.selection,
    required this.notifications,
  });

  final FacilityMockData data;
  final FacilitySelection selection;
  final NotificationState notifications;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Below ~600 the overlay goes full-bleed (no backdrop padding, no
        // rounded card frame) — matches phone-modal expectations.
        final isPhone = constraints.maxWidth < 600;

        final card = Material(
          color: AppTheme.warmWhite,
          elevation: isPhone ? 0 : 16,
          shadowColor: Colors.black.withOpacity(0.25),
          borderRadius: isPhone
              ? BorderRadius.zero
              : BorderRadius.circular(22),
          clipBehavior: Clip.antiAlias,
          child: GestureDetector(
            // Absorb taps so the backdrop dismiss doesn't fire.
            onTap: () {},
            behavior: HitTestBehavior.opaque,
            child: Stack(
              children: [
                PatientDetailView(
                  data: data,
                  selection: selection,
                  notifications: notifications,
                ),
                // Close (X) button top-right of the card.
                Positioned(
                  top: 12,
                  right: 14,
                  child: _CloseButton(onTap: selection.clearPatient),
                ),
              ],
            ),
          ),
        );

        return Stack(
          children: [
            // Dim backdrop — tap dismisses. Lighter on phone since the
            // card itself fills the screen.
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: selection.clearPatient,
                child: Container(
                  color: Colors.black
                      .withOpacity(isPhone ? 0.0 : 0.35),
                ),
              ),
            ),
            if (isPhone)
              Positioned.fill(child: card)
            else
              Padding(
                padding: const EdgeInsets.fromLTRB(28, 24, 28, 28),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1180),
                    child: card,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _CloseButton extends StatefulWidget {
  const _CloseButton({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_CloseButton> createState() => _CloseButtonState();
}

class _CloseButtonState extends State<_CloseButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: _hover
                ? AppTheme.sage.withOpacity(0.12)
                : AppTheme.cream,
            shape: BoxShape.circle,
            border: Border.all(
              color: AppTheme.border.withOpacity(0.6),
              width: 1,
            ),
          ),
          child: Icon(
            Icons.close_rounded,
            size: 18,
            color: _hover ? AppTheme.sage : AppTheme.textSoft,
          ),
        ),
      ),
    );
  }
}
