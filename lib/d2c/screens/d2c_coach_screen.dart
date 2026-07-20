import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../theme/app_theme.dart';
import '../d2c_routes.dart';
import '../data/d2c_mock_data.dart';
import '../widgets/d2c_bottom_nav.dart';

/// Presentational screens for the Coach ("Steady") tab
/// (ai-coach-c1-text-chat.md §5.7). These are dumb views: the hosts in
/// `lib/d2c/live/d2c_live_screens.dart` own the repository, the loaded
/// data, and the async state, and pass it down here as plain data +
/// callbacks — mirroring how `D2CDashboardScreen` takes a snapshot +
/// `onAckAlert`. Navigation between the tab and its memory sub-route uses
/// `context.go` directly (same as the dashboard's "See more").
///
/// Accessibility (C1-D6 / §5.7.1): chat body is 16px `textDark` on white,
/// not the 15px app body and not `textSoft`; every tap target clears 44px.
/// Persona is openly AI — a per-message "AI" glyph + the persistent
/// disclosure footer name Steady as an AI activity coach on every screen.

// ════════════════════════════════════════════════════════════════════
// (a) Main Coach screen — empty daily-note card + chat thread + composer
// ════════════════════════════════════════════════════════════════════

class D2CCoachScreen extends StatefulWidget {
  const D2CCoachScreen({
    super.key,
    required this.messages,
    required this.sending,
    required this.onSend,
    required this.onUpdatePrefs,
    this.note,
    this.prefs,
  });

  /// The transcript, oldest-first. Owned by the host; this view renders it.
  final List<CoachMessage> messages;

  /// True while a reply is awaited — drives the typing indicator (replies
  /// are non-streamed, so the wait is shown, not hidden; §5.7 / L5).
  final bool sending;

  /// Send one message. The host appends the user turn optimistically and
  /// the coach reply on return; this view just clears the composer.
  final ValueChanged<String> onSend;

  /// Today's proactive note (C2) for the "morning note" card. Null → the C1
  /// "coming soon" placeholder.
  final CoachNote? note;

  /// Coach preferences (C3) backing the settings sheet; null while loading
  /// (the settings action stays disabled until it resolves).
  final CoachPrefs? prefs;

  /// Persist a tone / SMS-opt-in change; resolves to the new authoritative
  /// preferences (the settings sheet reconciles its optimistic state from it).
  final Future<CoachPrefs> Function({String? tone, bool? smsTeaser})
      onUpdatePrefs;

  @override
  State<D2CCoachScreen> createState() => _D2CCoachScreenState();
}

class _D2CCoachScreenState extends State<D2CCoachScreen> {
  final _composer = TextEditingController();
  final _scroll = ScrollController();
  bool _canSend = false;

  @override
  void initState() {
    super.initState();
    _composer.addListener(_onComposerChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToEnd());
  }

