import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_theme.dart';

/// Shared form chrome used by AddResidentDialog and ResidentSettingsDialog.
/// Match the demo's pill / cream-fill palette so admin forms feel like part
/// of the product, not a generic Material form.

class FieldLabel extends StatelessWidget {
  const FieldLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: AppTheme.textDark,
        fontSize: 13,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

class LabeledField extends StatelessWidget {
  const LabeledField({
    super.key,
    required this.label,
    required this.controller,
    this.hint,
    this.keyboardType,
    this.inputFormatters,
    this.validator,
    this.textCapitalization = TextCapitalization.none,
    this.maxLines = 1,
  });

  final String label;
  final TextEditingController controller;
  final String? hint;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final String? Function(String?)? validator;
  final TextCapitalization textCapitalization;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FieldLabel(label),
        const SizedBox(height: 6),
        TextFormField(
          controller: controller,
          keyboardType: keyboardType,
          inputFormatters: inputFormatters,
          validator: validator,
          textCapitalization: textCapitalization,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          maxLines: maxLines,
          style: const TextStyle(fontSize: 14, color: AppTheme.textDark),
          decoration: formInputDecoration(hint: hint, enabled: true),
        ),
      ],
    );
  }
}

class LabeledDropdown<T> extends StatelessWidget {
  const LabeledDropdown({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.optionLabel,
    required this.onChanged,
    this.hint,
    this.validator,
    this.enabled = true,
  });

  final String label;
  final T? value;
  final List<T> options;
  final String Function(T) optionLabel;
  final ValueChanged<T?>? onChanged;
  final String? hint;
  final String? Function(T?)? validator;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FieldLabel(label),
        const SizedBox(height: 6),
        DropdownButtonFormField<T>(
          value: value,
          items: options
              .map(
                (o) => DropdownMenuItem(
                  value: o,
                  child: Text(
                    optionLabel(o),
                    style:
                        const TextStyle(fontSize: 14, color: AppTheme.textDark),
                  ),
                ),
              )
              .toList(),
          onChanged: enabled ? onChanged : null,
          validator: validator,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          icon: Icon(
            Icons.keyboard_arrow_down_rounded,
            size: 20,
            color: enabled
                ? AppTheme.textSoft
                : AppTheme.textSoft.withOpacity(0.4),
          ),
          isDense: true,
          dropdownColor: Colors.white,
          borderRadius: BorderRadius.circular(12),
          decoration: formInputDecoration(hint: hint, enabled: enabled),
        ),
      ],
    );
  }
}

InputDecoration formInputDecoration({String? hint, required bool enabled}) {
  const errorColor = Color(0xFFB85C4F);
  OutlineInputBorder border(Color color, {double width = 1}) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: color, width: width),
      );
  return InputDecoration(
    hintText: hint,
    hintStyle: TextStyle(
      color: AppTheme.textSoft.withOpacity(0.7),
      fontSize: 14,
    ),
    isDense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    filled: true,
    fillColor: enabled ? AppTheme.cream : AppTheme.cream.withOpacity(0.5),
    border: border(AppTheme.border.withOpacity(0.6)),
    enabledBorder: border(AppTheme.border.withOpacity(0.6)),
    focusedBorder: border(AppTheme.sage, width: 1.5),
    errorBorder: border(errorColor),
    focusedErrorBorder: border(errorColor, width: 1.5),
    errorStyle: const TextStyle(
      color: errorColor,
      fontSize: 12,
      fontWeight: FontWeight.w500,
    ),
  );
}
