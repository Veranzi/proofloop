import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/api.dart';
import '../../core/models.dart';
import '../../widgets/form_fields.dart';

/// Creates a case (POST /v1/cases) and returns it, or null if cancelled.
Future<CaseItem?> showNewCaseDialog(BuildContext context) {
  return showDialog<CaseItem>(
    context: context,
    builder: (_) => const _NewCaseDialog(),
  );
}

class _NewCaseDialog extends StatefulWidget {
  const _NewCaseDialog();

  @override
  State<_NewCaseDialog> createState() => _NewCaseDialogState();
}

class _NewCaseDialogState extends State<_NewCaseDialog> {
  final _formKey = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _category = TextEditingController();
  final _description = TextEditingController();
  Priority _priority = Priority.medium;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    _category.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final item = await PrufloApi().createCase(
        title: _title.text.trim(),
        category: _category.text.trim(),
        description: _description.text.trim(),
        priority: _priority,
      );
      if (mounted) Navigator.of(context).pop(item);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New Case'),
      content: SizedBox(
        width: 440,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LabeledField(
                label: 'Title',
                hint: 'e.g. Supplier delivery check',
                controller: _title,
                validator: (v) => Validators.required(v, 'Title'),
              ),
              const SizedBox(height: 14),
              LabeledField(
                label: 'Category',
                hint: 'e.g. Fraud, Legal, HR',
                controller: _category,
              ),
              const SizedBox(height: 14),
              LabeledField(
                label: 'Description',
                hint: 'What needs to be verified?',
                controller: _description,
                maxLines: 3,
              ),
              const SizedBox(height: 14),
              const Text('Priority',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
              const SizedBox(height: 6),
              SegmentedButton<Priority>(
                segments: const [
                  ButtonSegment(value: Priority.low, label: Text('Low')),
                  ButtonSegment(value: Priority.medium, label: Text('Medium')),
                  ButtonSegment(value: Priority.high, label: Text('High')),
                ],
                selected: {_priority},
                onSelectionChanged: (s) => setState(() => _priority = s.first),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!,
                    style:
                        const TextStyle(color: AppColors.danger, fontSize: 13)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(120, 44)),
          onPressed: _busy ? null : _create,
          child: Text(_busy ? 'Creating…' : 'Create Case'),
        ),
      ],
    );
  }
}
