import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_theme.dart';
import '../../data/facility_repository.dart';
import '../models/patient.dart';
import '../models/unit.dart';
import 'form_fields.dart';

/// Per-resident settings sheet. Opens from the gear icon in the detail
/// header. Cosmetic — every form submission closes the dialog and shows a
/// SnackBar; nothing in the seed list is mutated.
///
/// One Dialog instance, multiple "pages" swapped via `_View`. The X always
/// closes the whole dialog (back to detail view). The back arrow on a
/// sub-page returns to the menu.
class ResidentSettingsDialog extends StatefulWidget {
  const ResidentSettingsDialog({
    super.key,
    required this.patient,
    required this.data,
  });

  final Patient patient;
  final FacilityRepository data;

  static Future<void> show(
    BuildContext context, {
    required Patient patient,
    required FacilityRepository data,
  }) =>
      showDialog<void>(
        context: context,
        barrierColor: Colors.black.withOpacity(0.45),
        builder: (_) => ResidentSettingsDialog(patient: patient, data: data),
      );

  @override
  State<ResidentSettingsDialog> createState() =>
      _ResidentSettingsDialogState();
}

enum _View {
  menu,
  replaceDevice,
  discontinueDevice,
  editInfo,
  pauseMonitoring,
  dischargeResident,
}

class _ResidentSettingsDialogState extends State<ResidentSettingsDialog> {
  _View _view = _View.menu;

  void _goTo(_View v) => setState(() => _view = v);
  void _back() => _goTo(_View.menu);

  void _close() => Navigator.of(context).pop();

