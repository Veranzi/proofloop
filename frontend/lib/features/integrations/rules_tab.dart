import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/integration_models.dart';
import '../../core/integrations_repository.dart';
import '../../widgets/form_fields.dart';
import 'integration_widgets.dart';

/// Reconciliation rules for this organisation: which ones run and their
/// parameters. The calculations themselves live in backend code.
///
/// API: list (46), update (47).
class RulesTab extends StatefulWidget {
  const RulesTab({super.key});

  @override
  State<RulesTab> createState() => _RulesTabState();
}

class _RulesTabState extends State<RulesTab> {
  final _repo = IntegrationsRepository.instance;

  Future<void> _edit(ReconciliationRule rule) async {
    final params = await showDialog<List<RuleParam>>(
      context: context,
      builder: (_) => _EditRuleDialog(rule: rule),
    );
    if (params == null || !mounted) return;
    final unchanged = [
      for (var i = 0; i < params.length; i++)
        params[i].value == rule.params[i].value,
    ].every((same) => same);
    if (unchanged) return;
    final updated = rule.copyWith(params: params);
    setState(() => _repo.updateRule(updated));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${rule.name} saved as version ${updated.version}'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const TabIntro(title: 'Reconciliation rules'),
        const InfoBanner(
          'Rules are calculated in code, never by AI. Changing a parameter '
          'creates a new version; findings already made keep the version '
          'that produced them, so they can be reproduced.',
        ),
        const SizedBox(height: 12),
        for (final r in _repo.rules())
          Container(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: AppColors.border)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${r.name}  ·  v${r.version}',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        r.description,
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 6),
                      TagList([
                        r.template,
                        for (final p in r.params)
                          '${p.key} = ${p.value}${p.suffix.isEmpty ? '' : ' ${p.suffix}'}',
                      ]),
                    ],
                  ),
                ),
                if (r.params.isNotEmpty)
                  IconButton(
                    tooltip: 'Edit parameters',
                    icon: const Icon(Icons.tune, size: 18),
                    onPressed: () => _edit(r),
                  ),
                Switch(
                  value: r.enabled,
                  onChanged: (v) =>
                      setState(() => _repo.updateRule(r.copyWith(enabled: v))),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _EditRuleDialog extends StatefulWidget {
  const _EditRuleDialog({required this.rule});
  final ReconciliationRule rule;

  @override
  State<_EditRuleDialog> createState() => _EditRuleDialogState();
}

class _EditRuleDialogState extends State<_EditRuleDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _controllers = [
    for (final p in widget.rule.params) TextEditingController(text: p.value),
  ];

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  static String? _nonNegativeNumber(String? v) {
    final n = num.tryParse(v?.trim() ?? '');
    if (n == null) return 'Enter a number';
    if (n < 0) return 'Cannot be negative';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final params = widget.rule.params;
    return AlertDialog(
      title: Text(widget.rule.name),
      content: SizedBox(
        width: 380,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < params.length; i++) ...[
                LabeledField(
                  label: params[i].suffix.isEmpty
                      ? params[i].label
                      : '${params[i].label} (${params[i].suffix})',
                  controller: _controllers[i],
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  validator: _nonNegativeNumber,
                ),
                const SizedBox(height: 12),
              ],
              Text(
                'Saving creates version ${widget.rule.version + 1}. It applies '
                'to evidence processed from now on.',
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondary,
                ),
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
          style: FilledButton.styleFrom(minimumSize: const Size(100, 44)),
          onPressed: () {
            if (!_formKey.currentState!.validate()) return;
            Navigator.of(context).pop([
              for (var i = 0; i < params.length; i++)
                params[i].withValue(_controllers[i].text.trim()),
            ]);
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
