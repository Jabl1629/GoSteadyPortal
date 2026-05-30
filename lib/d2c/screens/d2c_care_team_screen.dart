import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../theme/app_theme.dart';
import '../data/d2c_mock_data.dart';
import '../widgets/d2c_bottom_nav.dart';

/// Care Team (Care Circle) management screen.
///
/// Shows the household's Members + their roles, pending invites, and
/// (Admin-only) pending walk-up access requests. Admins get write
/// affordances (invite, promote/demote, remove, approve/deny); plain
/// Members see a read-only roster.
///
/// `viewerIsAdmin` controls the whole write surface. The walker user is
/// rendered as a Member even when they have no account (no email/last-
/// active) — the architecture treats "walker user without account" as a
/// first-class state.
class D2CCareTeamScreen extends StatefulWidget {
  const D2CCareTeamScreen({super.key, this.viewerIsAdmin = true});

  final bool viewerIsAdmin;

  @override
  State<D2CCareTeamScreen> createState() => _D2CCareTeamScreenState();
}

class _D2CCareTeamScreenState extends State<D2CCareTeamScreen> {
  late List<CareCircleMember> _members;
  late List<PendingInvite> _invites;
  late List<AccessRequest> _requests;

  @override
  void initState() {
    super.initState();
    _members = D2CMockData.careCircle();
    _invites = D2CMockData.pendingInvites();
    _requests = D2CMockData.accessRequests();
  }

  int get _adminCount => _members.where((m) => m.isAdmin).length;

