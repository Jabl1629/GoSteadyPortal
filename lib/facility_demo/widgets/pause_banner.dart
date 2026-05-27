import 'package:flutter/material.dart';

import '../../api/api_exception.dart';
import '../../api/api_models.dart' as api;
import '../../data/facility_repository.dart';
import '../../theme/app_theme.dart';

/// Patient Detail banner shown when [api.NotificationsPaused] is set
/// and active. Displays reason + days remaining + a single-tap
/// Resume button.
///
/// Per phase-2b-fac-w-facility-writes.md L8 + user-needs US-31.
class PauseBanner extends StatefulWidget {
  const PauseBanner({
    super.key,
    required this.patientId,
    required this.paused,
    required this.data,
    required this.onResumed,
  });

  final String patientId;
  final api.NotificationsPaused paused;
  final FacilityRepository data;
  final VoidCallback onResumed;

  @override
  State<PauseBanner> createState() => _PauseBannerState();
}

class _PauseBannerState extends State<PauseBanner> {
  bool _submitting = false;

  Future<void> _resume() async {
    setState(() => _submitting = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.data.resumeNotifications(widget.patientId);
      widget.onResumed();
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: const Text('Notifications resumed.'),
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppTheme.sage,
          duration: const Duration(seconds: 3),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            e is ApiException ? '${e.code}: ${e.message}' : 'Could not resume: $e',
          ),
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppTheme.statusAlert,
          duration: const Duration(seconds: 5),
        ),
      );
      if (mounted) setState(() => _submitting = false);
    }
  }

  String _humanReason(String reason) {
    final r = api.PauseReason.values.firstWhere(
      (p) => p.wireValue == reason,
      orElse: () => api.PauseReason.other,
    );
    return r.label;
  }

  String _remainingLabel(DateTime until) {
    final d = until.difference(DateTime.now());
    if (d.isNegative) return 'expired';
    if (d.inDays >= 1) {
      return '${d.inDays} day${d.inDays == 1 ? '' : 's'} remaining';
    }
    if (d.inHours >= 1) {
      return '${d.inHours} hour${d.inHours == 1 ? '' : 's'} remaining';
    }
    return '<1 hour remaining';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppTheme.statusWarn.withOpacity(0.10),
        borderRadius: BorderRadius.circular(AppTheme.cardRadius),
        border: Border.all(color: AppTheme.statusWarn.withOpacity(0.35)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Row(
        children: [
          Icon(
            Icons.notifications_paused_outlined,
            color: AppTheme.statusWarn,
            size: 22,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Notifications paused — ${_humanReason(widget.paused.reason)}',
                  style: const TextStyle(
                    color: AppTheme.textDark,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _remainingLabel(widget.paused.until),
                  style: const TextStyle(
                    color: AppTheme.textSoft,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          TextButton.icon(
            onPressed: _submitting ? null : _resume,
            icon: _submitting
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor:
                          AlwaysStoppedAnimation<Color>(AppTheme.statusWarn),
                    ),
                  )
                : Icon(Icons.play_arrow_rounded,
                    color: AppTheme.statusWarn, size: 18),
            label: Text(
              _submitting ? 'Resuming…' : 'Resume',
              style: TextStyle(
                color: AppTheme.statusWarn,
                fontWeight: FontWeight.w600,
              ),
            ),
            style: TextButton.styleFrom(
              backgroundColor: Colors.white,
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(100),
                side: BorderSide(color: AppTheme.statusWarn.withOpacity(0.35)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
