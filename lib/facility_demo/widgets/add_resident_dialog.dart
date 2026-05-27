import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../api/api_exception.dart';
import '../../data/facility_repository.dart';
import '../../theme/app_theme.dart';
import '../data/facility_seed.dart';
import '../models/facility.dart';
import '../models/unit.dart';
import 'form_fields.dart';

/// "Add Resident" intake form. Submits via the FacilityRepository
/// per phase-2b-fac-w-facility-writes.md L2 — live impl hits
/// `POST /patients` (atomic with provisioning when a deviceSerial is
/// present); demo impl returns a synthesized response.
class AddResidentDialog extends StatefulWidget {
  const AddResidentDialog({super.key, required this.data, this.onCreated});

  /// Repository used to call `POST /patients`. Required for both
  /// builds (demo path is a no-op via FacilityMockData).
  final FacilityRepository data;

  /// Optional callback after a successful create. Census view uses
  /// this to refresh the patient list so the new resident appears.
  final VoidCallback? onCreated;

  static Future<void> show(
    BuildContext context, {
    required FacilityRepository data,
    VoidCallback? onCreated,
  }) =>
      showDialog<void>(
        context: context,
        barrierColor: Colors.black.withOpacity(0.45),
        builder: (_) => AddResidentDialog(data: data, onCreated: onCreated),
      );

  @override
  State<AddResidentDialog> createState() => _AddResidentDialogState();
}

class _AddResidentDialogState extends State<AddResidentDialog> {
  final _formKey = GlobalKey<FormState>();
  final _firstName = TextEditingController();
  final _lastName = TextEditingController();
  final _deviceId = TextEditingController();
  final _room = TextEditingController();

  Facility? _facility;
  Unit? _unit;

  bool _submitting = false;
  String? _errorMessage;

  late final List<Facility> _facilities;

  @override
  void initState() {
    super.initState();
    // Live impl: facilities/units derived from the cached
    // /me/patients response (per 2B-FAC-R L2). Demo impl: same data
    // shape via FacilityMockData. Either way, the seed fallback is
    // available if the repository returns empty (e.g. patient with
    // no scope — unlikely in practice).
    final fromRepo = widget.data.allFacilities();
    _facilities = fromRepo.isNotEmpty ? fromRepo : FacilitySeed.facilities;
  }

  @override
  void dispose() {
    _firstName.dispose();
    _lastName.dispose();
    _deviceId.dispose();
    _room.dispose();
    super.dispose();
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

    final fullName = '${_firstName.text.trim()} ${_lastName.text.trim()}';
    final censusId = _unit!.id;
    final room = _room.text.trim();
    final rawSerial = _deviceId.text.trim();
    // Per 2A-UM-P L3, server expects the GoSteady-prefixed serial.
    // The form is a 10-digit input; prepend "GS" if not already
    // present. Both forms are accepted by the server (it
    // canonicalizes), but be explicit.
    final deviceSerial = rawSerial.isEmpty
        ? null
        : (rawSerial.startsWith('GS') ? rawSerial : 'GS$rawSerial');

    setState(() {
      _submitting = true;
      _errorMessage = null;
    });

    try {
      await widget.data.createPatient(
        displayName: fullName,
        censusId: censusId,
        room: room,
        deviceSerial: deviceSerial,
      );
      if (!mounted) return;
      widget.onCreated?.call();
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop();
      messenger.showSnackBar(
        SnackBar(
          content:
              Text('$fullName registered in ${_unit!.displayName} · Rm $room'),
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
            : 'Could not add resident: $e';
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
                _Header(onClose: () => Navigator.of(context).pop()),
                const SizedBox(height: 24),
                LayoutBuilder(
                  builder: (context, c) {
                    final canRowName = c.maxWidth >= 360;
                    final first = LabeledField(
                      label: 'First name',
                      controller: _firstName,
                      hint: 'Margaret',
                      textCapitalization: TextCapitalization.words,
                      validator: _requiredText,
                    );
                    final last = LabeledField(
                      label: 'Last name',
                      controller: _lastName,
                      hint: 'O’Sullivan',
                      textCapitalization: TextCapitalization.words,
                      validator: _requiredText,
                    );
                    if (canRowName) {
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: first),
                          const SizedBox(width: 14),
                          Expanded(child: last),
                        ],
                      );
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [first, const SizedBox(height: 14), last],
                    );
                  },
                ),
                const SizedBox(height: 14),
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
                  validator: _requiredText,
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
                          : const Text('Add Resident'),
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

  static String? _requiredText(String? v) =>
      (v == null || v.trim().isEmpty) ? 'Required' : null;
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
          child: const Icon(
            Icons.person_add_alt_1_rounded,
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
                'Add Resident',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      height: 1.0,
                    ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Register a new resident and assign a device.',
                style: TextStyle(
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

