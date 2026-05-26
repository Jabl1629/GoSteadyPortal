import 'package:flutter/material.dart';
import 'package:visibility_detector/visibility_detector.dart';

/// Wraps a child in [VisibilityDetector] and fires [onFirstVisible]
/// exactly once when the child first scrolls into view.
///
/// When [onFirstVisible] is null (e.g. demo mode where the
/// [FacilityRepository] doesn't need a viewport trigger), the child
/// is returned unwrapped — no detector overhead.
///
/// Per phase-2b-fac-r-facility-reads.md L5 — used by Census List
/// + Tile views to enqueue per-row `rowStatsFor +
/// notificationsForPatient` fetches through a
/// [RowLoaderQueue].
class MaybeVisible extends StatefulWidget {
  const MaybeVisible({
    super.key,
    required this.detectorKey,
    required this.onFirstVisible,
    required this.child,
  });

  /// Stable key for the underlying [VisibilityDetector]. Typically
  /// `ValueKey('row-$patientId')` so each row in a list has a unique
  /// detector instance.
  final Key detectorKey;
  final VoidCallback? onFirstVisible;
  final Widget child;

  @override
  State<MaybeVisible> createState() => _MaybeVisibleState();
}

class _MaybeVisibleState extends State<MaybeVisible> {
  bool _fired = false;

  @override
  Widget build(BuildContext context) {
    final cb = widget.onFirstVisible;
    if (cb == null) return widget.child;
    return VisibilityDetector(
      key: widget.detectorKey,
      onVisibilityChanged: (info) {
        if (_fired || info.visibleFraction <= 0) return;
        _fired = true;
        // Defer to the next frame so the callback never fires during
        // build/layout — Flutter would assert if we triggered a
        // setState in the parent mid-build.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          cb();
        });
      },
      child: widget.child,
    );
  }
}
