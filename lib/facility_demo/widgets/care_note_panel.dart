import 'package:flutter/material.dart';

import '../../api/api_exception.dart';
import '../../api/api_models.dart' as api;
import '../../data/facility_repository.dart';
import '../../theme/app_theme.dart';

/// Care-note display + inline editor for the patient detail screen.
///
/// Renders [api.CareNote.text] in a soft cream-tinted block under
/// the patient header. Empty state shows a "Tap to add a care note"
/// placeholder. The edit pencil opens a dialog with a 280-char
/// textarea + counter (per user-needs US-44 + 2A-UM-P L8).
///
/// On save: calls `data.updateCareNote(...)`; on success calls
/// [onUpdated] so Patient Detail can refresh and re-render with
/// new text + attribution. Per phase-2b-fac-w-facility-writes.md L7.
class CareNotePanel extends StatelessWidget {
  const CareNotePanel({
    super.key,
    required this.patientId,
    required this.note,
    required this.data,
    required this.onUpdated,
  });

  final String patientId;
  final api.CareNote? note;
  final FacilityRepository data;
  final VoidCallback onUpdated;

  @override
  Widget build(BuildContext context) {
    final hasNote = note != null && note!.text.trim().isNotEmpty;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppTheme.cream,
        borderRadius: BorderRadius.circular(AppTheme.cardRadius),
        border: Border.all(color: AppTheme.border.withOpacity(0.5)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 16, 16, 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.sticky_note_2_outlined,
            size: 18,
            color: AppTheme.textSoft,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text(
                      'CARE NOTE',
                      style: TextStyle(
                        color: AppTheme.textDark,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.6,
                      ),
                    ),
                    const Spacer(),
                    if (hasNote && note!.updatedByName != null) ...[
                      Text(
                        'Updated by ${note!.updatedByName} · ${_relTime(note!.updatedAt)}',
                        style: const TextStyle(
                          color: AppTheme.textSoft,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 6),
                if (hasNote)
                  Text(
                    note!.text,
                    style: const TextStyle(
                      color: AppTheme.textDark,
                      fontSize: 14,
                      height: 1.45,
                    ),
                  )
                else
                  Text(
                    'Tap edit to add a care note.',
                    style: TextStyle(
                      color: AppTheme.textSoft.withOpacity(0.85),
                      fontSize: 13,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: hasNote ? 'Edit care note' : 'Add care note',
            icon: Icon(
              hasNote ? Icons.edit_outlined : Icons.add_rounded,
              size: 20,
              color: AppTheme.textSoft,
            ),
            onPressed: () => _CareNoteEditDialog.show(
              context,
              patientId: patientId,
              existing: note?.text ?? '',
              data: data,
              onUpdated: onUpdated,
            ),
          ),
        ],
      ),
    );
  }

  static String _relTime(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    if (d.inDays == 1) return 'yesterday';
    return '${d.inDays}d ago';
  }
}

class _CareNoteEditDialog extends StatefulWidget {
  const _CareNoteEditDialog({
    required this.patientId,
    required this.existing,
    required this.data,
    required this.onUpdated,
  });

  final String patientId;
  final String existing;
  final FacilityRepository data;
  final VoidCallback onUpdated;

  static Future<void> show(
    BuildContext context, {
    required String patientId,
    required String existing,
    required FacilityRepository data,
    required VoidCallback onUpdated,
  }) =>
      showDialog<void>(
        context: context,
        barrierColor: Colors.black.withOpacity(0.45),
        builder: (_) => _CareNoteEditDialog(
          patientId: patientId,
          existing: existing,
          data: data,
          onUpdated: onUpdated,
        ),
      );

  @override
  State<_CareNoteEditDialog> createState() => _CareNoteEditDialogState();
}

class _CareNoteEditDialogState extends State<_CareNoteEditDialog> {
  late final TextEditingController _ctrl;
  bool _submitting = false;
  String? _errorMessage;

  static const int _maxLen = 280;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.existing);
    _ctrl.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _save(String text) async {
    setState(() {
      _submitting = true;
      _errorMessage = null;
    });
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      await widget.data.updateCareNote(
        patientId: widget.patientId,
        text: text,
      );
      widget.onUpdated();
      if (!mounted) return;
      navigator.pop();
      messenger.showSnackBar(
        SnackBar(
          content: Text(text.isEmpty ? 'Care note cleared.' : 'Care note saved.'),
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppTheme.sage,
          duration: const Duration(seconds: 3),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage =
            e is ApiException ? '${e.code}: ${e.message}' : 'Save failed: $e';
        _submitting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = _ctrl.text;
    final remaining = _maxLen - text.length;
    final overLimit = remaining < 0;

    return Dialog(
      backgroundColor: AppTheme.warmWhite,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.sticky_note_2_outlined,
                      size: 18, color: AppTheme.textSoft),
                  const SizedBox(width: 10),
                  const Text(
                    'Care Note',
                    style: TextStyle(
                      color: AppTheme.textDark,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, size: 20),
                    color: AppTheme.textSoft,
                    onPressed:
                        _submitting ? null : () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _ctrl,
                maxLines: 5,
                minLines: 3,
                maxLength: _maxLen,
                autofocus: true,
                style: const TextStyle(
                  color: AppTheme.textDark,
                  fontSize: 14,
                  height: 1.45,
                ),
                decoration: InputDecoration(
                  hintText: 'e.g. Watch for unsteadiness after dinner — '
                      'family visiting Sat.',
                  hintStyle: TextStyle(
                    color: AppTheme.textSoft.withOpacity(0.7),
                    fontSize: 13,
                  ),
                  counterText: '$remaining',
                  counterStyle: TextStyle(
                    color: overLimit ? AppTheme.statusAlert : AppTheme.textSoft,
                    fontSize: 12,
                  ),
                  filled: true,
                  fillColor: Colors.white,
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
              ),
              if (_errorMessage != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
                          _errorMessage!,
                          style: TextStyle(
                            color: AppTheme.statusAlert,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (widget.existing.isNotEmpty)
                    TextButton(
                      onPressed: _submitting ? null : () => _save(''),
                      style: TextButton.styleFrom(
                        foregroundColor: AppTheme.statusAlert,
                      ),
                      child: const Text('Clear note'),
                    ),
                  const Spacer(),
                  TextButton(
                    onPressed: _submitting
                        ? null
                        : () => Navigator.of(context).pop(),
                    style: TextButton.styleFrom(
                      foregroundColor: AppTheme.textSoft,
                    ),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: (_submitting || overLimit)
                        ? null
                        : () => _save(text.trim()),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.sage,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(100),
                      ),
                    ),
                    child: _submitting
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor:
                                  AlwaysStoppedAnimation<Color>(Colors.white),
                            ),
                          )
                        : const Text('Save'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
