import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// Single-select dropdown matching the FacilitySelectorDropdown pill style.
/// Generic over the option type so we can use it for sort, filter, and any
/// other small picker without rewriting the chrome.
class SimpleSelectDropdown<T> extends StatefulWidget {
  const SimpleSelectDropdown({
    super.key,
    required this.label,
    required this.options,
    required this.value,
    required this.optionLabel,
    required this.onChanged,
    this.icon,
  });

  /// Prefix shown on the trigger ("Sort", "Filter").
  final String label;
  final List<T> options;
  final T value;
  final String Function(T) optionLabel;
  final ValueChanged<T> onChanged;
  final IconData? icon;

  @override
  State<SimpleSelectDropdown<T>> createState() =>
      _SimpleSelectDropdownState<T>();
}

class _SimpleSelectDropdownState<T> extends State<SimpleSelectDropdown<T>> {
  final OverlayPortalController _portal = OverlayPortalController();
  final LayerLink _link = LayerLink();

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _link,
      child: OverlayPortal(
        controller: _portal,
        overlayChildBuilder: (_) => _buildOverlay(),
        child: _Trigger(
          label: widget.label,
          valueText: widget.optionLabel(widget.value),
          icon: widget.icon,
          onTap: _portal.toggle,
        ),
      ),
    );
  }

  Widget _buildOverlay() {
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _portal.hide,
          ),
        ),
        CompositedTransformFollower(
          link: _link,
          targetAnchor: Alignment.bottomLeft,
          followerAnchor: Alignment.topLeft,
          offset: const Offset(0, 8),
          child: Material(
            color: Colors.transparent,
            child: Container(
              constraints: const BoxConstraints(minWidth: 220),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
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
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final opt in widget.options)
                    _OptionRow(
                      label: widget.optionLabel(opt),
                      selected: opt == widget.value,
                      onTap: () {
                        widget.onChanged(opt);
                        _portal.hide();
                      },
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _Trigger extends StatefulWidget {
  const _Trigger({
    required this.label,
    required this.valueText,
    required this.onTap,
    this.icon,
  });

  final String label;
  final String valueText;
  final VoidCallback onTap;
  final IconData? icon;

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
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: _hover
                ? AppTheme.sage.withOpacity(0.06)
                : AppTheme.cream,
            borderRadius: BorderRadius.circular(100),
            border: Border.all(color: AppTheme.border.withOpacity(0.6)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.icon != null) ...[
                Icon(widget.icon, size: 14, color: AppTheme.textSoft),
                const SizedBox(width: 6),
              ],
              Text(
                '${widget.label}: ',
                style: const TextStyle(
                  color: AppTheme.textSoft,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
              Text(
                widget.valueText,
                style: const TextStyle(
                  color: AppTheme.textDark,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 16,
                color: AppTheme.textSoft,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OptionRow extends StatefulWidget {
  const _OptionRow({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_OptionRow> createState() => _OptionRowState();
}

class _OptionRowState extends State<_OptionRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          color: _hover ? AppTheme.cream : Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.label,
                  style: TextStyle(
                    color: AppTheme.textDark,
                    fontSize: 13,
                    fontWeight:
                        widget.selected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ),
              if (widget.selected)
                Icon(
                  Icons.check_rounded,
                  size: 16,
                  color: AppTheme.sage,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
