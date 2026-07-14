import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../api/api_exception.dart';
import '../api/api_models.dart';
import '../data/fleet_repository.dart';
import '../models/user.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';

/// Internal fleet board — the clickable equivalent of `tools/fleet.py`.
///
/// internal_admin + internal_support may VIEW; only internal_admin may run the
/// lifecycle actions (provision / end / reset / decommission / recover). All
/// actions go through the audited device-api. Route is gated to internal roles
/// (see app_router.dart); the server is the real enforcement point.
class FleetScreen extends StatefulWidget {
  const FleetScreen({super.key});

  @override
  State<FleetScreen> createState() => _FleetScreenState();
}

class _FleetScreenState extends State<FleetScreen> {
  FleetRepository? _repo;
  Future<List<FleetDevice>>? _future;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_repo == null) {
      // Live when an ApiClient is present; mock in demo mode (no backend).
      final ApiClient? api = AppState.of(context).apiClient;
      _repo = api != null ? LiveFleetRepository(api) : MockFleetRepository();
      _future = _repo!.listFleet();
    }
  }

  void _refresh() => setState(() => _future = _repo!.listFleet());

  bool get _canWrite =>
      AppState.of(context).auth.currentUser?.role == UserRole.internalAdmin;

  // ── Action runner (mirrors resident_settings_dialog._runWrite) ──
  Future<void> _runAction(String successMessage, Future<void> Function() op) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await op();
      messenger.showSnackBar(SnackBar(
        content: Text(successMessage),
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppTheme.sage,
        duration: const Duration(seconds: 3),
      ));
      _refresh();
    } catch (e) {
      final msg = e is ApiException ? '${e.code}: ${e.message}' : 'Failed: $e';
      messenger.showSnackBar(SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppTheme.statusAlert,
        duration: const Duration(seconds: 5),
      ));
    }
  }

  Future<void> _onProvision(FleetDevice d) async {
    final patientId = await _promptText(
      title: 'Provision ${d.serialNumber}',
      label: 'patientId',
      hint: d.patientId ?? 'pat_…',
      initial: d.patientId ?? '',
    );
    if (patientId == null || patientId.isEmpty) return;
    await _runAction('Provisioned ${d.serialNumber} → $patientId (activate sent)',
        () => _repo!.provision(d.serialNumber, patientId));
  }

  Future<void> _onEnd(FleetDevice d) async {
    if (!await _confirm(
        title: 'End assignment on ${d.serialNumber}?',
        body: 'Ends monitoring and fires the wipe cmd. The device auto-recycles '
            'to ready_to_provision once it acks the wipe.',
        confirmLabel: 'End assignment')) return;
    await _runAction('Ended ${d.serialNumber} → discontinued (wipe cmd sent)',
        () => _repo!.endAssignment(d.serialNumber));
  }

  Future<void> _onReset(FleetDevice d) async {
    final reason = await _promptText(
      title: 'Force-reset ${d.serialNumber}',
      label: 'reason (≥4 chars)',
      hint: 'stuck_device',
      initial: 'ops_force_reset',
      danger: true,
      note: 'Admin override → ready_to_provision. Bypasses the wipe check '
          '(the device may still hold prior data until it re-enters '
          'pre-activation). Heavily audited.',
    );
    if (reason == null || reason.length < 4) return;
    await _runAction('Force-reset ${d.serialNumber} → ready_to_provision',
        () => _repo!.forceReset(d.serialNumber, reason));
  }

  Future<void> _onDecommission(FleetDevice d) async {
    final reason = await _promptChoice(
      title: 'Decommission ${d.serialNumber}',
      choices: const ['lost', 'broken', 'retired', 'end_of_life'],
      note: 'Only "lost" is recoverable. Heavily audited.',
    );
    if (reason == null) return;
    await _runAction('Decommissioned ${d.serialNumber} ($reason)',
        () => _repo!.decommission(d.serialNumber, reason));
  }

  Future<void> _onRecover(FleetDevice d) async {
    if (!await _confirm(
        title: 'Recover ${d.serialNumber}?',
        body: 'Returns a lost-decommissioned unit to ready_to_provision.',
        confirmLabel: 'Recover')) return;
    await _runAction('Recovered ${d.serialNumber} → ready_to_provision',
        () => _repo!.recover(d.serialNumber));
  }

  Future<void> _onRelease(FleetDevice d) async {
    if (!await _confirm(
        title: 'Release ownership of ${d.serialNumber}?',
        body: 'Removes this device from its current household so a NEW household '
            'can claim it via QR. Use to rotate a device to a different user. '
            'Heavily audited.',
        confirmLabel: 'Release')) return;
    await _runAction('Released ${d.serialNumber} — now claimable by a new household',
        () => _repo!.release(d.serialNumber));
  }

  Future<void> _onEndAndRelease(FleetDevice d) async {
    if (!await _confirm(
        title: 'End + release ${d.serialNumber}?',
        body: 'Ends the current assignment (fires the wipe), then releases ownership. '
            'Once the device recycles, a NEW household can claim it via QR. Use to '
            'rotate this device to a different user. Heavily audited.',
        confirmLabel: 'End + release')) return;
    // end → then release; the device ends up unowned + recycles to
    // ready_to_provision on the wipe-ack, then is QR-claimable.
    await _runAction(
        'Ended + released ${d.serialNumber} — recycles, then claimable by a new household',
        () async {
      await _repo!.endAssignment(d.serialNumber);
      await _repo!.release(d.serialNumber);
    });
  }

  @override
  Widget build(BuildContext context) {
    final auth = AppState.of(context).auth;
    return Scaffold(
      backgroundColor: AppTheme.cream,
      appBar: AppBar(
        title: const Text('Fleet — internal'),
        actions: [
          if (!_canWrite)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Center(child: _ReadOnlyBadge()),
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _refresh,
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Sign out',
            onPressed: () => auth.signOut(),
          ),
        ],
      ),
      body: FutureBuilder<List<FleetDevice>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(
                child: CircularProgressIndicator(color: AppTheme.sage));
          }
          if (snap.hasError) {
            return _ErrorPanel(error: snap.error, onRetry: _refresh);
          }
          final devices = snap.data ?? const [];
          if (devices.isEmpty) {
            return const _EmptyPanel();
          }
          return _FleetTable(
            devices: devices,
            canWrite: _canWrite,
            onProvision: _onProvision,
            onEnd: _onEnd,
            onReset: _onReset,
            onDecommission: _onDecommission,
            onRecover: _onRecover,
            onRelease: _onRelease,
            onEndAndRelease: _onEndAndRelease,
          );
        },
      ),
    );
  }

  // ── Small dialogs ─────────────────────────────────────────────
  Future<bool> _confirm({
    required String title,
    required String body,
    required String confirmLabel,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.warmWhite,
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(confirmLabel)),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<String?> _promptText({
    required String title,
    required String label,
    String? hint,
    String initial = '',
    String? note,
    bool danger = false,
  }) {
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.warmWhite,
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (note != null) ...[
              Text(note, style: TextStyle(color: AppTheme.textSoft, fontSize: 13)),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: ctrl,
              autofocus: true,
              decoration: InputDecoration(labelText: label, hintText: hint),
              onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, null),
              child: const Text('Cancel')),
          FilledButton(
            style: danger
                ? FilledButton.styleFrom(backgroundColor: AppTheme.statusAlert)
                : null,
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
  }

  Future<String?> _promptChoice({
    required String title,
    required List<String> choices,
    String? note,
  }) {
    String selected = choices.first;
    return showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: AppTheme.warmWhite,
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (note != null) ...[
                Text(note,
                    style: TextStyle(color: AppTheme.textSoft, fontSize: 13)),
                const SizedBox(height: 12),
              ],
              DropdownButton<String>(
                value: selected,
                isExpanded: true,
                items: choices
                    .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                    .toList(),
                onChanged: (v) => setLocal(() => selected = v ?? selected),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, null),
                child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppTheme.statusAlert),
              onPressed: () => Navigator.pop(ctx, selected),
              child: const Text('Decommission'),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Table ───────────────────────────────────────────────────────

typedef _DeviceAction = Future<void> Function(FleetDevice d);

class _FleetTable extends StatelessWidget {
  final List<FleetDevice> devices;
  final bool canWrite;
  final _DeviceAction onProvision, onEnd, onReset, onDecommission, onRecover,
      onRelease, onEndAndRelease;

  const _FleetTable({
    required this.devices,
    required this.canWrite,
    required this.onProvision,
    required this.onEnd,
    required this.onReset,
    required this.onDecommission,
    required this.onRecover,
    required this.onRelease,
    required this.onEndAndRelease,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final table = Container(
        constraints: const BoxConstraints(minWidth: 900),
        margin: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppTheme.warmWhite,
          borderRadius: BorderRadius.circular(AppTheme.cardRadius),
          border: Border.all(color: AppTheme.border),
          boxShadow: AppTheme.cardShadow,
        ),
        child: Column(
          children: [
            const _HeaderRow(),
            for (final d in devices) _DataRow(
              device: d,
              canWrite: canWrite,
              onProvision: onProvision,
              onEnd: onEnd,
              onReset: onReset,
              onDecommission: onDecommission,
              onRecover: onRecover,
              onRelease: onRelease,
              onEndAndRelease: onEndAndRelease,
            ),
          ],
        ),
      );
      // Horizontal scroll on narrow viewports (matches patient_list_view).
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: constraints.maxWidth),
          child: SingleChildScrollView(child: table),
        ),
      );
    });
  }
}