  @override
  Widget build(BuildContext context) {
    final isAdmin = widget.viewerIsAdmin;
    return Scaffold(
      backgroundColor: AppTheme.warmWhite,
      appBar: AppBar(
        backgroundColor: AppTheme.warmWhite,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        automaticallyImplyLeading: false,
        title: Text(
          'Care Team',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: AppTheme.textDark,
              ),
        ),
      ),
      bottomNavigationBar: const D2CBottomNav(active: D2CTab.careTeam),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
            children: [
              Text(
                "Everyone who can see Susan's activity. "
                '${_members.length} ${_members.length == 1 ? "person" : "people"}'
                '${_invites.isNotEmpty ? " · ${_invites.length} pending" : ""}.',
                style: const TextStyle(
                  color: AppTheme.textSoft,
                  fontSize: 14,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 20),

              // Access requests (Admin only) — surfaced first; they're
              // time-sensitive.
              if (isAdmin && _requests.isNotEmpty) ...[
                const _SectionLabel('Requests to join'),
                const SizedBox(height: 10),
                for (final r in _requests)
                  _AccessRequestCard(
                    request: r,
                    onApprove: () => _decideRequest(r, approved: true),
                    onDeny: () => _decideRequest(r, approved: false),
                  ),
                const SizedBox(height: 24),
              ],

              // Members
              const _SectionLabel('Members'),
              const SizedBox(height: 10),
              for (final m in _members)
                _MemberCard(
                  member: m,
                  canManage: isAdmin && !m.isViewer,
                  onTap: isAdmin && !m.isViewer
                      ? () => _openMemberSheet(m)
                      : null,
                ),

              // Pending invites
              if (_invites.isNotEmpty) ...[
                const SizedBox(height: 24),
                const _SectionLabel('Invited'),
                const SizedBox(height: 10),
                for (final inv in _invites)
                  _InviteCard(
                    invite: inv,
                    canManage: isAdmin,
                    onResend: () => _toast('Invite resent to ${inv.email}'),
                    onCancel: () => setState(() => _invites.remove(inv)),
                  ),
              ],

              if (isAdmin) ...[
                const SizedBox(height: 28),
                _InviteButton(onTap: _openInviteSheet),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppTheme.sage,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _decideRequest(AccessRequest r, {required bool approved}) {
    setState(() => _requests.remove(r));
    _toast(approved
        ? '${r.name} added to the Care Team'
        : "${r.name}'s request was declined");
  }

  Future<void> _openInviteSheet() async {
    final result = await showModalBottomSheet<_InviteResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _InviteSheet(),
    );
    if (result != null) {
      _toast('Invite sent to ${result.email}');
    }
  }

  Future<void> _openMemberSheet(CareCircleMember m) async {
    final action = await showModalBottomSheet<_MemberAction>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _MemberSheet(
        member: m,
        isLastAdmin: m.isAdmin && _adminCount <= 1,
      ),
    );
    if (action == null) return;
    switch (action) {
      case _MemberAction.toggleAdmin:
        _toast(m.isAdmin
            ? '${m.displayName} is no longer an admin'
            : '${m.displayName} is now an admin');
        break;
      case _MemberAction.remove:
        setState(() => _members.remove(m));
        _toast('${m.displayName} removed from the Care Team');
        break;
    }
  }
}

// ─────────────────────────────────────────────────────────────────────
// Member card
// ─────────────────────────────────────────────────────────────────────

class _MemberCard extends StatelessWidget {
  const _MemberCard({
    required this.member,
    required this.canManage,
    this.onTap,
  });

  final CareCircleMember member;
  final bool canManage;
  final VoidCallback? onTap;

  String _lastActive() {
    if (member.isWalkerUser && member.lastActiveAt == null) {
      return 'The walker — no account needed';
    }
    final t = member.lastActiveAt;
    if (t == null) return 'Hasn\'t signed in yet';
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 60) return 'Active just now';
    if (d.inHours < 24) return 'Active ${d.inHours}h ago';
    return 'Active ${d.inDays}d ago';
  }

  @override
  Widget build(BuildContext context) {
    final initials = member.displayName
        .trim()
        .split(' ')
        .where((p) => p.isNotEmpty)
        .take(2)
        .map((p) => p[0])
        .join();
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: AppTheme.cardShadow,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 22,
                  backgroundColor: member.isWalkerUser
                      ? AppTheme.sage.withOpacity(0.14)
                      : AppTheme.cream,
                  child: Text(
                    initials,
                    style: TextStyle(
                      color: member.isWalkerUser
                          ? AppTheme.sage
                          : AppTheme.textDark,
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              member.isViewer
                                  ? '${member.displayName} (you)'
                                  : member.displayName,
                              style: const TextStyle(
                                color: AppTheme.textDark,
                                fontSize: 15.5,
                                fontWeight: FontWeight.w600,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          if (member.isWalkerUser) const _Badge('Walker'),
                          if (member.isAdmin) ...[
                            const SizedBox(width: 4),
                            const _Badge('Admin', filled: true),
                          ],
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        member.relationship == 'Self'
                            ? _lastActive()
                            : '${member.relationship} · ${_lastActive()}',
                        style: const TextStyle(
                          color: AppTheme.textSoft,
                          fontSize: 12.5,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (canManage)
                  const Icon(
                    Icons.chevron_right_rounded,
                    color: AppTheme.textSoft,
                    size: 22,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.label, {this.filled = false});
  final String label;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: filled ? AppTheme.sage : AppTheme.sage.withOpacity(0.10),
        borderRadius: BorderRadius.circular(100),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: filled ? Colors.white : AppTheme.sage,
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Access request card
// ─────────────────────────────────────────────────────────────────────

class _AccessRequestCard extends StatelessWidget {
  const _AccessRequestCard({
    required this.request,
    required this.onApprove,
    required this.onDeny,
  });

  final AccessRequest request;
  final VoidCallback onApprove;
  final VoidCallback onDeny;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
      decoration: BoxDecoration(
        color: AppTheme.sage.withOpacity(0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.sage.withOpacity(0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.qr_code_scanner_rounded,
                  size: 18, color: AppTheme.sage),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${request.name} · claims to be ${request.relationshipClaim}',
                  style: const TextStyle(
                    color: AppTheme.textDark,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '"${request.note}"',
              style: const TextStyle(
                color: AppTheme.textDark,
                fontSize: 13.5,
                height: 1.45,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Scanned the QR on the walker · requested ${_ago(request.requestedAt)}',
            style: TextStyle(
              color: AppTheme.textSoft.withOpacity(0.9),
              fontSize: 11.5,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: onDeny,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.textSoft,
                    side: BorderSide(color: AppTheme.border),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(100),
                    ),
                  ),
                  child: const Text('Not now',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  onPressed: onApprove,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.sage,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(100),
                    ),
                  ),
                  child: const Text('Add to Care Team',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Pending invite card
// ─────────────────────────────────────────────────────────────────────

class _InviteCard extends StatelessWidget {
  const _InviteCard({
    required this.invite,
    required this.canManage,
    required this.onResend,
    required this.onCancel,
  });

  final PendingInvite invite;
  final bool canManage;
  final VoidCallback onResend;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.border.withOpacity(0.7)),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: AppTheme.cream,
            child: Icon(Icons.mail_outline_rounded,
                color: AppTheme.textSoft.withOpacity(0.8), size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  invite.name,
                  style: const TextStyle(
                    color: AppTheme.textDark,
                    fontSize: 15.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'Invited ${_ago(invite.sentAt)} · expires in ${invite.expiresInDays} days',
                  style: const TextStyle(
                    color: AppTheme.textSoft,
                    fontSize: 12.5,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (canManage)
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_horiz_rounded,
                  color: AppTheme.textSoft),
              onSelected: (v) => v == 'resend' ? onResend() : onCancel(),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'resend', child: Text('Resend invite')),
                PopupMenuItem(value: 'cancel', child: Text('Cancel invite')),
              ],
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Invite button
// ─────────────────────────────────────────────────────────────────────

class _InviteButton extends StatelessWidget {
  const _InviteButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: onTap,
        icon: const Icon(Icons.person_add_alt_1_rounded, size: 20),
        label: const Text('Invite someone',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
        style: FilledButton.styleFrom(
          backgroundColor: AppTheme.sage,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(100),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Invite bottom sheet
// ─────────────────────────────────────────────────────────────────────

class _InviteResult {
  const _InviteResult(this.email);
  final String email;
}

class _InviteSheet extends StatefulWidget {
  const _InviteSheet();

  @override
  State<_InviteSheet> createState() => _InviteSheetState();
}

class _InviteSheetState extends State<_InviteSheet> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _relationship = TextEditingController();
  bool _asAdmin = false;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _relationship.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context).pop(_InviteResult(_email.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    return _SheetScaffold(
      title: 'Invite someone',
      subtitle: "They'll get a text and email link to join Susan's Care Team.",
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _SheetField(
              controller: _name,
              label: 'Their name',
              hint: 'e.g. Michael',
              textCapitalization: TextCapitalization.words,
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Required' : null,
            ),
            const SizedBox(height: 14),
            _SheetField(
              controller: _email,
              label: 'Email',
              hint: 'name@example.com',
              keyboardType: TextInputType.emailAddress,
              validator: (v) {
                if (v == null || v.trim().isEmpty) return 'Required';
                if (!v.contains('@')) return 'Enter a valid email';
                return null;
              },
            ),
            const SizedBox(height: 14),
            _SheetField(
              controller: _relationship,
              label: 'Relationship to Susan',
              hint: 'e.g. Son, Neighbor, Aide',
              textCapitalization: TextCapitalization.words,
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Required' : null,
            ),
            const SizedBox(height: 18),
            _AdminToggle(
              value: _asAdmin,
              onChanged: (v) => setState(() => _asAdmin = v),
            ),
            const SizedBox(height: 22),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _submit,
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.sage,
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(100),
                  ),
                ),
                child: const Text('Send invite',
                    style:
                        TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AdminToggle extends StatelessWidget {
  const _AdminToggle({required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      decoration: BoxDecoration(
        color: AppTheme.cream,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Text(
                  'Make them an admin',
                  style: TextStyle(
                    color: AppTheme.textDark,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'Admins can invite others, manage the device, and handle billing.',
                  style: TextStyle(color: AppTheme.textSoft, fontSize: 12.5),
                ),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeColor: AppTheme.sage,
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Member detail bottom sheet
// ─────────────────────────────────────────────────────────────────────

enum _MemberAction { toggleAdmin, remove }

class _MemberSheet extends StatelessWidget {
  const _MemberSheet({required this.member, required this.isLastAdmin});
  final CareCircleMember member;
  final bool isLastAdmin;

  @override
  Widget build(BuildContext context) {
    return _SheetScaffold(
      title: member.displayName,
      subtitle: '${member.relationship} · ${member.email}',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SheetActionRow(
            icon: member.isAdmin
                ? Icons.remove_moderator_outlined
                : Icons.add_moderator_outlined,
            label: member.isAdmin ? 'Remove admin access' : 'Make admin',
            subtitle: isLastAdmin
                ? "Can't remove — they're the only admin"
                : null,
            disabled: isLastAdmin,
            onTap: isLastAdmin
                ? null
                : () => Navigator.of(context).pop(_MemberAction.toggleAdmin),
          ),
          const SizedBox(height: 8),
          _SheetActionRow(
            icon: Icons.person_remove_outlined,
            label: 'Remove from Care Team',
            destructive: true,
            onTap: () => Navigator.of(context).pop(_MemberAction.remove),
          ),
        ],
      ),
    );
  }
}

class _SheetActionRow extends StatelessWidget {
  const _SheetActionRow({
    required this.icon,
    required this.label,
    this.subtitle,
    this.onTap,
    this.destructive = false,
    this.disabled = false,
  });

  final IconData icon;
  final String label;
  final String? subtitle;
  final VoidCallback? onTap;
  final bool destructive;
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    final color = disabled
        ? AppTheme.textSoft.withOpacity(0.5)
        : (destructive ? AppTheme.statusAlert : AppTheme.textDark);
    return Material(
      color: AppTheme.cream,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        color: color,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        style: const TextStyle(
                          color: AppTheme.textSoft,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Shared sheet chrome + field
// ─────────────────────────────────────────────────────────────────────

class _SheetScaffold extends StatelessWidget {
  const _SheetScaffold({
    required this.title,
    required this.child,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Container(
      decoration: const BoxDecoration(
        color: AppTheme.warmWhite,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.fromLTRB(24, 12, 24, 24 + bottomInset),
      child: SafeArea(
        top: false,
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
                  borderRadius: BorderRadius.circular(100),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              title,
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                  ),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 6),
              Text(
                subtitle!,
                style: const TextStyle(
                  color: AppTheme.textSoft,
                  fontSize: 14,
                  height: 1.4,
                ),
              ),
            ],
            const SizedBox(height: 22),
            child,
          ],
        ),
      ),
    );
  }
}

class _SheetField extends StatelessWidget {
  const _SheetField({
    required this.controller,
    required this.label,
    this.hint,
    this.keyboardType,
    this.textCapitalization = TextCapitalization.none,
    this.validator,
    this.inputFormatters,
  });

  final TextEditingController controller;
  final String label;
  final String? hint;
  final TextInputType? keyboardType;
  final TextCapitalization textCapitalization;
  final String? Function(String?)? validator;
  final List<TextInputFormatter>? inputFormatters;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: AppTheme.textDark,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        TextFormField(
          controller: controller,
          keyboardType: keyboardType,
          textCapitalization: textCapitalization,
          validator: validator,
          inputFormatters: inputFormatters,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          style: const TextStyle(fontSize: 15, color: AppTheme.textDark),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle:
                TextStyle(color: AppTheme.textSoft.withOpacity(0.7), fontSize: 15),
            isDense: true,
            filled: true,
            fillColor: Colors.white,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: AppTheme.border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: AppTheme.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: AppTheme.sage, width: 1.5),
            ),
          ),
        ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
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

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inDays >= 1) return '${d.inDays} day${d.inDays == 1 ? '' : 's'} ago';
  if (d.inHours >= 1) return '${d.inHours}h ago';
  if (d.inMinutes >= 1) return '${d.inMinutes} min ago';
  return 'just now';
}
