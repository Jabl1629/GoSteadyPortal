import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../api/api_exception.dart';
import '../../theme/app_theme.dart';
import '../d2c_routes.dart';
import '../data/d2c_mock_data.dart';
import '../data/d2c_repository.dart';
import '../widgets/d2c_bottom_nav.dart';

/// Care Team (Care Circle) management screen — repository-driven
/// (d2c-care-circle.md §5.9). The live build wires the deployed
/// care-circle endpoints; the demo/preview builds pass
/// [D2CMockRepository], which keeps in-memory state.
///
/// Shows the household's Members + their roles, pending invites, and
/// (Admin-only) pending walk-up access requests (5b — mock-only until
/// that ships). Admins get write affordances (invite, promote/demote,
/// remove); plain Members see a read-only roster + Leave.
///
/// The walker user is rendered as a Member even when they have no
/// account — "walker user without account" is a first-class state (L2).
class D2CCareTeamScreen extends StatefulWidget {
  const D2CCareTeamScreen({
    super.key,
    required this.repository,
    this.viewerIsAdmin,
  });

  final D2CRepository repository;

  /// Preview-hub override for the write surface; null (live) derives it
  /// from the roster response.
  final bool? viewerIsAdmin;

  @override
  State<D2CCareTeamScreen> createState() => _D2CCareTeamScreenState();
}

class _D2CCareTeamScreenState extends State<D2CCareTeamScreen> {
  CareCircleData? _data;
  Object? _error;
  bool _loading = true;

  List<CareCircleMember> _members = const [];
  List<PendingInvite> _invites = const [];
  List<AccessRequest> _requests = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await widget.repository.careCircle();
      if (!mounted) return;
      setState(() {
        _data = data;
        _members = List.of(data.members);
        _invites = List.of(data.invites);
        _requests = List.of(data.requests);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  bool get _isAdmin => widget.viewerIsAdmin ?? _data?.viewerIsAdmin ?? false;
  String get _walkerName => _data?.walkerName ?? 'your walker';
  int get _adminCount => _members.where((m) => m.isAdmin).length;

  String _errMsg(Object e) =>
      e is ApiException ? e.message : 'Something went wrong. Please try again.';

  @override
  Widget build(BuildContext context) {
    final isAdmin = _isAdmin;
    final viewer = _members.where((m) => m.isViewer).toList();
    final canLeave = viewer.isNotEmpty && !isAdmin;
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
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? _ErrorRetry(message: _errMsg(_error!), onRetry: _load)
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
                      children: [
                        Text(
                          "Everyone who can see $_walkerName's activity. "
                          '${_members.length} ${_members.length == 1 ? "person" : "people"}'
                          '${_invites.isNotEmpty ? " · ${_invites.length} pending" : ""}.',
                          style: const TextStyle(
                            color: AppTheme.textSoft,
                            fontSize: 14,
                            height: 1.4,
                          ),
                        ),
                        const SizedBox(height: 20),

                        // Access requests (Admin only) — surfaced first;
                        // they're time-sensitive. (5b: mock-only for now.)
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
                            canManage:
                                isAdmin && !m.isViewer && m.userId.isNotEmpty,
                            onTap: isAdmin && !m.isViewer && m.userId.isNotEmpty
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
                              onResend: () => _resendInvite(inv),
                              onCancel: () => _cancelInvite(inv),
                            ),
                        ],

                        if (isAdmin) ...[
                          const SizedBox(height: 28),
                          _InviteButton(onTap: _openInviteSheet),
                        ],
                        if (canLeave) ...[
                          const SizedBox(height: 28),
                          _LeaveButton(onTap: _leaveCareTeam),
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

  Future<void> _resendInvite(PendingInvite inv) async {
    try {
      await widget.repository.resendInvite(inv.id);
      _toast('Invite resent to ${inv.name}');
    } catch (e) {
      if (mounted) _toast(_errMsg(e));
    }
  }

  Future<void> _cancelInvite(PendingInvite inv) async {
    try {
      await widget.repository.revokeInvite(inv.id);
      if (!mounted) return;
      setState(() => _invites.remove(inv));
      _toast('Invite canceled');
    } catch (e) {
      if (mounted) _toast(_errMsg(e));
    }
  }

  Future<void> _openInviteSheet() async {
    final req = await showModalBottomSheet<_InviteRequest>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _InviteSheet(walkerName: _walkerName),
    );
    if (req == null) return;
    try {
      final created = await widget.repository.sendInvite(
        name: req.name,
        phone: req.phone,
        relationship: req.relationship,
        asAdmin: req.asAdmin,
        isWalkerUser: req.isWalkerUser,
      );
      if (!mounted) return;
      setState(() => _invites = [..._invites, created]);
      _toast("Invite texted to ${req.name}");
    } catch (e) {
      if (mounted) _toast(_errMsg(e));
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
        try {
          await widget.repository.setMemberAdmin(m.userId, admin: !m.isAdmin);
          if (!mounted) return;
          _toast(m.isAdmin
              ? '${m.displayName} is no longer an admin'
              : '${m.displayName} is now an admin');
          await _load();
        } catch (e) {
          if (mounted) _toast(_errMsg(e));
        }
        break;
      case _MemberAction.remove:
        try {
          await widget.repository.removeMember(m.userId);
          if (!mounted) return;
          setState(() => _members.remove(m));
          _toast('${m.displayName} removed from the Care Team');
        } catch (e) {
          if (mounted) _toast(_errMsg(e));
        }
        break;
    }
  }

  Future<void> _leaveCareTeam() async {
    final viewerId = _data?.viewerUserId ?? '';
    if (viewerId.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Leave this Care Team?'),
        content: Text(
          "You'll no longer see $_walkerName's activity or alerts. "
          'An Admin can invite you back any time.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Stay'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.statusAlert),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.repository.removeMember(viewerId);
      if (!mounted) return;
      _toast('You left the Care Team');
      context.go(D2CRoutes.dashboard);
    } catch (e) {
      if (mounted) _toast(_errMsg(e));
    }
  }
}

class _ErrorRetry extends StatelessWidget {
  const _ErrorRetry({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 44, color: AppTheme.textSoft),
            const SizedBox(height: 12),
            Text(message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppTheme.textDark)),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

class _LeaveButton extends StatelessWidget {
  const _LeaveButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: onTap,
        icon: const Icon(Icons.logout_rounded, size: 18),
        label: const Text('Leave Care Team',
            style: TextStyle(fontWeight: FontWeight.w600)),
        style: OutlinedButton.styleFrom(
          foregroundColor: AppTheme.statusAlert,
          side: BorderSide(color: AppTheme.statusAlert.withOpacity(0.5)),
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(100),
          ),
        ),
      ),
    );
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
    if (member.isWalkerUser && member.lastActiveAt == null && member.userId.isEmpty) {
      return 'The walker — no account needed';
    }
    final t = member.lastActiveAt;
    if (t == null) {
      // Live roster: last-active isn't tracked in V1 — show the masked
      // contact instead of a misleading "hasn't signed in yet".
      return member.contactMask.isNotEmpty ? member.contactMask : 'Member';
    }
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

class _InviteRequest {
  const _InviteRequest({
    required this.name,
    required this.phone,
    required this.relationship,
    required this.asAdmin,
    required this.isWalkerUser,
  });