const _colGap = 20.0;
const _wSerial = 130.0;
const _wType = 90.0;
const _wStatus = 210.0;
const _wBatt = 80.0;
const _wSeen = 90.0;
const _wPatient = 190.0;
const _wActions = 200.0;

class _HeaderRow extends StatelessWidget {
  const _HeaderRow();

  @override
  Widget build(BuildContext context) {
    Widget h(String s, double w, {TextAlign align = TextAlign.left}) => SizedBox(
          width: w,
          child: Text(s,
              textAlign: align,
              style: TextStyle(
                  color: AppTheme.textSoft,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.4)),
        );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: AppTheme.border)),
      ),
      child: Row(spacing: _colGap, children: [
        h('SERIAL', _wSerial),
        h('TYPE', _wType),
        h('STATUS', _wStatus),
        h('BATT', _wBatt, align: TextAlign.right),
        h('SEEN', _wSeen, align: TextAlign.right),
        h('PATIENT', _wPatient),
        h('ACTIONS', _wActions),
      ]),
    );
  }
}

class _DataRow extends StatelessWidget {
  final FleetDevice device;
  final bool canWrite;
  final _DeviceAction onProvision, onEnd, onReset, onDecommission, onRecover,
      onRelease, onEndAndRelease;

  const _DataRow({
    required this.device,
    required this.canWrite,
    required this.onProvision,
    required this.onEnd,
    required this.onReset,
    required this.onDecommission,
    required this.onRecover,
    required this.onRelease,
    required this.onEndAndRelease,
  });

