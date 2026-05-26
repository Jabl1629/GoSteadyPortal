import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../data/facility_repository.dart';
import '../../state/app_state.dart';
import '../../state/polling_controller.dart';
import '../../state/row_loader_queue.dart';
import '../../widgets/maybe_visible.dart';
import '../data/facility_mock_data.dart' show PatientRowStats, Trend;
import '../data/notification_engine.dart';
import '../models/notification.dart';
import '../models/patient.dart';
import '../state/facility_selection.dart';
import '../state/notification_state.dart';
import '../widgets/add_resident_dialog.dart';
import '../widgets/patient_list_view.dart';
import '../widgets/patient_tile.dart';
import '../widgets/simple_select_dropdown.dart';
import '../widgets/view_mode_toggle.dart';

// ── Loaded per-row data + placeholder used until a fetch completes. ──

class _RowData {
  final PatientRowStats stats;
  final List<PatientNotification> computed;
  const _RowData({required this.stats, required this.computed});
  const _RowData.empty()
      : stats = _placeholderStats,
        computed = const [];
}

const _placeholderStats = PatientRowStats(
  alertsThisWeek: 0,
  activeMinutesToday: 0,
  activeMinutes7dAvg: 0,
  activeMinutesPrior7dAvg: 0,
  activeMinutesTrend7d: Trend.flat,
  activeMinutes30dAvg: 0,
  stepsToday: 0,
  stepsTrend7d: Trend.flat,
  stepsRecentAvg: 0,
  stepsPriorAvg: 0,
  gaitSpeed3dAvg: 0,
  gaitSpeedTrend: Trend.flat,
  gaitSpeedPriorAvg: 0,
);

/// Left/main pane of the facility shell. Renders one tile per patient
/// matching the current unit selection, sort, and filter. Click a tile ->
/// sets FacilitySelection.selectedPatientId, triggering the overlay.
///
/// Per phase-2b-fac-r-facility-reads.md L2 — the repository's per-
/// patient methods are async. This view pre-loads row stats +
/// notifications for all visible patients in parallel via a stateful
/// loader, then renders the synchronous list/grid against the loaded
/// data. Throttle + lazy-per-row are L5 follow-ups.
class PatientCensusView extends StatefulWidget {
  const PatientCensusView({
    super.key,
    required this.data,
    required this.selection,
    required this.notifications,
  });

  final FacilityRepository data;
  final FacilitySelection selection;
  final NotificationState notifications;

  @override
  State<PatientCensusView> createState() => _PatientCensusViewState();
}

class _PatientCensusViewState extends State<PatientCensusView> {
  // Loaded per-patient data; keyed by patientId.
  final Map<String, _RowData> _loaded = {};
  // Currently-pending fetches (dedup at this state layer; deeper
  // dedup happens inside [RowLoaderQueue] and the live repo's
  // _TimedCache).
  final Set<String> _inFlight = {};

  /// Lazy-per-row stats loader per phase-2b-fac-r L5 — caps concurrent
  /// `rowStatsFor + notificationsForPatient` fetches at 5 so a 200-
  /// patient cold-load doesn't slam API Gateway's 25 RPS dev throttle.
  /// Tasks are enqueued by each row's `VisibilityDetector` callback
  /// when it first scrolls into view.
  late final RowLoaderQueue<_RowData> _rowQueue;

  PollingController? _polling;

  @override
  void initState() {
    super.initState();
    _rowQueue = RowLoaderQueue<_RowData>(maxConcurrent: 5);
    widget.selection.addListener(_onSelectionChanged);
    widget.notifications.addListener(_rebuild);
    // Kick off fetches for the visible patient set through the
    // throttled queue. The queue caps concurrency at 5 (per L5)
    // even though we eager-enqueue everything — this gives us the
    // API-throttle protection without depending on viewport
    // visibility, which proved fragile in release Flutter Web
    // (VisibilityDetector callbacks sometimes don't fire post-
    // service-worker handover). Visibility-lazy remains an
    // optional polish item if multi-patient pilot data shows the
    // eager-enqueue rate-limit isn't sufficient.
    WidgetsBinding.instance.addPostFrameCallback((_) => _enqueueAllVisible());
  }

