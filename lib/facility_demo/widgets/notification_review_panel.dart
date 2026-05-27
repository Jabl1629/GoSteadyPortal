import 'package:flutter/material.dart';

import '../../api/api_exception.dart';
import '../../data/facility_repository.dart';
import '../../theme/app_theme.dart';
import '../models/notification.dart';
import '../state/notification_state.dart';

/// "Notification Review" section displayed at the top of the patient
/// detail overlay. Hidden when the patient has no active notifications.
/// Each active notification gets its own subcard with detail, existing
/// notes, an inline "add note" field, and a dismiss button.
class NotificationReviewPanel extends StatelessWidget {
  const NotificationReviewPanel({
    super.key,
    required this.notifications,
    required this.state,
    required this.data,
    this.onAcked,
  });

  /// Active (i.e. not-yet-dismissed) notifications for the patient.
  final List<PatientNotification> notifications;
  final NotificationState state;

  /// Repository used to call `PATCH /alerts/{patientId}/{sk}` per
  /// phase-2b-fac-w L2. Demo path is a no-op; live path triggers the
  /// manual-ack-release flow from coord §C33 L5.
  final FacilityRepository data;

  /// Optional callback after a successful ack. Patient Detail uses
  /// this to refresh the bundle so the acked row disappears from the
  /// list immediately (rather than waiting for the next polling tick).
  final VoidCallback? onAcked;

  @override
  Widget build(BuildContext context) {
    if (notifications.isEmpty) return const SizedBox.shrink();

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFFDF8EE), // a touch warmer than cream
        borderRadius: BorderRadius.circular(AppTheme.cardRadius),
        border: Border.all(color: AppTheme.statusWarn.withOpacity(0.25)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.notification_important_rounded,
                size: 18,
                color: AppTheme.statusWarn,
              ),
              const SizedBox(width: 8),
              Text(
                _headerLabel(notifications.length),
                style: const TextStyle(
                  color: AppTheme.textDark,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          for (final n in notifications)
            _NotificationCard(
              notification: n,
              state: state,
              data: data,
              onAcked: onAcked,
            ),
        ],
      ),
    );
  }

  static String _headerLabel(int count) {
    if (count == 1) return 'NOTIFICATIONS · 1 AWAITING REVIEW';
    return 'NOTIFICATIONS · $count AWAITING REVIEW';
  }
}

class _NotificationCard extends StatefulWidget {
  const _NotificationCard({
    required this.notification,
    required this.state,
    required this.data,
    this.onAcked,
  });
  final PatientNotification notification;
  final NotificationState state;
  final FacilityRepository data;
  final VoidCallback? onAcked;

  @override
  State<_NotificationCard> createState() => _NotificationCardState();
}

