import 'package:flutter/material.dart';

import '../app/theme.dart';

/// Text field with the small label above it, as in the mockups.
class LabeledField extends StatelessWidget {
  const LabeledField({
    super.key,
    required this.label,
    this.controller,
    this.hint,
    this.validator,
    this.keyboardType,
    this.obscure = false,
    this.suffix,
    this.maxLines = 1,
    this.readOnly = false,
    this.textInputAction,
    this.onSubmitted,
  });

  final String label;
  final TextEditingController? controller;
  final String? hint;
  final String? Function(String?)? validator;
  final TextInputType? keyboardType;
  final bool obscure;
  final Widget? suffix;
  final int maxLines;
  final bool readOnly;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: AppColors.textPrimary)),
        const SizedBox(height: 6),
        TextFormField(
          controller: controller,
          validator: validator,
          keyboardType: keyboardType,
          obscureText: obscure,
          maxLines: maxLines,
          readOnly: readOnly,
          textInputAction: textInputAction,
          onFieldSubmitted: onSubmitted,
          decoration: InputDecoration(hintText: hint, suffixIcon: suffix),
        ),
      ],
    );
  }
}

/// Password field with a show/hide toggle.
class PasswordField extends StatefulWidget {
  const PasswordField({
    super.key,
    required this.label,
    required this.controller,
    this.validator,
    this.textInputAction,
    this.onSubmitted,
  });

  final String label;
  final TextEditingController controller;
  final String? Function(String?)? validator;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;

  @override
  State<PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<PasswordField> {
  bool _hidden = true;

  @override
  Widget build(BuildContext context) {
    return LabeledField(
      label: widget.label,
      controller: widget.controller,
      validator: widget.validator,
      obscure: _hidden,
      hint: '••••••••••',
      textInputAction: widget.textInputAction,
      onSubmitted: widget.onSubmitted,
      suffix: IconButton(
        tooltip: _hidden ? 'Show password' : 'Hide password',
        icon: Icon(
          _hidden ? Icons.visibility_off_outlined : Icons.visibility_outlined,
          size: 18,
          color: AppColors.textSecondary,
        ),
        onPressed: () => setState(() => _hidden = !_hidden),
      ),
    );
  }
}

/// Shared validators for the auth forms.
class Validators {
  Validators._();

  static String? required(String? v, String field) =>
      (v == null || v.trim().isEmpty) ? '$field is required' : null;

  static String? email(String? v) {
    if (v == null || v.trim().isEmpty) return 'Email address is required';
    final ok = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(v.trim());
    return ok ? null : 'Enter a valid email address';
  }

  static String? password(String? v) {
    if (v == null || v.isEmpty) return 'Password is required';
    if (v.length < 8) return 'Use at least 8 characters';
    return null;
  }
}
