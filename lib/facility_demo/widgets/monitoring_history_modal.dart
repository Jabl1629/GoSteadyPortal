import 'package:flutter/material.dart';

import '../../api/api_models.dart' as api;
import '../../data/facility_repository.dart';
import '../../theme/app_theme.dart';

/// Read-only "Monitoring history" modal launched from patient detail. Shows
/// every monitoring period for a patient — device + start + end — most-
/// recent-first, from [FacilityRepository.monitoringHistory]
/// (`GET /patients/{id}/devices`). Each row is one DeviceAssignments period;
/// an open-ended period renders as an "Ongoing" chip.
class MonitoringHistoryModal extends StatelessWidget {
  const MonitoringHistoryModal({
    super.key,
    required this.patientId,
    required this.data,
  });

  final String patientId;
  final FacilityRepository data;

  static Future<void> show(
    BuildContext context, {
    required String patientId,
    required FacilityRepository data,
  }) =>
      showDialog<void>(
        context: context,
        barrierColor: Colors.black.withOpacity(0.45),
        builder: (_) =>
            MonitoringHistoryModal(patientId: patientId, data: data),
      );

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.of(context).size.width >= 560;
    // Resolve censusId → unit name for a friendlier row subtitle.
    final unitNames = <String, String>{
      for (final u in data.allUnits()) u.id: u.displayName,
    };

    return Dialog(
      backgroundColor: AppTheme.warmWhite,
      insetPadding: EdgeInsets.symmetric(
        horizontal: isWide ? 40 : 16,
        vertical: 24,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Header(onClose: () => Navigator.of(context).pop()),
              const SizedBox(height: 20),
              Flexible(
                child: FutureBuilder<List<api.MonitoringSession>>(
                  future: data.monitoringHistory(patientId),
                  builder: (context, snap) {
                    if (snap.connectionState == ConnectionState.waiting) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 48),
                        child: Center(
                          child: CircularProgressIndicator(color: AppTheme.sage),
                        ),
                      );
                    }
                    if (snap.hasError) {
                      return _Message(
                        icon: Icons.error_outline_rounded,
                        color: AppTheme.statusAlert,
                        text: 'Could not load monitoring history.',
                      );
                    }
                    final sessions = snap.data ?? const [];
                    if (sessions.isEmpty) {
                      return const _Message(
                        icon: Icons.history_toggle_off_rounded,
                        color: AppTheme.textSoft,
                        text: 'No monitoring sessions yet.',
                      );
                    }
                    return ListView.separated(
                      shrinkWrap: true,
                      itemCount: sessions.length,
                      separatorBuilder: (_, __) =>
                          const Divider(height: 1, color: AppTheme.border),
                      itemBuilder: (_, i) => _SessionRow(
                        session: sessions[i],
                        unitName: sessions[i].censusId == null
                            ? null
                            : unitNames[sessions[i].censusId],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SessionRow extends StatelessWidget {
  const _SessionRow({required this.session, this.unitName});

  final api.MonitoringSession session;
  final String? unitName;

  @override
  Widget build(BuildContext context) {
    final started = _fmtDateTime(session.startedAt);
    final ended = session.ongoing ? null : _fmtDateTime(session.endedAt);
    final duration = _durationLabel(session);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: AppTheme.sage.withOpacity(0.10),
              borderRadius: BorderRadius.circular(9),
            ),
            child: const Icon(Icons.sensors_rounded,
                size: 17, color: AppTheme.sage),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      session.serialNumber,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textDark,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                    if (session.ongoing) ...[
                      const SizedBox(width: 8),
                      const _OngoingChip(),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  ended == null ? '$started → now' : '$started → $ended',
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: AppTheme.textSoft,
                  ),
                ),
                if (unitName != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    unitName!,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: AppTheme.textSoft.withOpacity(0.8),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            duration,
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: AppTheme.textSoft,
            ),
          ),
        ],
      ),
    );
  }
}

class _OngoingChip extends StatelessWidget {
  const _OngoingChip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: AppTheme.statusOk.withOpacity(0.12),
        borderRadius: BorderRadius.circular(100),
        border: Border.all(color: AppTheme.statusOk.withOpacity(0.35)),
      ),
      child: const Text(
        'Ongoing',
        style: TextStyle(
          color: AppTheme.statusOk,
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: AppTheme.sage.withOpacity(0.12),
            borderRadius: BorderRadius.circular(11),
          ),
          child: const Icon(Icons.history_rounded,
              size: 20, color: AppTheme.sage),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Monitoring history',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      height: 1.0,
                    ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Every device this resident has been monitored with.',
                style: TextStyle(color: AppTheme.textSoft, fontSize: 13),
              ),
            ],
          ),
        ),
        IconButton(
          icon: const Icon(Icons.close_rounded, size: 20),
          tooltip: 'Close',
          onPressed: onClose,
          style: IconButton.styleFrom(foregroundColor: AppTheme.textSoft),
        ),
      ],
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.color, required this.text});

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: color.withOpacity(0.7)),
            const SizedBox(height: 12),
            Text(
              text,
              style: TextStyle(color: AppTheme.textSoft, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

// ── formatting helpers ────────────────────────────────────────────

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// "Jun 4, 2026, 1:13 PM" in the viewer's local time.
String _fmtDateTime(DateTime? utc) {
  if (utc == null) return '—';
  final d = utc.toLocal();
  final h12 = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final ampm = d.hour < 12 ? 'AM' : 'PM';
  final mm = d.minute.toString().padLeft(2, '0');
  return '${_months[d.month - 1]} ${d.day}, ${d.year}, $h12:$mm $ampm';
}

/// Human-friendly duration. For an ongoing session, measures start→now.
String _durationLabel(api.MonitoringSession s) {
  int? secs = s.durationSeconds;
  if (secs == null && s.ongoing && s.startedAt != null) {
    secs = DateTime.now().toUtc().difference(s.startedAt!).inSeconds;
  }
  if (secs == null || secs < 0) return '';
  if (secs < 60) return '<1 min';
  final mins = secs ~/ 60;
  if (mins < 60) return '$mins min';
  final hours = mins ~/ 60;
  if (hours < 24) {
    final rem = mins % 60;
    return rem == 0 ? '${hours}h' : '${hours}h ${rem}m';
  }
  final days = hours ~/ 24;
  final remH = hours % 24;
  return remH == 0 ? '${days}d' : '${days}d ${remH}h';
}