class _NotificationCardState extends State<_NotificationCard> {
  late final TextEditingController _noteCtrl;
  bool _hasText = false;
  bool _submitting = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _noteCtrl = TextEditingController();
    _noteCtrl.addListener(() {
      final has = _noteCtrl.text.trim().isNotEmpty;
      if (has != _hasText) setState(() => _hasText = has);
    });
  }

  @override
  void dispose() {
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _submitNote() async {
    final text = _noteCtrl.text.trim();
    if (text.isEmpty) return;
    final n = widget.notification;
    setState(() {
      _submitting = true;
      _errorMessage = null;
    });
    try {
      // Phase 2B-FAC-W L2 — repository owns the write path. In live
      // mode this hits PATCH /alerts/{patientId}/{sk} and (per coord
      // §C33 L5) the server-side ack handler releases the
      // openAlerts.<alertType> slot on the Patient row. Demo impl is
      // a no-op returning a synthesized response.
      if (n.sk != null) {
        await widget.data.ackAlert(
          patientId: n.patientId,
          sk: n.sk!,
          notes: text,
        );
      }
      if (!mounted) return;
      // Persist the note locally (kept for demo continuity) + dismiss.
      // Parent then refreshes the bundle so the row disappears.
      widget.state.addNote(n, text);
      widget.state.dismiss(n);
      _noteCtrl.clear();
      widget.onAcked?.call();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e is ApiException
            ? '${e.code}: ${e.message}'
            : 'Could not save: $e';
      });
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.notification;
    final notes = widget.state.notesFor(n);
    final isCritical = n.severity == NotificationSeverity.critical;
    final accent = isCritical ? AppTheme.statusAlert : AppTheme.statusWarn;

    return Container(
      margin: const EdgeInsets.only(top: 12, bottom: 4),
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border.withOpacity(0.7)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                margin: const EdgeInsets.only(top: 4),
                width: 8,
                height: 8,
                decoration:
                    BoxDecoration(color: accent, shape: BoxShape.circle),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      n.type.label,
                      style: const TextStyle(
                        color: AppTheme.textDark,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      n.detail,
                      style: const TextStyle(
                        color: AppTheme.textSoft,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (notes.isNotEmpty) ...[
            const SizedBox(height: 12),
            for (final note in notes)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: _NoteBubble(note: note),
              ),
          ],
          const SizedBox(height: 8),
          _NoteInput(
            controller: _noteCtrl,
            canSubmit: _hasText && !_submitting,
            submitting: _submitting,
            onSubmit: _submitNote,
          ),
          if (_errorMessage != null) ...[
            const SizedBox(height: 8),
            _ErrorBanner(message: _errorMessage!),
          ],
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: AppTheme.statusAlert.withOpacity(0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.statusAlert.withOpacity(0.35)),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded,
              size: 16, color: AppTheme.statusAlert),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: AppTheme.statusAlert,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NoteBubble extends StatelessWidget {
  const _NoteBubble({required this.note});
  final NotificationNote note;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: AppTheme.cream,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.border.withOpacity(0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            note.text,
            style: const TextStyle(
              color: AppTheme.textDark,
              fontSize: 13,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _formatRelative(note.addedAt),
            style: const TextStyle(
              color: AppTheme.textSoft,
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  static String _formatRelative(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    if (d.inDays == 1) return 'yesterday';
    return '${d.inDays} days ago';
  }
}

class _NoteInput extends StatelessWidget {
  const _NoteInput({
    required this.controller,
    required this.canSubmit,
    required this.submitting,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final bool canSubmit;
  final bool submitting;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // The Acknowledge button is ~210px wide; under ~520 we stack
        // it below the input rather than alongside.
        final stack = constraints.maxWidth < 520;
        final input = TextField(
          controller: controller,
          onSubmitted: (_) => onSubmit(),
          textInputAction: TextInputAction.send,
          style: const TextStyle(fontSize: 13, color: AppTheme.textDark),
          decoration: InputDecoration(
            hintText: 'Add a note before acknowledging…',
            hintStyle: TextStyle(
              color: AppTheme.textSoft.withOpacity(0.7),
              fontSize: 13,
            ),
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            filled: true,
            fillColor: AppTheme.warmWhite,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: AppTheme.border.withOpacity(0.7)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: AppTheme.border.withOpacity(0.7)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: AppTheme.sage, width: 1.5),
            ),
          ),
        );
        final button = _AcknowledgeButton(
          enabled: canSubmit,
          submitting: submitting,
          onTap: onSubmit,
        );

        if (stack) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              input,
              const SizedBox(height: 10),
              button,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(child: input),
            const SizedBox(width: 10),
            button,
          ],
        );
      },
    );
  }
}

class _AcknowledgeButton extends StatefulWidget {
  const _AcknowledgeButton({
    required this.enabled,
    required this.submitting,
    required this.onTap,
  });
  final bool enabled;
  final bool submitting;
  final VoidCallback onTap;

  @override
  State<_AcknowledgeButton> createState() => _AcknowledgeButtonState();
}

class _AcknowledgeButtonState extends State<_AcknowledgeButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled;
    final bg = enabled
        ? (_hover ? AppTheme.sageDark : AppTheme.sage)
        : AppTheme.border.withOpacity(0.5);
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.forbidden,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: enabled ? widget.onTap : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.submitting)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                )
              else
                Icon(
                  Icons.check_rounded,
                  size: 16,
                  color: enabled ? Colors.white : AppTheme.textSoft,
                ),
              const SizedBox(width: 6),
              Text(
                widget.submitting ? 'Acknowledging…' : 'Acknowledge + Save Note',
                style: TextStyle(
                  color: enabled || widget.submitting
                      ? Colors.white
                      : AppTheme.textSoft,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.1,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