  void _enqueueAllVisible() {
    if (!mounted) return;
    final summaries =
        widget.data.patientsForSelection(widget.selection.selectedUnitIds);
    for (final s in summaries) {
      _scheduleLoad(s.patient.id);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Per phase-2b-fac-r-facility-reads.md L3 — 60s Census poll
    // driven by the AppShell-mounted PollingController. Subscribing
    // here (rather than initState) gives access to AppState's
    // InheritedWidget.
    final ctl = AppState.of(context).polling;
    if (ctl != _polling) {
      _polling?.censusTick.removeListener(_onPollTick);
      _polling?.stopCensusPolling();
      _polling = ctl;
      _polling!.censusTick.addListener(_onPollTick);
      _polling!.startCensusPolling();
    }
  }

  @override
  void dispose() {
    widget.selection.removeListener(_onSelectionChanged);
    widget.notifications.removeListener(_rebuild);
    _polling?.censusTick.removeListener(_onPollTick);
    _polling?.stopCensusPolling();
    _rowQueue.clear();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  void _onSelectionChanged() {
    _enqueueAllVisible();
    _rebuild();
  }

  /// Polling tick: refresh the cached `/me/patients` slice, then
  /// re-fetch stats for any previously-loaded rows. We can't rely on
  /// each row's [MaybeVisible.onFirstVisible] firing a second time —
  /// it's intentionally one-shot per detector instance. So the set
  /// of "rows we've seen at least once" is the right re-fetch
  /// universe; newly-appearing rows still go through the visibility
  /// callback as before.
  Future<void> _onPollTick() async {
    try {
      await widget.data.refreshCensus();
    } catch (_) {
      // Swallow transient errors; next tick retries. Loud diagnostics
      // live in the API client.
      return;
    }
    if (!mounted) return;
    setState(() {
      _loaded.clear();
      _inFlight.clear();
      _rowQueue.clear();
    });
    _enqueueAllVisible();
  }

  /// Enqueue a row's `rowStatsFor + notificationsForPatient` fetch
  /// via [_rowQueue] (capped at 5 concurrent per L5). Called from
  /// each row's `VisibilityDetector` callback when it first scrolls
  /// into view. The queue dedups concurrent enqueues for the same
  /// patientId.
  void _scheduleLoad(String patientId) {
    if (_loaded.containsKey(patientId) || _inFlight.contains(patientId)) {
      return;
    }
    _inFlight.add(patientId);
    _rowQueue.enqueue(patientId, () async {
      // Sequential awaits (not Future.wait) to keep the type inference
      // simple in release builds and to play nicely with the live
      // repo's in-flight Future dedup at the per-cache layer.
      final stats = await widget.data.rowStatsFor(patientId);
      final notifications =
          await notificationsForPatient(widget.data, patientId);
      return _RowData(stats: stats, computed: notifications);
    }).then((data) {
      if (!mounted) return;
      setState(() {
        _loaded[patientId] = data;
        _inFlight.remove(patientId);
      });
    }, onError: (Object e) {
      if (!mounted) return;
      setState(() {
        // Empty placeholder on error — UI doesn't hang; retry UX is
        // a later polish item.
        _loaded[patientId] = const _RowData.empty();
        _inFlight.remove(patientId);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final summaries =
        widget.data.patientsForSelection(widget.selection.selectedUnitIds);
    final rows = summaries.map((s) {
      final loaded = _loaded[s.patient.id];
      final computed = loaded?.computed ?? const <PatientNotification>[];
      final active = widget.notifications.activeOf(computed);
      return _CensusRow(summary: s, active: active);
    }).toList();

    final filtered = _applyFilter(rows, widget.selection.filterMode);
    _applySort(filtered, widget.selection.sortMode);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(10, 24, 10, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Header(
            totalShown: filtered.length,
            totalSelected: summaries.length,
            selection: widget.selection,
          ),
          const SizedBox(height: 18),
          if (filtered.isEmpty)
            _EmptyState(filterMode: widget.selection.filterMode)
          else if (widget.selection.viewMode == CensusViewMode.list)
            PatientListView(
              rows: filtered.map((r) {
                final id = r.summary.patient.id;
                final loaded = _loaded[id];
                return PatientListRow(
                  patient: r.summary.patient,
                  unitDisplay:
                      unitDisplayFor(widget.data, r.summary.patient.unitId),
                  stats: loaded?.stats ?? _placeholderStats,
                  activeNotifications: r.active,
                  isLoading: loaded == null,
                  onFirstVisible: () => _scheduleLoad(id),
                );
              }).toList(),
              selectedPatientId: widget.selection.selectedPatientId,
              onSelect: widget.selection.selectPatient,
            )
          else
            _Grid(
              rows: filtered,
              data: widget.data,
              selection: widget.selection,
              onRowVisible: _scheduleLoad,
            ),
        ],
      ),
    );
  }

  static List<_CensusRow> _applyFilter(
    List<_CensusRow> rows,
    CensusFilterMode mode,
  ) {
    switch (mode) {
      case CensusFilterMode.all:
        return rows;
      case CensusFilterMode.withNotifications:
        return rows.where((r) => r.active.isNotEmpty).toList();
      case CensusFilterMode.criticalOnly:
        return rows
            .where((r) => r.active
                .any((n) => n.severity == NotificationSeverity.critical))
            .toList();
      case CensusFilterMode.noNotifications:
        return rows.where((r) => r.active.isEmpty).toList();
    }
  }

  static void _applySort(List<_CensusRow> rows, CensusSortMode mode) {
    int byName(_CensusRow a, _CensusRow b) =>
        a.summary.patient.displayName.compareTo(b.summary.patient.displayName);

    int severityRank(_CensusRow r) {
      if (r.active.any((n) => n.severity == NotificationSeverity.critical)) {
        return 0;
      }
      if (r.active.isNotEmpty) return 1;
      return 2;
    }

    switch (mode) {
      case CensusSortMode.notificationsFirst:
        rows.sort((a, b) {
          final r = severityRank(a).compareTo(severityRank(b));
          return r != 0 ? r : byName(a, b);
        });
      case CensusSortMode.nameAZ:
        rows.sort(byName);
      case CensusSortMode.mostActive:
        rows.sort(
            (a, b) => b.summary.stepsToday.compareTo(a.summary.stepsToday));
      case CensusSortMode.leastActive:
        rows.sort(
            (a, b) => a.summary.stepsToday.compareTo(b.summary.stepsToday));
    }
  }
}

class _CensusRow {
  final PatientSummary summary;
  final List<PatientNotification> active;
  _CensusRow({required this.summary, required this.active});
}

class _Header extends StatelessWidget {
  const _Header({
    required this.totalShown,
    required this.totalSelected,
    required this.selection,
  });

  final int totalShown;
  final int totalSelected;
  final FacilitySelection selection;

  String _countLabel() {
    if (totalShown == totalSelected) {
      return totalShown == 1 ? '1 resident' : '$totalShown residents';
    }
    return '$totalShown of $totalSelected residents';
  }

  @override
  Widget build(BuildContext context) {
    final controls = Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      runSpacing: 12,
      spacing: 12,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              'Census',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontSize: 24,
                    fontWeight: FontWeight.w600,
                    height: 1.0,
                  ),
            ),
            const SizedBox(width: 12),
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text(
                _countLabel(),
                style: const TextStyle(
                  color: AppTheme.textSoft,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  height: 1.0,
                ),
              ),
            ),
          ],
        ),
        ViewModeToggle(
          selected: selection.viewMode,
          onChanged: selection.setViewMode,
        ),
        SimpleSelectDropdown<CensusSortMode>(
          label: 'Sort',
          icon: Icons.sort_rounded,
          options: CensusSortMode.values,
          value: selection.sortMode,
          optionLabel: (m) => m.label,
          onChanged: selection.setSortMode,
        ),
        SimpleSelectDropdown<CensusFilterMode>(
          label: 'Filter',
          icon: Icons.filter_list_rounded,
          options: CensusFilterMode.values,
          value: selection.filterMode,
          optionLabel: (m) => m.label,
          onChanged: selection.setFilterMode,
        ),
      ],
    );

    return LayoutBuilder(
      builder: (context, c) {
        // On wide layouts, pin the Add Resident button to the right edge
        // while the controls wrap on the left. On narrow phones, drop the
        // button onto its own row so the long text doesn't crowd Filter.
        final wide = c.maxWidth >= 720;
        if (wide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(child: controls),
              const SizedBox(width: 16),
              const _AddResidentButton(),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Align(
              alignment: Alignment.centerRight,
              child: _AddResidentButton(),
            ),
            const SizedBox(height: 14),
            controls,
          ],
        );
      },
    );
  }
}