  void _toastAndClose(String message) {
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppTheme.sage,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  String _unitDisplay(String unitId) =>
      widget.data.allUnits().firstWhere((u) => u.id == unitId).displayName;

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.of(context).size.width >= 560;
    return Dialog(
      backgroundColor: AppTheme.warmWhite,
      insetPadding: EdgeInsets.symmetric(
        horizontal: isWide ? 40 : 16,
        vertical: 24,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: AnimatedSize(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          alignment: Alignment.topCenter,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(28, 24, 28, 20),
            child: _buildBody(),
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    switch (_view) {
      case _View.menu:
        return _MenuView(
          patient: widget.patient,
          unitDisplay: _unitDisplay(widget.patient.unitId),
          onSelect: _goTo,
          onClose: _close,
        );
      case _View.replaceDevice:
        return _ReplaceDeviceForm(
          patient: widget.patient,
          onBack: _back,
          onClose: _close,
          onSubmit: (newId) => _toastAndClose(
            'Device replaced — ${widget.patient.displayName} is now on $newId.',
          ),
        );
      case _View.discontinueDevice:
        return _DiscontinueDeviceConfirm(
          patient: widget.patient,
          onBack: _back,
          onClose: _close,
          onConfirm: () => _toastAndClose(
            'Device discontinued for ${widget.patient.displayName}.',
          ),
        );
      case _View.editInfo:
        return _EditInfoForm(
          patient: widget.patient,
          data: widget.data,
          onBack: _back,
          onClose: _close,
          onSubmit: (name) => _toastAndClose('Resident info updated for $name.'),
        );
      case _View.pauseMonitoring:
        return _PauseMonitoringForm(
          patient: widget.patient,
          onBack: _back,
          onClose: _close,
          onSubmit: (days) => _toastAndClose(
            'Monitoring paused for ${widget.patient.displayName} '
            'for $days day${days == 1 ? '' : 's'}.',
          ),
        );
      case _View.dischargeResident:
        return _DischargeForm(
          patient: widget.patient,
          onBack: _back,
          onClose: _close,
          onConfirm: () => _toastAndClose(
            '${widget.patient.displayName} discharged. '
            'Activity history preserved.',
          ),
        );
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Menu view
// ─────────────────────────────────────────────────────────────────────────

class _MenuView extends StatelessWidget {
  const _MenuView({
    required this.patient,
    required this.unitDisplay,
    required this.onSelect,
    required this.onClose,
  });

  final Patient patient;
  final String unitDisplay;
  final ValueChanged<_View> onSelect;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: AppTheme.sage.withOpacity(0.12),
                borderRadius: BorderRadius.circular(11),
              ),
              child: const Icon(
                Icons.settings_rounded,
                size: 20,
                color: AppTheme.sage,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Resident Settings',
                    style:
                        Theme.of(context).textTheme.headlineMedium?.copyWith(
                              fontSize: 20,
                              fontWeight: FontWeight.w600,
                              height: 1.0,
                            ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${patient.displayName}  ·  $unitDisplay  ·  Rm ${patient.room}',
                    style: const TextStyle(
                      color: AppTheme.textSoft,
                      fontSize: 13,
                    ),
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
        ),
        const SizedBox(height: 24),
        const _SectionLabel('Device'),
        const SizedBox(height: 4),
        _MenuRow(
          icon: Icons.sync_alt_rounded,
          label: 'Replace Device',
          subtitle: 'Swap in a new walker cap',
          onTap: () => onSelect(_View.replaceDevice),
        ),
        _MenuRow(
          icon: Icons.power_settings_new_rounded,
          label: 'Discontinue Device',
          subtitle: 'Unassign without discharging',
          destructive: true,
          onTap: () => onSelect(_View.discontinueDevice),
        ),
        const SizedBox(height: 18),
        const _SectionLabel('Resident'),
        const SizedBox(height: 4),
        _MenuRow(
          icon: Icons.edit_outlined,
          label: 'Edit Resident Info',
          subtitle: 'Name, unit, room',
          onTap: () => onSelect(_View.editInfo),
        ),
        _MenuRow(
          icon: Icons.notifications_paused_outlined,
          label: 'Pause Monitoring',
          subtitle: 'Mute alerts for N days',
          onTap: () => onSelect(_View.pauseMonitoring),
        ),
        _MenuRow(
          icon: Icons.logout_rounded,
          label: 'Discharge Resident',
          subtitle: 'End monitoring; preserves history',
          destructive: true,
          onTap: () => onSelect(_View.dischargeResident),
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
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.0,
        ),
      ),
    );
  }
}

class _MenuRow extends StatefulWidget {
  const _MenuRow({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.onTap,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final String subtitle;
  final VoidCallback onTap;
  final bool destructive;

  @override
  State<_MenuRow> createState() => _MenuRowState();
}

class _MenuRowState extends State<_MenuRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final accent =
        widget.destructive ? AppTheme.statusAlert : AppTheme.textDark;
    final iconColor =
        widget.destructive ? AppTheme.statusAlert : AppTheme.sage;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            color: _hover ? AppTheme.cream : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: iconColor.withOpacity(0.10),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(widget.icon, color: iconColor, size: 17),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.label,
                      style: TextStyle(
                        color: accent,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        height: 1.1,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.subtitle,
                      style: const TextStyle(
                        color: AppTheme.textSoft,
                        fontSize: 12,
                        height: 1.2,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: AppTheme.textSoft.withOpacity(0.7),
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Shared sub-view chrome
// ─────────────────────────────────────────────────────────────────────────

class _SubViewHeader extends StatelessWidget {
  const _SubViewHeader({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onBack,
    required this.onClose,
    this.iconColor = AppTheme.sage,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onBack;
  final VoidCallback onClose;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _BackToMenuLink(onTap: onBack),
        const SizedBox(height: 14),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: iconColor.withOpacity(0.12),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(icon, size: 20, color: iconColor),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style:
                        Theme.of(context).textTheme.headlineMedium?.copyWith(
                              fontSize: 20,
                              fontWeight: FontWeight.w600,
                              height: 1.0,
                            ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      color: AppTheme.textSoft,
                      fontSize: 13,
                    ),
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
        ),
      ],
    );
  }
}

class _BackToMenuLink extends StatelessWidget {
  const _BackToMenuLink({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: const Padding(
          padding: EdgeInsets.symmetric(vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.arrow_back_rounded, color: AppTheme.sage, size: 16),
              SizedBox(width: 4),
              Text(
                'Settings',
                style: TextStyle(
                  color: AppTheme.sage,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DialogActions extends StatelessWidget {
  const _DialogActions({
    required this.onCancel,
    required this.onAction,
    this.cancelLabel = 'Cancel',
    required this.actionLabel,
    this.destructive = false,
  });

  final VoidCallback onCancel;
  final VoidCallback onAction;
  final String cancelLabel;
  final String actionLabel;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final actionColor = destructive ? AppTheme.statusAlert : AppTheme.sage;
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        TextButton(
          onPressed: onCancel,
          style: TextButton.styleFrom(
            foregroundColor: AppTheme.textSoft,
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          ),
          child: Text(
            cancelLabel,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: onAction,
          style: FilledButton.styleFrom(
            backgroundColor: actionColor,
            foregroundColor: Colors.white,
            padding:
                const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(100),
            ),
            textStyle: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
            elevation: 0,
          ),
          child: Text(actionLabel),
        ),
      ],
    );
  }
}

class _CurrentValueChip extends StatelessWidget {
  const _CurrentValueChip({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppTheme.cream,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.border.withOpacity(0.6)),
      ),
      child: Row(
        children: [
          Text(
            label,
            style: const TextStyle(
              color: AppTheme.textSoft,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: AppTheme.textDark,
                fontSize: 14,
                fontWeight: FontWeight.w600,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WarningBox extends StatelessWidget {
  const _WarningBox({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.statusAlert.withOpacity(0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.statusAlert.withOpacity(0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.info_outline_rounded,
            color: AppTheme.statusAlert,
            size: 18,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: AppTheme.textDark.withOpacity(0.85),
                fontSize: 13,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String? _requiredText(String? v) =>
    (v == null || v.trim().isEmpty) ? 'Required' : null;

// ─────────────────────────────────────────────────────────────────────────
// Replace Device
// ─────────────────────────────────────────────────────────────────────────

class _ReplaceDeviceForm extends StatefulWidget {
  const _ReplaceDeviceForm({
    required this.patient,
    required this.onBack,
    required this.onClose,
    required this.onSubmit,
  });

  final Patient patient;
  final VoidCallback onBack;
  final VoidCallback onClose;
  final ValueChanged<String> onSubmit;

  @override
  State<_ReplaceDeviceForm> createState() => _ReplaceDeviceFormState();
}

class _ReplaceDeviceFormState extends State<_ReplaceDeviceForm> {
  final _formKey = GlobalKey<FormState>();
  final _newId = TextEditingController();
  String? _reason;

  static const _reasons = [
    'Damaged',
    'Battery worn',
    'Upgraded model',
    'Lost or misplaced',
    'Other',
  ];

  @override
  void dispose() {
    _newId.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    if (_reason == null) return;
    widget.onSubmit(_newId.text);
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SubViewHeader(
            icon: Icons.sync_alt_rounded,
            title: 'Replace Device',
            subtitle:
                'Assign a new walker cap to ${widget.patient.displayName}.',
            onBack: widget.onBack,
            onClose: widget.onClose,
          ),
          const SizedBox(height: 20),
          _CurrentValueChip(
            label: 'Current device',
            value: widget.patient.deviceSerial ?? '—',
          ),
          const SizedBox(height: 16),
          LabeledField(
            label: 'New device ID',
            controller: _newId,
            hint: '10-digit serial',
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(10),
            ],
            validator: (v) {
              if (v == null || v.isEmpty) return 'Required';
              if (v.length != 10) return 'Must be exactly 10 digits';
              return null;
            },
          ),
          const SizedBox(height: 14),
          LabeledDropdown<String>(
            label: 'Reason',
            hint: 'Select reason',
            value: _reason,
            options: _reasons,
            optionLabel: (s) => s,
            onChanged: (s) => setState(() => _reason = s),
            validator: (v) => v == null ? 'Required' : null,
          ),
          const SizedBox(height: 24),
          _DialogActions(
            onCancel: widget.onBack,
            cancelLabel: 'Cancel',
            actionLabel: 'Replace Device',
            onAction: _submit,
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Discontinue Device
// ─────────────────────────────────────────────────────────────────────────

class _DiscontinueDeviceConfirm extends StatelessWidget {
  const _DiscontinueDeviceConfirm({
    required this.patient,
    required this.onBack,
    required this.onClose,
    required this.onConfirm,
  });

  final Patient patient;
  final VoidCallback onBack;
  final VoidCallback onClose;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SubViewHeader(
          icon: Icons.power_settings_new_rounded,
          iconColor: AppTheme.statusAlert,
          title: 'Discontinue Device',
          subtitle: 'Unassign ${patient.displayName}\'s walker cap.',
          onBack: onBack,
          onClose: onClose,
        ),
        const SizedBox(height: 16),
        _WarningBox(
          text:
              'This will stop activity tracking and alerts from the device. '
              '${patient.displayName}\'s historical activity is preserved. '
              'You can assign a new device any time.',
        ),
        const SizedBox(height: 16),
        _CurrentValueChip(
          label: 'Currently assigned',
          value: patient.deviceSerial ?? '—',
        ),
        const SizedBox(height: 24),
        _DialogActions(
          onCancel: onBack,
          cancelLabel: 'Cancel',
          actionLabel: 'Discontinue',
          onAction: onConfirm,
          destructive: true,
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Edit Resident Info
// ─────────────────────────────────────────────────────────────────────────

class _EditInfoForm extends StatefulWidget {
  const _EditInfoForm({
    required this.patient,
    required this.data,
    required this.onBack,
    required this.onClose,
    required this.onSubmit,
  });

  final Patient patient;
  final FacilityRepository data;
  final VoidCallback onBack;
  final VoidCallback onClose;
  final ValueChanged<String> onSubmit;

  @override
  State<_EditInfoForm> createState() => _EditInfoFormState();
}

class _EditInfoFormState extends State<_EditInfoForm> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _room;
  late Unit _unit;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.patient.displayName);
    _room = TextEditingController(text: widget.patient.room);
    _unit = widget.data
        .allUnits()
        .firstWhere((u) => u.id == widget.patient.unitId);
  }

  @override
  void dispose() {
    _name.dispose();
    _room.dispose();
    super.dispose();
  }

  String _unitLabel(Unit u) {
    final fac = widget.data
        .allFacilities()
        .firstWhere((f) => f.id == u.facilityId);
    final short = fac.displayName.split(' ').first;
    return '$short — ${u.displayName}';
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    widget.onSubmit(_name.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SubViewHeader(
            icon: Icons.edit_outlined,
            title: 'Edit Resident Info',
            subtitle: 'Update name, unit, or room number.',
            onBack: widget.onBack,
            onClose: widget.onClose,
          ),
          const SizedBox(height: 20),
          LabeledField(
            label: 'Full name',
            controller: _name,
            textCapitalization: TextCapitalization.words,
            validator: _requiredText,
          ),
          const SizedBox(height: 14),
          LabeledDropdown<Unit>(
            label: 'Unit',
            value: _unit,
            options: widget.data.allUnits(),
            optionLabel: _unitLabel,
            onChanged: (u) => setState(() => _unit = u!),
            validator: (v) => v == null ? 'Required' : null,
          ),
          const SizedBox(height: 14),
          LabeledField(
            label: 'Room',
            controller: _room,
            validator: _requiredText,
          ),
          const SizedBox(height: 24),
          _DialogActions(
            onCancel: widget.onBack,
            cancelLabel: 'Cancel',
            actionLabel: 'Save Changes',
            onAction: _submit,
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Pause Monitoring
// ─────────────────────────────────────────────────────────────────────────

class _PauseMonitoringForm extends StatefulWidget {
  const _PauseMonitoringForm({
    required this.patient,
    required this.onBack,
    required this.onClose,
    required this.onSubmit,
  });

  final Patient patient;
  final VoidCallback onBack;
  final VoidCallback onClose;
  final ValueChanged<int> onSubmit;

  @override
  State<_PauseMonitoringForm> createState() => _PauseMonitoringFormState();
}

class _PauseMonitoringFormState extends State<_PauseMonitoringForm> {
  final _formKey = GlobalKey<FormState>();
  final _days = TextEditingController(text: '7');
  String? _reason;

  static const _reasons = [
    'In hospital',
    'At rehab elsewhere',
    'Family visit / off-site',
    'On vacation',
    'Other',
  ];

  @override
  void dispose() {
    _days.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    if (_reason == null) return;
    final n = int.tryParse(_days.text) ?? 0;
    widget.onSubmit(n);
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SubViewHeader(
            icon: Icons.notifications_paused_outlined,
            title: 'Pause Monitoring',
            subtitle:
                'Mute notifications and "no activity" alerts for a period.',
            onBack: widget.onBack,
            onClose: widget.onClose,
          ),
          const SizedBox(height: 16),
          const _WarningBox(
            text:
                'Activity tracking continues — only alerts are paused. Use this '
                'when the resident is off-site (hospital, family visit) so the '
                'team isn\'t paged about expected no-data days.',
          ),
          const SizedBox(height: 16),
          LabeledField(
            label: 'Pause for (days)',
            controller: _days,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(3),
            ],
            validator: (v) {
              if (v == null || v.isEmpty) return 'Required';
              final n = int.tryParse(v);
              if (n == null || n < 1) return 'Must be at least 1 day';
              if (n > 90) return 'Max 90 days';
              return null;
            },
          ),
          const SizedBox(height: 14),
          LabeledDropdown<String>(
            label: 'Reason',
            hint: 'Select reason',
            value: _reason,
            options: _reasons,
            optionLabel: (s) => s,
            onChanged: (s) => setState(() => _reason = s),
            validator: (v) => v == null ? 'Required' : null,
          ),
          const SizedBox(height: 24),
          _DialogActions(
            onCancel: widget.onBack,
            cancelLabel: 'Cancel',
            actionLabel: 'Pause Monitoring',
            onAction: _submit,
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Discharge Resident
// ─────────────────────────────────────────────────────────────────────────

class _DischargeForm extends StatefulWidget {
  const _DischargeForm({
    required this.patient,
    required this.onBack,
    required this.onClose,
    required this.onConfirm,
  });

  final Patient patient;
  final VoidCallback onBack;
  final VoidCallback onClose;
  final VoidCallback onConfirm;

  @override
  State<_DischargeForm> createState() => _DischargeFormState();
}

class _DischargeFormState extends State<_DischargeForm> {
  final _formKey = GlobalKey<FormState>();
  final _notes = TextEditingController();
  String? _reason;

  static const _reasons = [
    'Transferred to another facility',
    'Moved home',
    'Hospital admission (long-term)',
    'Deceased',
    'Other',
  ];

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    if (_reason == null) return;
    widget.onConfirm();
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SubViewHeader(
            icon: Icons.logout_rounded,
            iconColor: AppTheme.statusAlert,
            title: 'Discharge Resident',
            subtitle:
                'End monitoring for ${widget.patient.displayName}.',
            onBack: widget.onBack,
            onClose: widget.onClose,
          ),
          const SizedBox(height: 16),
          _WarningBox(
            text:
                'This archives ${widget.patient.displayName} from the active '
                'census and stops all monitoring. Activity history is preserved '
                'and remains exportable. To re-admit, contact support.',
          ),
          const SizedBox(height: 16),
          LabeledDropdown<String>(
            label: 'Reason for discharge',
            hint: 'Select reason',
            value: _reason,
            options: _reasons,
            optionLabel: (s) => s,
            onChanged: (s) => setState(() => _reason = s),
            validator: (v) => v == null ? 'Required' : null,
          ),
          const SizedBox(height: 14),
          LabeledField(
            label: 'Notes (optional)',
            controller: _notes,
            hint: 'Any additional context for the record',
            maxLines: 3,
            textCapitalization: TextCapitalization.sentences,
          ),
          const SizedBox(height: 24),
          _DialogActions(
            onCancel: widget.onBack,
            cancelLabel: 'Cancel',
            actionLabel: 'Discharge Resident',
            onAction: _submit,
            destructive: true,
          ),
        ],
      ),
    );
  }
}