  @override
  void didUpdateWidget(covariant D2CCoachScreen old) {
    super.didUpdateWidget(old);
    // New turn or the typing indicator appeared → keep the latest in view.
    if (widget.messages.length != old.messages.length ||
        widget.sending != old.sending) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToEnd());
    }
  }

  @override
  void dispose() {
    _composer.removeListener(_onComposerChanged);
    _composer.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onComposerChanged() {
    final canSend = _composer.text.trim().isNotEmpty;
    if (canSend != _canSend) setState(() => _canSend = canSend);
  }

  void _scrollToEnd() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      _scroll.position.maxScrollExtent,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOut,
    );
  }

  void _submit() {
    final text = _composer.text.trim();
    if (text.isEmpty || widget.sending) return;
    widget.onSend(text);
    _composer.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.warmWhite,
      appBar: _buildAppBar(context),
      bottomNavigationBar: const D2CBottomNav(active: D2CTab.coach),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: ListView(
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                children: [
                  _DailyNoteCard(note: widget.note),
                  const SizedBox(height: 18),
                  if (widget.messages.isEmpty && !widget.sending)
                    const _EmptyThreadHint()
                  else
                    for (final m in widget.messages) ...[
                      _MessageRow(message: m),
                      const SizedBox(height: 14),
                    ],
                  if (widget.sending) const _TypingIndicator(),
                ],
              ),
            ),
            const _DisclosureFooter(),
            _Composer(
              controller: _composer,
              canSend: _canSend && !widget.sending,
              onSubmit: _submit,
            ),
          ],
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    return AppBar(
      backgroundColor: AppTheme.warmWhite,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      automaticallyImplyLeading: false,
      titleSpacing: 16,
      title: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: AppTheme.sage.withOpacity(0.14),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.auto_awesome, size: 18, color: AppTheme.sage),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Steady',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textDark,
                    ),
              ),
              const Text(
                'Your AI activity coach',
                style: TextStyle(
                  color: AppTheme.textSoft,
                  fontSize: 12,
                  height: 1.1,
                ),
              ),
            ],
          ),
        ],
      ),
      actions: [
        IconButton(
          tooltip: 'Coach settings',
          // Disabled only until prefs resolve; the host seeds a warm default
          // so this is effectively always available.
          onPressed: widget.prefs == null ? null : _openSettings,
          icon: const Icon(Icons.tune_rounded, color: AppTheme.textSoft),
        ),
        IconButton(
          tooltip: 'What Steady knows about you',
          onPressed: () => context.go(D2CRoutes.coachMemory),
          icon: const Icon(Icons.menu_book_outlined, color: AppTheme.textSoft),
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  void _openSettings() {
    final prefs = widget.prefs;
    if (prefs == null) return;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.warmWhite,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _CoachSettingsSheet(
        initialPrefs: prefs,
        onUpdate: widget.onUpdatePrefs,
      ),
    );
  }
}

/// The daily-note card. When C2's proactive inbox has a note for today it
/// renders the real, warm note (title + "AI" glyph + body); otherwise it
/// falls back to the C1 "coming soon" placeholder and makes no claim (§5.7 /
/// §5.8). Body copy is 16px `textDark` (chat-body size, AA on white) — never
/// `textSoft` for the note itself (§5.7.1).
class _DailyNoteCard extends StatelessWidget {
  const _DailyNoteCard({this.note});

  final CoachNote? note;

  @override
  Widget build(BuildContext context) {
    final note = this.note;
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppTheme.cardRadius),
        boxShadow: AppTheme.cardShadow,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: AppTheme.sage.withOpacity(0.10),
              borderRadius: BorderRadius.circular(11),
            ),
            child: const Icon(Icons.wb_sunny_outlined,
                size: 20, color: AppTheme.sage),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: note == null ? const _NotePlaceholder() : _NoteBody(note: note),
          ),
        ],
      ),
    );
  }
}

/// The C1 "coming soon" state — shown until C2's engine writes a note.
class _NotePlaceholder extends StatelessWidget {
  const _NotePlaceholder();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Your morning note',
          style: TextStyle(
            color: AppTheme.textDark,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
        SizedBox(height: 4),
        Text(
          'Soon, Steady will leave you a short note here each morning. '
          'For now, say hello below whenever you like.',
          style: TextStyle(
            color: AppTheme.textSoft,
            fontSize: 13.5,
            height: 1.4,
          ),
        ),
      ],
    );
  }
}

/// A real proactive note (C2). Openly AI — the "AI" glyph sits by the title,
/// matching the per-message marker on coach turns (§6.0 / §5.8).
class _NoteBody extends StatelessWidget {
  const _NoteBody({required this.note});

  final CoachNote note;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            Text(
              'Your morning note',
              style: TextStyle(
                color: AppTheme.textDark,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(width: 8),
            _AiChip(),
          ],
        ),
        const SizedBox(height: 7),
        Text(
          note.text,
          style: const TextStyle(
            color: AppTheme.textDark,
            fontSize: 16,
            height: 1.5,
          ),
        ),
      ],
    );
  }
}