class _AddResidentButton extends StatelessWidget {
  const _AddResidentButton();

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: () => AddResidentDialog.show(context),
      icon: const Icon(Icons.add_rounded, size: 18),
      label: const Text('Add Resident'),
      style: FilledButton.styleFrom(
        backgroundColor: AppTheme.sage,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(100)),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        elevation: 0,
      ),
    );
  }
}

class _Grid extends StatelessWidget {
  const _Grid({
    required this.rows,
    required this.data,
    required this.selection,
    required this.onRowVisible,
  });

  final List<_CensusRow> rows;
  final FacilityRepository data;
  final FacilitySelection selection;

  /// Fired once when each tile first scrolls into view. Wired by
  /// the Census view to enqueue the row's stats fetch through its
  /// [RowLoaderQueue] (L5).
  final void Function(String patientId) onRowVisible;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const tileMinWidth = 260.0;
        const gap = 14.0;
        final cols = ((constraints.maxWidth + gap) / (tileMinWidth + gap))
            .floor()
            .clamp(1, 5);
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final r in rows)
              SizedBox(
                width: (constraints.maxWidth - gap * (cols - 1)) / cols,
                child: MaybeVisible(
                  detectorKey:
                      ValueKey('tile-visibility-${r.summary.patient.id}'),
                  onFirstVisible: () => onRowVisible(r.summary.patient.id),
                  child: PatientTile(
                    summary: r.summary,
                    unitDisplay:
                        unitDisplayFor(data, r.summary.patient.unitId),
                    selected:
                        selection.selectedPatientId == r.summary.patient.id,
                    onTap: () => selection.selectPatient(r.summary.patient.id),
                    activeNotifications: r.active,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.filterMode});
  final CensusFilterMode filterMode;

  @override
  Widget build(BuildContext context) {
    final (icon, title, body) = switch (filterMode) {
      CensusFilterMode.all => (
          Icons.people_outline_rounded,
          'No units selected',
          'Choose at least one unit from the dropdown above\nto view residents.',
        ),
      CensusFilterMode.withNotifications => (
          Icons.check_circle_outline_rounded,
          'No notifications',
          'No residents in the current selection need review.',
        ),
      CensusFilterMode.criticalOnly => (
          Icons.check_circle_outline_rounded,
          'No critical alerts',
          'No residents in the current selection have critical notifications.',
        ),
      CensusFilterMode.noNotifications => (
          Icons.notifications_active_outlined,
          'All residents have notifications',
          'Every resident in the current selection currently has at least one\nnotification awaiting review.',
        ),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 64),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: AppTheme.textSoft.withOpacity(0.4)),
            const SizedBox(height: 14),
            Text(
              title,
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontSize: 17),
            ),
            const SizedBox(height: 6),
            Text(
              body,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppTheme.textSoft,
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
