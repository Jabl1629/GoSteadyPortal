import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../data/facility_repository.dart';
import '../models/facility.dart';
import '../models/unit.dart';
import '../state/facility_selection.dart';

/// Top-bar trigger + anchored dropdown for selecting which facilities/units
/// drive the Patient Census view. Per spec §5.4: nested checkboxes,
/// indeterminate facility state, live filtering, no Apply button.
class FacilitySelectorDropdown extends StatefulWidget {
  const FacilitySelectorDropdown({
    super.key,
    required this.data,
    required this.selection,
  });

  final FacilityRepository data;
  final FacilitySelection selection;

  @override
  State<FacilitySelectorDropdown> createState() =>
      _FacilitySelectorDropdownState();
}

class _FacilitySelectorDropdownState extends State<FacilitySelectorDropdown> {
  final OverlayPortalController _portalCtrl = OverlayPortalController();
  final LayerLink _link = LayerLink();

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _link,
      child: OverlayPortal(
        controller: _portalCtrl,
        overlayChildBuilder: (_) => _buildOverlay(),
        child: ListenableBuilder(
          listenable: widget.selection,
          builder: (context, _) => _Trigger(
            label: widget.selection.selectorLabel(),
            onTap: () => _portalCtrl.toggle(),
          ),
        ),
      ),
    );
  }

  Widget _buildOverlay() {
    return Stack(
      children: [
        // Tap-outside dismiss layer.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _portalCtrl.hide,
          ),
        ),
        // Anchored panel.
        CompositedTransformFollower(
          link: _link,
          targetAnchor: Alignment.bottomLeft,
          followerAnchor: Alignment.topLeft,
          offset: const Offset(0, 8),
          child: Material(
            color: Colors.transparent,
            child: ListenableBuilder(
              listenable: widget.selection,
              builder: (context, _) => _Panel(
                data: widget.data,
                selection: widget.selection,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _Trigger extends StatefulWidget {
  const _Trigger({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  State<_Trigger> createState() => _TriggerState();
}

class _TriggerState extends State<_Trigger> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: _hover ? AppTheme.sage.withOpacity(0.06) : Colors.white,
            borderRadius: BorderRadius.circular(100),
            border: Border.all(
              color: AppTheme.border.withOpacity(0.7),
              width: 1,
            ),
            boxShadow: _hover ? null : AppTheme.cardShadow,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.business_rounded,
                size: 16,
                color: AppTheme.sage,
              ),
              const SizedBox(width: 8),
              Text(
                widget.label,
                style: const TextStyle(
                  color: AppTheme.textDark,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.1,
                ),
              ),
              const SizedBox(width: 6),
              Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 18,
                color: AppTheme.textSoft,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.data, required this.selection});

  final FacilityRepository data;
  final FacilitySelection selection;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 360,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.border.withOpacity(0.6)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x1A000000),
            blurRadius: 24,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _Header(selection: selection),
          const Divider(height: 1, color: AppTheme.border),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final f in data.allFacilities())
                  _FacilityBlock(
                    facility: f,
                    units: data.unitsForFacility(f.id),
                    data: data,
                    selection: selection,
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.selection});
  final FacilitySelection selection;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Row(
        children: [
          const Text(
            'Facilities & Units',
            style: TextStyle(
              color: AppTheme.textDark,
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
            ),
          ),
          const Spacer(),
          _LinkButton(label: 'Select all', onTap: selection.selectAll),
          const SizedBox(width: 8),
          _LinkButton(label: 'Clear all', onTap: selection.clearAll),
        ],
      ),
    );
  }
}

class _LinkButton extends StatelessWidget {
  const _LinkButton({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Text(
            label,
            style: const TextStyle(
              color: AppTheme.sage,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

class _FacilityBlock extends StatelessWidget {
  const _FacilityBlock({
    required this.facility,
    required this.units,
    required this.data,
    required this.selection,
  });

  final Facility facility;
  final List<Unit> units;
  final FacilityRepository data;
  final FacilitySelection selection;

  @override
  Widget build(BuildContext context) {
    final facilityState = selection.facilityCheckState(facility.id);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _CheckRow(
          label: facility.displayName,
          counter: '(${units.length} units)',
          state: facilityState,
          bold: true,
          onChanged: (checked) {
            selection.setFacilityChecked(facility.id, checked);
          },
        ),
        for (final unit in units)
          Padding(
            padding: const EdgeInsets.only(left: 28),
            child: _CheckRow(
              label: unit.displayName,
              counter: '(${_residentCountForUnit(unit.id)} res.)',
              state: selection.isUnitSelected(unit.id)
                  ? FacilityCheckState.all
                  : FacilityCheckState.none,
              onChanged: (checked) => selection.toggleUnit(unit.id),
            ),
          ),
        const SizedBox(height: 4),
      ],
    );
  }

  int _residentCountForUnit(String unitId) =>
      data.patientsForSelection({unitId}).length;
}

class _CheckRow extends StatefulWidget {
  const _CheckRow({
    required this.label,
    required this.counter,
    required this.state,
    required this.onChanged,
    this.bold = false,
  });

  final String label;
  final String counter;
  final FacilityCheckState state;
  final ValueChanged<bool> onChanged;
  final bool bold;

  @override
  State<_CheckRow> createState() => _CheckRowState();
}

class _CheckRowState extends State<_CheckRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: () => widget.onChanged(
          widget.state != FacilityCheckState.all,
        ),
        child: Container(
          color: _hover ? AppTheme.cream : Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              _Checkbox(state: widget.state),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  widget.label,
                  style: TextStyle(
                    color: AppTheme.textDark,
                    fontSize: 13,
                    fontWeight: widget.bold ? FontWeight.w600 : FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                widget.counter,
                style: const TextStyle(
                  color: AppTheme.textSoft,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Checkbox extends StatelessWidget {
  const _Checkbox({required this.state});
  final FacilityCheckState state;

  @override
  Widget build(BuildContext context) {
    final filled =
        state == FacilityCheckState.all || state == FacilityCheckState.partial;
    return Container(
      width: 18,
      height: 18,
      decoration: BoxDecoration(
        color: filled ? AppTheme.sage : Colors.white,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: filled ? AppTheme.sage : AppTheme.border,
          width: 1.5,
        ),
      ),
      child: state == FacilityCheckState.all
          ? const Icon(Icons.check_rounded, size: 14, color: Colors.white)
          : state == FacilityCheckState.partial
              ? const Icon(Icons.remove_rounded, size: 14, color: Colors.white)
              : null,
    );
  }
}
