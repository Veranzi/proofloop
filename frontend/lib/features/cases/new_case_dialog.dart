import 'package:flutter/material.dart';

import '../../core/auth_service.dart';
import '../../core/mock_repository.dart';
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

  @override
  void dispose() {
    _title.dispose();
    _category.dispose();
    _description.dispose();
    super.dispose();
  }

  void _create() {
    if (!_formKey.currentState!.validate()) return;
    final item = MockRepository.instance.addCase(
      title: _title.text.trim(),
      category: _category.text.trim(),
      description: _description.text.trim(),
      priority: _priority,
      assignedTo: AuthService.instance.user?.name ?? '',
    );
    Navigator.of(context).pop(item);
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
                hint: 'e.g. Fraud Investigation',
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
          onPressed: _create,
          child: const Text('Create Case'),
        ),
      ],
    );
  }
}