  @override
  Widget build(BuildContext context) {
    final d = device;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: AppTheme.border.withOpacity(0.6))),
      ),
      child: Row(
        spacing: _colGap,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: _wSerial,
            child: Text(d.serialNumber,
                style: const TextStyle(
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textDark)),
          ),
          SizedBox(
              width: _wType,
              child: Text(_shortType(d.deviceType),
                  style: TextStyle(color: AppTheme.textSoft, fontSize: 13))),
          SizedBox(width: _wStatus, child: _StatusCell(d)),
          SizedBox(width: _wBatt, child: _BatteryCell(d.batteryPct)),
          SizedBox(
            width: _wSeen,
            child: Text(_ageLabel(d.lastSeen),
                textAlign: TextAlign.right,
                style: TextStyle(
                    color: _isStale(d.lastSeen)
                        ? AppTheme.statusOffline
                        : AppTheme.textSoft,
                    fontSize: 13)),
          ),
          SizedBox(
            width: _wPatient,
            child: Text(d.patientId ?? '—',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontFamily: d.patientId != null ? 'monospace' : null,
                    color: d.patientId != null
                        ? AppTheme.textDark
                        : AppTheme.textSoft,
                    fontSize: 12)),
          ),
          SizedBox(width: _wActions, child: _actions(d)),
        ],
      ),
    );
  }

  Widget _actions(FleetDevice d) {
    if (!canWrite) {
      return Text('—', style: TextStyle(color: AppTheme.textSoft));
    }
    final assigned = d.status == 'active_monitoring' || d.status == 'provisioned';
    // Owned but not actively assigned → can release ownership directly.
    final ownedUnassigned = d.owningClientId != null &&
        (d.status == 'ready_to_provision' || d.status == 'discontinued');
    final primary = _primaryButton(d);
    return Row(children: [
      if (primary != null) primary,
      PopupMenuButton<String>(
        tooltip: 'More actions',
        icon: Icon(Icons.more_horiz, color: AppTheme.textSoft, size: 20),
        onSelected: (v) {
          switch (v) {
            case 'provision': onProvision(d); break;
            case 'end': onEnd(d); break;
            case 'end_release': onEndAndRelease(d); break;
            case 'release': onRelease(d); break;
            case 'reset': onReset(d); break;
            case 'decommission': onDecommission(d); break;
            case 'recover': onRecover(d); break;
          }
        },
        itemBuilder: (_) => [
          const PopupMenuItem(value: 'provision', child: Text('Provision…')),
          const PopupMenuItem(value: 'end', child: Text('End assignment')),
          // Rotation: end+release (assigned) or release (owned+idle) → returns
          // the device to the unowned pool so a new household can claim it.
          if (assigned)
            const PopupMenuItem(
                value: 'end_release', child: Text('End + release (rotate)…')),
          if (ownedUnassigned)
            const PopupMenuItem(
                value: 'release', child: Text('Release ownership (rotate)…')),
          const PopupMenuItem(value: 'reset', child: Text('Force-reset…')),
          const PopupMenuItem(value: 'recover', child: Text('Recover')),
          const PopupMenuDivider(),
          const PopupMenuItem(value: 'decommission', child: Text('Decommission…')),
        ],
      ),
    ]);
  }

  Widget? _primaryButton(FleetDevice d) {
    switch (d.status) {
      case 'ready_to_provision':
        return _btn('Provision', () => onProvision(d));
      case 'provisioned':
      case 'active_monitoring':
        return _btn('End', () => onEnd(d));
      case 'discontinued':
        return _btn('Reset', () => onReset(d));
      case 'decommissioned':
        return _btn('Recover', () => onRecover(d));
      default:
        return null;
    }
  }

  Widget _btn(String label, VoidCallback onTap) => TextButton(
        style: TextButton.styleFrom(
          foregroundColor: AppTheme.sage,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          minimumSize: const Size(0, 34),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        onPressed: onTap,
        child: Text(label),
      );
}

