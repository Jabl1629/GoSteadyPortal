import 'package:flutter/foundation.dart';

import '../models/notification.dart';

/// Session-only state for notification dismissals and caregiver notes.
/// Resets on page reload — matches the static-data philosophy of the demo
/// (every investor conversation starts from the same baseline).
class NotificationState extends ChangeNotifier {
  NotificationState() {
    _seedDemoNotes();
  }

  // dismissed[notification.key] == true if cleared by a caregiver this session
  final Set<String> _dismissed = {};

  // notes[notification.key] = list of notes, oldest first
  final Map<String, List<NotificationNote>> _notes = {};

  // ── Read ───────────────────────────────────────────────────────────────

  bool isDismissed(PatientNotification n) => _dismissed.contains(n.key);

  List<NotificationNote> notesFor(PatientNotification n) =>
      List.unmodifiable(_notes[n.key] ?? const []);

  /// Filters out dismissed notifications. Caller passes in the freshly
  /// computed list from NotificationEngine.
  List<PatientNotification> activeOf(List<PatientNotification> computed) =>
      computed.where((n) => !_dismissed.contains(n.key)).toList();

  // ── Mutate ─────────────────────────────────────────────────────────────

  void dismiss(PatientNotification n) {
    if (_dismissed.add(n.key)) notifyListeners();
  }

  void addNote(PatientNotification n, String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    _notes.putIfAbsent(n.key, () => []).add(
          NotificationNote(text: trimmed, addedAt: DateTime.now()),
        );
    notifyListeners();
  }

  // ── Seed data ──────────────────────────────────────────────────────────

  void _seedDemoNotes() {
    final now = DateTime.now();

    // James Martinez (pt_003) — No activity today (Critical).
    _notes['pt_003:noActivityToday'] = [
      NotificationNote(
        text:
            'Family confirmed clinic appointment this morning. Expected back by 2pm.',
        addedAt: now.subtract(const Duration(hours: 2, minutes: 18)),
      ),
    ];

    // Frank Kowalski (pt_006) — Declining trend (Warning).
    _notes['pt_006:decliningTrend'] = [
      NotificationNote(
        text:
            'Trending down since hospital discharge 3 weeks ago. OT scheduled Monday.',
        addedAt: now.subtract(const Duration(hours: 22, minutes: 5)),
      ),
    ];

    // Robert Chen (pt_002) — Below typical activity (Warning).
    _notes['pt_002:belowTypical'] = [
      NotificationNote(
        text: 'Slept poorly last night per night staff. Watching today.',
        addedAt: now.subtract(const Duration(hours: 4, minutes: 32)),
      ),
    ];
  }
}
