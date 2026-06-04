import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../api/api_exception.dart';
import '../../data/facility_repository.dart';
import '../../theme/app_theme.dart';
import '../data/facility_seed.dart';
import '../models/facility.dart';
import '../models/patient.dart';
import '../models/unit.dart';
import 'form_fields.dart';

/// "Start Monitoring Again" — resumes a discontinued (discharged) resident
/// under the **same record** (history preserved). Modeled on
/// [AddResidentDialog], but the resident's name is fixed, and the unit/room
/// pre-fill from their last-known placement. A device is required (resume is
/// an atomic flip-to-active + re-provision). Submits via
/// [FacilityRepository.resumeMonitoring] — live impl hits
/// `POST /patients/{id}/resume`; demo impl synthesizes a response.
class ResumeMonitoringDialog extends StatefulWidget {
  const ResumeMonitoringDialog({
    super.key,
    required this.patient,
    required this.data,
    this.onCompleted,
  });

  /// The discontinued resident being resumed (same record).
  final Patient patient;

  /// Repository used to call `POST /patients/{id}/resume`.
  final FacilityRepository data;

  /// Optional callback after a successful resume. Patient detail uses this
  /// to reload — the record flips back to active, so the read-only state
  /// (chip + this button) clears and the settings gear returns.
  final VoidCallback? onCompleted;

  static Future<void> show(
    BuildContext context, {
    required Patient patient,
    required FacilityRepository data,
    VoidCallback? onCompleted,
  }) =>
      showDialog<void>(
        context: context,
        barrierColor: Colors.black.withOpacity(0.45),
        builder: (_) => ResumeMonitoringDialog(
          patient: patient,
          data: data,
          onCompleted: onCompleted,
        ),
      );

  @override
  State<ResumeMonitoringDialog> createState() => _ResumeMonitoringDialogState();
}

class _ResumeMonitoringDialogState extends State<ResumeMonitoringDialog> {
  final _formKey = GlobalKey<FormState>();
  final _deviceId = TextEditingController();
  late final TextEditingController _room;

  Facility? _facility;
  Unit? _unit;

  bool _submitting = false;
  String? _errorMessage;

  late final List<Facility> _facilities;

  @override
  void initState() {
    super.initState();
    final fromRepo = widget.data.allFacilities();
    _facilities = fromRepo.isNotEmpty ? fromRepo : FacilitySeed.facilities;

    // Pre-fill from the resident's last-known placement. Facility/unit only
    // pre-select if still present in the repo's options (a unit with no
    // active residents may be absent — then the user re-picks). Room always
    // pre-fills. Facility/Unit equality is by id (§C41 fix), so matching by
    // id is safe.
    _room = TextEditingController(text: widget.patient.room);
    _facility = _firstOrNull(_facilities, (f) => f.id == widget.patient.facilityId);
    if (_facility != null) {
      _unit = _firstOrNull(
        _unitsForFacility,
        (u) => u.id == widget.patient.unitId,
      );
    }
  }

  @override
  void dispose() {
    _deviceId.dispose();
    _room.dispose();
    super.dispose();
  }

  static T? _firstOrNull<T>(Iterable<T> items, bool Function(T) test) {
    for (final item in items) {
      if (test(item)) return item;
    }
    return null;
  }

  List<Unit> get _unitsForFacility {
    if (_facility == null) return const [];
    final fromRepo = widget.data.unitsForFacility(_facility!.id);
    if (fromRepo.isNotEmpty) return fromRepo;
    return FacilitySeed.units
        .where((u) => u.facilityId == _facility!.id)
        .toList();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_facility == null || _unit == null) return;

    final censusId = _unit!.id;
    final room = _room.text.trim();
    final rawSerial = _deviceId.text.trim();
    // Server expects the GS-prefixed serial; the form is a 10-digit input.
    final deviceSerial =
        rawSerial.startsWith('GS') ? rawSerial : 'GS$rawSerial';

    setState(() {
      _submitting = true;
      _errorMessage = null;
    });

    try {
      await widget.data.resumeMonitoring(
        patientId: widget.patient.id,
        censusId: censusId,
        room: room,
        deviceSerial: deviceSerial,
      );
      if (!mounted) return;
      widget.onCompleted?.call();
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '${widget.patient.displayName} — monitoring resumed in '
            '${_unit!.displayName} · Rm $room',
          ),
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppTheme.sage,
          duration: const Duration(seconds: 3),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e is ApiException
            ? '${e.code}: ${e.message}'
            : 'Could not resume monitoring: $e';
      });
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

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
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 20),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Header(
                  name: widget.patient.displayName,
                  onClose: () => Navigator.of(context).pop(),
                ),
                const SizedBox(height: 24),
                LabeledField(
                  label: 'Device ID',
                  controller: _deviceId,
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
                LabeledDropdown<Facility>(
                  label: 'Facility',
                  hint: 'Select facility',
                  value: _facility,
                  options: _facilities,
                  optionLabel: (f) => f.displayName,
                  onChanged: (f) => setState(() {
                    _facility = f;
                    _unit = null;
                  }),
                  validator: (v) => v == null ? 'Required' : null,
                ),
                const SizedBox(height: 14),
                LabeledDropdown<Unit>(
                  label: 'Unit',
                  hint: _facility == null
                      ? 'Choose a facility first'
                      : 'Select unit',
                  value: _unit,
                  options: _unitsForFacility,
                  optionLabel: (u) => u.displayName,
                  onChanged: _facility == null
                      ? null
                      : (u) => setState(() => _unit = u),
                  validator: (v) => v == null ? 'Required' : null,
                  enabled: _facility != null,
                ),
                const SizedBox(height: 14),
                LabeledField(
                  label: 'Room',
                  controller: _room,
                  hint: 'e.g. 203, 12A, R-4',
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'Required' : null,
                ),
                if (_errorMessage != null) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: AppTheme.statusAlert.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color: AppTheme.statusAlert.withOpacity(0.35)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.error_outline_rounded,
                            size: 16, color: AppTheme.statusAlert),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _errorMessage!,
                            style: TextStyle(
                              color: AppTheme.statusAlert,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: _submitting
                          ? null
                          : () => Navigator.of(context).pop(),
                      style: TextButton.styleFrom(
                        foregroundColor: AppTheme.textSoft,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 12),
                      ),
                      child: const Text(
                        'Cancel',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _submitting ? null : _submit,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTheme.sage,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(100),
                        ),
                        textStyle: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      child: _submitting
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor:
                                    AlwaysStoppedAnimation<Color>(Colors.white),
                              ),
                            )
                          : const Text('Resume Monitoring'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.name, required this.onClose});

  final String name;
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
          child: const Icon(
            Icons.restart_alt_rounded,
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
                'Start Monitoring Again',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      height: 1.0,
                    ),
              ),
              const SizedBox(height: 4),
              Text(
                'Resume monitoring for $name with a new device. '
                'Their activity history is preserved.',
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
          tooltip: 'Cancel',
          onPressed: onClose,
          style: IconButton.styleFrom(foregroundColor: AppTheme.textSoft),
        ),
      ],
    );
  }
}