  final String name;
  final String phone;
  final String relationship;
  final bool asAdmin;
  final bool isWalkerUser;
}

class _InviteSheet extends StatefulWidget {
  const _InviteSheet({required this.walkerName});

  final String walkerName;

  @override
  State<_InviteSheet> createState() => _InviteSheetState();
}

class _InviteSheetState extends State<_InviteSheet> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _relationship = TextEditingController();
  bool _asAdmin = false;
  bool _isWalkerUser = false;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _relationship.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context).pop(_InviteRequest(
      name: _name.text.trim(),
      phone: _phone.text.trim(),
      relationship: _relationship.text.trim(),
      asAdmin: _asAdmin,
      isWalkerUser: _isWalkerUser,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return _SheetScaffold(
      title: 'Invite someone',
      // Phone-first (d2c-care-circle.md D1): the invite is a text, and
      // joining requires verifying that same number — a forwarded link
      // grants nothing.
      subtitle: "We'll text them a link to join ${widget.walkerName}'s Care "
          'Team. They join by verifying this phone number.',
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
              controller: _phone,
              label: 'Mobile phone',
              hint: '(555) 123-4567',
              keyboardType: TextInputType.phone,
              validator: (v) {
                final digits = (v ?? '').replaceAll(RegExp(r'\D'), '');
                if (digits.isEmpty) return 'Required';
                if (digits.length < 10) return 'Enter a 10-digit mobile number';
                return null;
              },
            ),
            const SizedBox(height: 14),
            _SheetField(
              controller: _relationship,
              label: 'Relationship to ${widget.walkerName} (optional)',
              hint: 'e.g. Son, Neighbor, Aide',
              textCapitalization: TextCapitalization.words,
            ),
            const SizedBox(height: 18),
            _AdminToggle(
              value: _asAdmin,
              onChanged: (v) => setState(() => _asAdmin = v),
            ),
            const SizedBox(height: 10),
            _WalkerUserToggle(
              walkerName: widget.walkerName,
              value: _isWalkerUser,
              onChanged: (v) => setState(() => _isWalkerUser = v),
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

class _WalkerUserToggle extends StatelessWidget {
  const _WalkerUserToggle({
    required this.walkerName,
    required this.value,
    required this.onChanged,
  });
  final String walkerName;
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
              children: [
                Text(
                  'This is $walkerName',
                  style: const TextStyle(
                    color: AppTheme.textDark,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                const Text(
                  "Invite the walker user themselves — links their account to the activity you see.",
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
    final contact = member.email.isNotEmpty ? member.email : member.contactMask;
    final subtitleParts =
        [member.relationship, contact].where((s) => s.isNotEmpty).toList();
    return _SheetScaffold(
      title: member.displayName,
      subtitle: subtitleParts.isEmpty ? null : subtitleParts.join(' · '),
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