class _EmptyThreadHint extends StatelessWidget {
  const _EmptyThreadHint();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 40, horizontal: 24),
      child: Text(
        'Say hello to Steady to get started.',
        textAlign: TextAlign.center,
        style: TextStyle(
          color: AppTheme.textSoft,
          fontSize: 14,
          height: 1.4,
        ),
      ),
    );
  }
}

/// One transcript row. Coach turns are left-aligned with the AI glyph +
/// name header; user turns are right-aligned sage bubbles.
class _MessageRow extends StatelessWidget {
  const _MessageRow({required this.message});

  final CoachMessage message;

  @override
  Widget build(BuildContext context) {
    final time = DateFormat.jm().format(message.createdAt.toLocal());
    if (message.isCoach) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: AppTheme.sage.withOpacity(0.14),
              shape: BoxShape.circle,
            ),
            child:
                const Icon(Icons.auto_awesome, size: 15, color: AppTheme.sage),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text(
                      'Steady',
                      style: TextStyle(
                        color: AppTheme.textSoft,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 6),
                    const _AiChip(),
                    const SizedBox(width: 8),
                    Text(
                      time,
                      style: const TextStyle(
                        color: AppTheme.textSoft,
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                Container(
                  padding: const EdgeInsets.fromLTRB(14, 11, 14, 12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(4),
                      topRight: Radius.circular(16),
                      bottomLeft: Radius.circular(16),
                      bottomRight: Radius.circular(16),
                    ),
                    boxShadow: AppTheme.cardShadow,
                  ),
                  child: Text(
                    message.text,
                    style: const TextStyle(
                      color: AppTheme.textDark,
                      fontSize: 16,
                      height: 1.45,
                    ),
                  ),
                ),
                if (message.flagged) ...[
                  const SizedBox(height: 5),
                  const Row(
                    children: [
                      // Neutral, muted marker — textSoft clears AA on warmWhite
                      // (statusWarn amber would be ~2.7:1). Never shown in the
                      // C1 mock; honours the model's triage flag if the live
                      // backend sets it.
                      Icon(Icons.flag_outlined,
                          size: 13, color: AppTheme.textSoft),
                      SizedBox(width: 4),
                      Text(
                        'Flagged for review',
                        style: TextStyle(
                          color: AppTheme.textSoft,
                          fontSize: 11.5,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 36),
        ],
      );
    }
    // User turn — right-aligned sage bubble.
    return Row(
      children: [
        const SizedBox(width: 44),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Container(
                padding: const EdgeInsets.fromLTRB(14, 11, 14, 12),
                decoration: const BoxDecoration(
                  color: AppTheme.sage,
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(16),
                    topRight: Radius.circular(4),
                    bottomLeft: Radius.circular(16),
                    bottomRight: Radius.circular(16),
                  ),
                ),
                child: Text(
                  message.text,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    height: 1.45,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Text(
                  time,
                  style: const TextStyle(
                    color: AppTheme.textSoft,
                    fontSize: 11.5,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The openly-AI marker on coach turns (safety posture — §6.0).
class _AiChip extends StatelessWidget {
  const _AiChip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppTheme.sage,
        borderRadius: BorderRadius.circular(100),
      ),
      child: const Text(
        'AI',
        style: TextStyle(
          color: Colors.white,
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

/// Three-dot "Steady is typing…" indicator for the non-streamed wait.
class _TypingIndicator extends StatefulWidget {
  const _TypingIndicator();

  @override
  State<_TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<_TypingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: AppTheme.sage.withOpacity(0.14),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.auto_awesome, size: 15, color: AppTheme.sage),
        ),
        const SizedBox(width: 10),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Steady is typing…',
              style: TextStyle(
                color: AppTheme.textSoft,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(4),
                  topRight: Radius.circular(16),
                  bottomLeft: Radius.circular(16),
                  bottomRight: Radius.circular(16),
                ),
                boxShadow: AppTheme.cardShadow,
              ),
              child: AnimatedBuilder(
                animation: _c,
                builder: (context, _) {
                  return Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var i = 0; i < 3; i++) ...[
                        if (i > 0) const SizedBox(width: 5),
                        _dot(i),
                      ],
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _dot(int i) {
    // Each dot leads the next by a third of the cycle, giving a wave.
    final phase = (_c.value - i * 0.2) % 1.0;
    final t = (phase < 0.5) ? phase * 2 : (1 - phase) * 2; // 0→1→0 triangle
    final opacity = 0.3 + 0.7 * t.clamp(0.0, 1.0);
    return Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(
        color: AppTheme.sage.withOpacity(opacity),
        shape: BoxShape.circle,
      ),
    );
  }
}

/// The persistent disclosure required on every coach screen (§5.7 / §6.5).
class _DisclosureFooter extends StatelessWidget {
  const _DisclosureFooter();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      decoration: BoxDecoration(
        color: AppTheme.warmWhite,
        border: Border(top: BorderSide(color: AppTheme.border.withOpacity(0.6))),
      ),
      child: const Text(
        'Steady is your AI activity coach — not a medical professional. '
        'In an emergency, call 911.',
        textAlign: TextAlign.center,
        style: TextStyle(
          color: AppTheme.textDark,
          fontSize: 12.5,
          height: 1.35,
        ),
      ),
    );
  }
}

/// The message composer: an expanding text field + a send button.
class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.canSend,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final bool canSend;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 12),
      color: AppTheme.warmWhite,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              minLines: 1,
              maxLines: 5,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => onSubmit(),
              textCapitalization: TextCapitalization.sentences,
              style: const TextStyle(fontSize: 16, color: AppTheme.textDark),
              decoration: InputDecoration(
                hintText: 'Message Steady',
                hintStyle: TextStyle(
                  // Full-opacity textSoft = 5.7:1 on white; @80% was 3.7:1 (§5.7.1).
                  color: AppTheme.textSoft,
                  fontSize: 15,
                ),
                isDense: true,
                filled: true,
                fillColor: Colors.white,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(22),
                  borderSide: const BorderSide(color: AppTheme.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(22),
                  borderSide: const BorderSide(color: AppTheme.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(22),
                  borderSide: const BorderSide(color: AppTheme.sage, width: 1.5),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          // 48×48 tap target (≥44); sage when actionable, muted when not.
          Material(
            color: canSend ? AppTheme.sage : AppTheme.border,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: canSend ? onSubmit : null,
              child: SizedBox(
                width: 48,
                height: 48,
                child: Icon(
                  Icons.arrow_upward_rounded,
                  color: canSend ? Colors.white : AppTheme.textSoft,
                  size: 22,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
// (b) "What Steady knows about you" — editable memory (§5.2 / L4)
// ════════════════════════════════════════════════════════════════════

class D2CCoachMemoryScreen extends StatefulWidget {
  const D2CCoachMemoryScreen({
    super.key,
    required this.memory,
    required this.onAddFact,
    required this.onAddGoal,
    required this.onEditFact,
    required this.onDeleteFact,
  });

  final CoachMemory memory;
  final ValueChanged<String> onAddFact;

  /// Add a goal (C3) — a `kind:goal` memory item. Edit/delete reuse
  /// [onEditFact]/[onDeleteFact], which target any item by id.
  final ValueChanged<String> onAddGoal;
  final void Function(CoachMemoryFact fact, String text) onEditFact;
  final ValueChanged<CoachMemoryFact> onDeleteFact;

  @override
  State<D2CCoachMemoryScreen> createState() => _D2CCoachMemoryScreenState();
}

class _D2CCoachMemoryScreenState extends State<D2CCoachMemoryScreen> {
  final _add = TextEditingController();
  final _addGoal = TextEditingController();
  bool _canAdd = false;
  bool _canAddGoal = false;

  @override
  void initState() {
    super.initState();
    _add.addListener(() {
      final canAdd = _add.text.trim().isNotEmpty;
      if (canAdd != _canAdd) setState(() => _canAdd = canAdd);
    });
    _addGoal.addListener(() {
      final canAdd = _addGoal.text.trim().isNotEmpty;
      if (canAdd != _canAddGoal) setState(() => _canAddGoal = canAdd);
    });
  }

  @override
  void dispose() {
    _add.dispose();
    _addGoal.dispose();
    super.dispose();
  }

  void _submitAdd() {
    final text = _add.text.trim();
    if (text.isEmpty) return;
    widget.onAddFact(text);
    _add.clear();
  }

  void _submitGoal() {
    final text = _addGoal.text.trim();
    if (text.isEmpty) return;
    widget.onAddGoal(text);
    _addGoal.clear();
  }

  Future<void> _editFact(CoachMemoryFact fact) async {
    final controller = TextEditingController(text: fact.text);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.warmWhite,
        title: const Text('Edit this'),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: 1,
          maxLines: 4,
          textCapitalization: TextCapitalization.sentences,
          style: const TextStyle(fontSize: 16, color: AppTheme.textDark),
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.sage),
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result != null && result.isNotEmpty && result != fact.text) {
      widget.onEditFact(fact, result);
    }
  }

  Future<void> _deleteFact(CoachMemoryFact fact) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.warmWhite,
        title: const Text('Delete this?'),
        content: const Text(
          'Steady will forget this. You can always tell it again later.',
          style: TextStyle(color: AppTheme.textDark, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.statusAlert),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) widget.onDeleteFact(fact);
  }

  @override
  Widget build(BuildContext context) {
    final memory = widget.memory;
    // Split the flat fact list into the two user-facing lanes. Goals lead —
    // they're the motivational anchor Steady works toward (C3 §5.6).
    final goals = [
      for (final f in memory.facts)
        if (f.kind == CoachFactKind.goal) f
    ];
    final details = [
      for (final f in memory.facts)
        if (f.kind != CoachFactKind.goal) f
    ];
    return Scaffold(
      backgroundColor: AppTheme.warmWhite,
      appBar: AppBar(
        backgroundColor: AppTheme.warmWhite,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: AppTheme.textDark),
          onPressed: () => context.go(D2CRoutes.coach),
        ),
        title: Text(
          'What Steady knows',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontSize: 19,
                fontWeight: FontWeight.w600,
                color: AppTheme.textDark,
              ),
        ),
      ),
      bottomNavigationBar: const D2CBottomNav(active: D2CTab.coach),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
            children: [
              const Text(
                'These are the things Steady remembers to make your chats more '
                'helpful. You can edit or delete anything, any time.',
                style: TextStyle(
                  color: AppTheme.textSoft,
                  fontSize: 14,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 20),
              if (memory.summary.trim().isNotEmpty) ...[
                _SummaryCard(summary: memory.summary),
                const SizedBox(height: 22),
              ],
              // ── Goals (C3) ──────────────────────────────────────────
              const _MemorySectionLabel('Goals'),
              const SizedBox(height: 10),
              if (goals.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Text(
                    'No goals yet. Add one below to give Steady something to '
                    'cheer you toward.',
                    style: TextStyle(
                      color: AppTheme.textSoft,
                      fontSize: 14,
                      height: 1.4,
                    ),
                  ),
                )
              else
                for (final f in goals)
                  _FactCard(
                    fact: f,
                    onEdit: () => _editFact(f),
                    onDelete: () => _deleteFact(f),
                  ),
              const SizedBox(height: 16),
              _AddFactField(
                controller: _addGoal,
                canAdd: _canAddGoal,
                onAdd: _submitGoal,
                label: 'Add a goal',
                hint: 'e.g. Walk to the mailbox and back daily',
              ),
              const SizedBox(height: 30),
              // ── Details (profile facts) ─────────────────────────────
              const _MemorySectionLabel('Details'),
              const SizedBox(height: 10),
              if (details.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Text(
                    "Nothing yet. Add something you'd like Steady to keep in "
                    'mind below.',
                    style: TextStyle(
                      color: AppTheme.textSoft,
                      fontSize: 14,
                      height: 1.4,
                    ),
                  ),
                )
              else
                for (final f in details)
                  _FactCard(
                    fact: f,
                    onEdit: () => _editFact(f),
                    onDelete: () => _deleteFact(f),
                  ),
              const SizedBox(height: 22),
              _AddFactField(
                controller: _add,
                canAdd: _canAdd,
                onAdd: _submitAdd,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.summary});

  final String summary;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: BoxDecoration(
        color: AppTheme.sage.withOpacity(0.06),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.sage.withOpacity(0.18), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.auto_awesome, size: 15, color: AppTheme.sage),
              SizedBox(width: 6),
              Text(
                "IN STEADY'S WORDS",
                // sageDark (6.4:1 on the tinted card) — plain sage is 4.4:1,
                // just under AA for this 11.5px label (§5.7.1 check).
                style: TextStyle(
                  color: AppTheme.sageDark,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            summary,
            style: const TextStyle(
              color: AppTheme.textDark,
              fontSize: 15,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _FactCard extends StatelessWidget {
  const _FactCard({
    required this.fact,
    required this.onEdit,
    required this.onDelete,
  });

  final CoachMemoryFact fact;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  String get _meta {
    final kind = fact.kind == CoachFactKind.goal ? 'Goal' : 'About you';
    final source = fact.source == CoachFactSource.user
        ? 'you added this'
        : 'Steady noticed this';
    return '$kind · $source';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: AppTheme.cardShadow,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    fact.text,
                    style: const TextStyle(
                      color: AppTheme.textDark,
                      fontSize: 16,
                      height: 1.4,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _meta,
                  style: const TextStyle(
                    color: AppTheme.textSoft,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: 'Edit',
            onPressed: onEdit,
            icon: const Icon(Icons.edit_outlined,
                size: 20, color: AppTheme.textSoft),
          ),
          IconButton(
            tooltip: 'Delete',
            onPressed: onDelete,
            icon: Icon(Icons.delete_outline,
                size: 20, color: AppTheme.statusAlert.withOpacity(0.85)),
          ),
        ],
      ),
    );
  }
}

class _AddFactField extends StatelessWidget {
  const _AddFactField({
    required this.controller,
    required this.canAdd,
    required this.onAdd,
    this.label = 'Tell Steady something',
    this.hint = 'e.g. I like walking after lunch',
  });

  final TextEditingController controller;
  final bool canAdd;
  final VoidCallback onAdd;
  final String label;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: AppTheme.textDark,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                minLines: 1,
                maxLines: 3,
                textInputAction: TextInputAction.done,
                textCapitalization: TextCapitalization.sentences,
                onSubmitted: (_) {
                  if (canAdd) onAdd();
                },
                style: const TextStyle(fontSize: 15, color: AppTheme.textDark),
                decoration: InputDecoration(
                  hintText: hint,
                  hintStyle: TextStyle(
                    color: AppTheme.textSoft.withOpacity(0.8),
                    fontSize: 14.5,
                  ),
                  isDense: true,
                  filled: true,
                  fillColor: Colors.white,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: AppTheme.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: AppTheme.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: AppTheme.sage, width: 1.5),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              height: 50,
              child: FilledButton(
                onPressed: canAdd ? onAdd : null,
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.sage,
                  disabledBackgroundColor: AppTheme.border,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text('Add',
                    style:
                        TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _MemorySectionLabel extends StatelessWidget {
  const _MemorySectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        text.toUpperCase(),
        style: const TextStyle(
          color: AppTheme.textSoft,
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.0,
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
// (c) Coach settings sheet — tone (warm↔direct) + SMS opt-in (C3 §5.6)
// ════════════════════════════════════════════════════════════════════

/// A self-contained modal sheet for the two coach preferences. It holds an
/// optimistic local copy so a toggle responds instantly, persists each change
/// via [onUpdate], and reconciles from the returned authoritative prefs (or
/// reverts + toasts on failure). Reachable from the Coach AppBar's settings
/// action. Accessibility: labels are 15px `textDark`; the sage switch +
/// segmented tone control both clear 44px tap targets.
class _CoachSettingsSheet extends StatefulWidget {
  const _CoachSettingsSheet({required this.initialPrefs, required this.onUpdate});

  final CoachPrefs initialPrefs;
  final Future<CoachPrefs> Function({String? tone, bool? smsTeaser}) onUpdate;

  @override
  State<_CoachSettingsSheet> createState() => _CoachSettingsSheetState();
}

class _CoachSettingsSheetState extends State<_CoachSettingsSheet> {
  late CoachPrefs _prefs = widget.initialPrefs;
  bool _saving = false;

  Future<void> _apply({String? tone, bool? smsTeaser}) async {
    if (_saving) return;
    final prev = _prefs;
    setState(() {
      _saving = true;
      _prefs = _prefs.copyWith(
        tone: tone == null ? null : CoachTone.fromWire(tone),
        smsTeaser: smsTeaser,
      );
    });
    try {
      final updated = await widget.onUpdate(tone: tone, smsTeaser: smsTeaser);
      if (!mounted) return;
      setState(() {
        _prefs = updated;
        _saving = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _prefs = prev;
        _saving = false;
      });
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text("Couldn't save that. Please try again.")),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppTheme.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Coach settings',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textDark,
                  ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Personalize how Steady talks with you.',
              style: TextStyle(
                color: AppTheme.textSoft,
                fontSize: 13.5,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 22),
            const Text(
              'How Steady talks',
              style: TextStyle(
                color: AppTheme.textDark,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
            _ToneSelector(
              tone: _prefs.tone,
              onChanged: _saving ? null : (t) => _apply(tone: t.wire),
            ),
            const SizedBox(height: 8),
            Text(
              _prefs.tone == CoachTone.warm
                  ? 'Warm — friendly and encouraging.'
                  : 'Direct — brief and to the point.',
              style: const TextStyle(
                color: AppTheme.textSoft,
                fontSize: 13,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 24),
            _SmsOptInTile(
              value: _prefs.smsTeaser,
              onChanged: _saving ? null : (v) => _apply(smsTeaser: v),
            ),
          ],
        ),
      ),
    );
  }
}

/// Two-segment Warm | Direct selector. The selected segment is sage-filled
/// white text; the other is a bordered white chip. Each segment is a 48px
/// tap target (≥44).
class _ToneSelector extends StatelessWidget {
  const _ToneSelector({required this.tone, required this.onChanged});

  final CoachTone tone;
  final ValueChanged<CoachTone>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: _segment('Warm', CoachTone.warm)),
        const SizedBox(width: 10),
        Expanded(child: _segment('Direct', CoachTone.direct)),
      ],
    );
  }

  Widget _segment(String label, CoachTone value) {
    final selected = tone == value;
    return Material(
      color: selected ? AppTheme.sage : Colors.white,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onChanged == null ? null : () => onChanged!(value),
        child: Container(
          height: 48,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? AppTheme.sage : AppTheme.border,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? Colors.white : AppTheme.textDark,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

/// "Coach text messages" opt-in (C2's `coachSmsTeaser`). Off by default; the
/// subtitle states it's separate from the activity alerts. Sage switch,
/// matching the Care Team toggles.
class _SmsOptInTile extends StatelessWidget {
  const _SmsOptInTile({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Coach text messages',
                style: TextStyle(
                  color: AppTheme.textDark,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              SizedBox(height: 4),
              Text(
                "Occasional texts from Steady when there's something worth a "
                'nudge. Separate from your activity alerts.',
                style: TextStyle(
                  color: AppTheme.textSoft,
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Switch(
          value: value,
          onChanged: onChanged,
          activeColor: AppTheme.sage,
        ),
      ],
    );
  }
}
