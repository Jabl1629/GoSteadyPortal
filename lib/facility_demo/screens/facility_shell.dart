import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../data/facility_mock_data.dart';
import '../state/facility_selection.dart';
import '../widgets/facility_top_bar.dart';
import 'patient_census_view.dart';
import 'patient_detail_view.dart';

/// Master-detail container for the facility demo. Top bar always visible.
/// Layout per spec §5.1 / §5.2:
/// - ≥1280px: side-by-side (census left, detail right)
/// - <1280px: census view by default; tile click swaps to detail with a back
///   button.
class FacilityShell extends StatefulWidget {
  const FacilityShell({super.key, required this.data});
  final FacilityMockData data;

  @override
  State<FacilityShell> createState() => _FacilityShellState();
}

class _FacilityShellState extends State<FacilityShell> {
  late final FacilitySelection _selection;

  @override
  void initState() {
    super.initState();
    _selection = FacilitySelection(widget.data);
  }

  @override
  void dispose() {
    _selection.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.warmWhite,
      body: SafeArea(
        child: Column(
          children: [
            FacilityTopBar(data: widget.data, selection: _selection),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  if (constraints.maxWidth >= 1280) {
                    return _WideSplit(
                      data: widget.data,
                      selection: _selection,
                      shellWidth: constraints.maxWidth,
                    );
                  }
                  return _NarrowSwap(
                    data: widget.data,
                    selection: _selection,
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WideSplit extends StatelessWidget {
  const _WideSplit({
    required this.data,
    required this.selection,
    required this.shellWidth,
  });

  final FacilityMockData data;
  final FacilitySelection selection;
  final double shellWidth;

  @override
  Widget build(BuildContext context) {
    // Census pane width: 30% of shell, clamped to [380, 520].
    final censusWidth = (shellWidth * 0.30).clamp(380.0, 520.0);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: censusWidth,
          child: PatientCensusView(data: data, selection: selection),
        ),
        VerticalDivider(
          width: 1,
          thickness: 1,
          color: AppTheme.border.withOpacity(0.6),
        ),
        Expanded(
          child: PatientDetailView(data: data, selection: selection),
        ),
      ],
    );
  }
}

class _NarrowSwap extends StatelessWidget {
  const _NarrowSwap({required this.data, required this.selection});
  final FacilityMockData data;
  final FacilitySelection selection;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: selection,
      builder: (context, _) {
        final showingPatient = selection.selectedPatientId != null;
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child: showingPatient
              ? PatientDetailView(
                  key: const ValueKey('detail'),
                  data: data,
                  selection: selection,
                  showBackButton: true,
                )
              : PatientCensusView(
                  key: const ValueKey('census'),
                  data: data,
                  selection: selection,
                ),
        );
      },
    );
  }
}
