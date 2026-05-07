import 'package:flutter/material.dart';

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
  });

  /// Active (i.e. not-yet-dismissed) notifications for the patient.
  final List<PatientNotification> notifications;
  final NotificationState state;

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
            _NotificationCard(notification: n, state: state),
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
  const _NotificationCard({required this.notification, required this.state});
  final PatientNotification notification;
  final NotificationState state;

  @override
  State<_NotificationCard> createState() => _NotificationCardState();
}

class _NotificationCardState extends State<_NotificationCard> {
  late final TextEditingController _noteCtrl;
  bool _hasText = false;

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

  void _submitNote() {
    final text = _noteCtrl.text.trim();
    if (text.isEmpty) return;
    widget.state.addNote(widget.notification, text);
    _noteCtrl.clear();
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
              _DismissButton(
                onTap: () => widget.state.dismiss(n),
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
            canSubmit: _hasText,
            onSubmit: _submitNote,
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
    required this.onSubmit,
  });

  final TextEditingController controller;
  final bool canSubmit;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            onSubmitted: (_) => onSubmit(),
            textInputAction: TextInputAction.send,
            style: const TextStyle(fontSize: 13, color: AppTheme.textDark),
            decoration: InputDecoration(
              hintText: 'Add a note…',
              hintStyle: TextStyle(
                color: AppTheme.textSoft.withOpacity(0.7),
                fontSize: 13,
              ),
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              filled: true,
              fillColor: AppTheme.warmWhite,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide:
                    BorderSide(color: AppTheme.border.withOpacity(0.7)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide:
                    BorderSide(color: AppTheme.border.withOpacity(0.7)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide:
                    BorderSide(color: AppTheme.sage, width: 1.5),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        _SendButton(enabled: canSubmit, onTap: onSubmit),
      ],
    );
  }
}

class _SendButton extends StatelessWidget {
  const _SendButton({required this.enabled, required this.onTap});
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor:
          enabled ? SystemMouseCursors.click : SystemMouseCursors.forbidden,
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        child: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: enabled ? AppTheme.sage : AppTheme.border.withOpacity(0.5),
            shape: BoxShape.circle,
          ),
          child: Icon(
            Icons.arrow_upward_rounded,
            size: 18,
            color: enabled ? Colors.white : AppTheme.textSoft,
          ),
        ),
      ),
    );
  }
}

class _DismissButton extends StatefulWidget {
  const _DismissButton({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_DismissButton> createState() => _DismissButtonState();
}

class _DismissButtonState extends State<_DismissButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Tooltip(
          message: 'Dismiss notification',
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: _hover
                  ? AppTheme.sage.withOpacity(0.1)
                  : Colors.transparent,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.close_rounded,
              size: 16,
              color: _hover ? AppTheme.sage : AppTheme.textSoft,
            ),
          ),
        ),
      ),
    );
  }
}