class _StatusCell extends StatelessWidget {
  final FleetDevice d;
  const _StatusCell(this.d);

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _pill(_statusLabel(d.status), _statusColor(d.status)),
        if (d.wipePending) _pill('wipe?', AppTheme.statusWarn, subtle: true),
        if (d.activationPending)
          _pill('activating', AppTheme.statusWarn, subtle: true),
        if (d.decommissionReason != null)
          _pill(d.decommissionReason!, AppTheme.statusOffline, subtle: true),
      ],
    );
  }

  Widget _pill(String text, Color color, {bool subtle = false}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: color.withOpacity(subtle ? 0.10 : 0.14),
          borderRadius: BorderRadius.circular(100),
        ),
        child: Text(text,
            style: TextStyle(
                color: color,
                fontSize: 11.5,
                fontWeight: subtle ? FontWeight.w500 : FontWeight.w600)),
      );
}

class _BatteryCell extends StatelessWidget {
  final double? pct;
  const _BatteryCell(this.pct);

  @override
  Widget build(BuildContext context) {
    if (pct == null) {
      return Text('—',
          textAlign: TextAlign.right,
          style: TextStyle(color: AppTheme.textSoft));
    }
    final color = pct! >= 0.25
        ? AppTheme.statusOk
        : pct! >= 0.10
            ? AppTheme.statusWarn
            : AppTheme.statusAlert;
    return Text('${(pct! * 100).round()}%',
        textAlign: TextAlign.right,
        style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 13));
  }
}

class _ReadOnlyBadge extends StatelessWidget {
  const _ReadOnlyBadge();
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: AppTheme.statusOffline.withOpacity(0.15),
          borderRadius: BorderRadius.circular(100),
        ),
        child: Text('read-only',
            style: TextStyle(
                color: AppTheme.statusOffline,
                fontSize: 12,
                fontWeight: FontWeight.w600)),
      );
}

class _ErrorPanel extends StatelessWidget {
  final Object? error;
  final VoidCallback onRetry;
  const _ErrorPanel({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final e = error;
    final msg = e is ApiException ? '${e.code} (${e.httpStatus}): ${e.message}' : '$e';
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, color: AppTheme.statusAlert, size: 40),
          const SizedBox(height: 12),
          Text('Could not load the fleet',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(msg, style: TextStyle(color: AppTheme.textSoft, fontFamily: 'monospace')),
          const SizedBox(height: 16),
          FilledButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

class _EmptyPanel extends StatelessWidget {
  const _EmptyPanel();
  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.devices_other, color: AppTheme.textSoft, size: 40),
            const SizedBox(height: 12),
            Text('No devices in the registry',
                style: Theme.of(context).textTheme.titleMedium),
          ],
        ),
      );
}

// ── Formatting helpers ──────────────────────────────────────────

String _shortType(String? t) {
  switch (t) {
    case 'rollator_platform':
      return 'rollator';
    case 'walker_cap':
      return 'walker';
    default:
      return t ?? '?';
  }
}

String _statusLabel(String? s) => (s ?? 'unknown').replaceAll('_', ' ');

Color _statusColor(String? s) {
  switch (s) {
    case 'active_monitoring':
      return AppTheme.statusOk;
    case 'ready_to_provision':
      return AppTheme.sageLight;
    case 'provisioned':
      return AppTheme.statusWarn;
    case 'discontinued':
      return AppTheme.statusWarn;
    case 'decommissioned':
      return AppTheme.statusOffline;
    default:
      return AppTheme.statusOffline;
  }
}

bool _isStale(DateTime? t) =>
    t == null || DateTime.now().difference(t) > const Duration(hours: 24);

String _ageLabel(DateTime? t) {
  if (t == null) return 'never';
  final s = DateTime.now().difference(t).inSeconds;
  if (s < 60) return '${s}s';
  if (s < 3600) return '${s ~/ 60}m';
  if (s < 86400) return '${s ~/ 3600}h';
  return '${s ~/ 86400}d';
}
