import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/integration_models.dart';
import '../../core/integrations_repository.dart';
import '../../widgets/form_fields.dart';
import 'integration_widgets.dart';

/// OCR and AI providers plus the processing region.
///
/// API: read (48), save (49). Provider credentials are configured on the
/// server; this screen only chooses between the ones the backend supports.
class ProvidersTab extends StatefulWidget {
  const ProvidersTab({super.key});

  @override
  State<ProvidersTab> createState() => _ProvidersTabState();
}

class _ProvidersTabState extends State<ProvidersTab> {
  final _repo = IntegrationsRepository.instance;
  final _formKey = GlobalKey<FormState>();
  late ProviderSettings _saved = _repo.providers();
  late OcrProvider _ocr = _saved.ocr;
  late AiProvider _ai = _saved.ai;
  late String _region = _saved.region;
  late final _model = TextEditingController(text: _saved.model);

  @override
  void dispose() {
    _model.dispose();
    super.dispose();
  }

  bool get _dirty =>
      _ocr != _saved.ocr ||
      _ai != _saved.ai ||
      _region != _saved.region ||
      _model.text.trim() != _saved.model;

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    final settings = ProviderSettings(
      ocr: _ocr,
      ai: _ai,
      model: _model.text.trim(),
      region: _region,
    );
    _repo.saveProviders(settings);
    setState(() => _saved = settings);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Saved. New evidence will use these settings.'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const TabIntro(title: 'Processing providers'),
          const InfoBanner(
            'Choose which services read documents and extract claims. '
            'Changes apply to evidence processed after saving; every claim '
            'records the provider and model version that produced it.',
          ),
          const SizedBox(height: 16),
          const _Label('Text recognition (OCR)'),
          DropdownButtonFormField<OcrProvider>(
            initialValue: _ocr,
            isExpanded: true,
            items: [
              for (final p in OcrProvider.values)
                DropdownMenuItem(value: p, child: Text(p.label)),
            ],
            onChanged: (v) => setState(() => _ocr = v!),
          ),
          const SizedBox(height: 16),
          const _Label('AI extraction and explanations'),
          DropdownButtonFormField<AiProvider>(
            initialValue: _ai,
            isExpanded: true,
            items: [
              for (final p in AiProvider.values)
                DropdownMenuItem(value: p, child: Text(p.label)),
            ],
            onChanged: (v) => setState(() => _ai = v!),
          ),
          const SizedBox(height: 16),
          LabeledField(
            label: 'Model ID',
            hint: 'e.g. gemini-2.5-flash',
            controller: _model,
            validator: (v) => Validators.required(v, 'Model ID'),
          ),
          const SizedBox(height: 16),
          const _Label('Processing region'),
          DropdownButtonFormField<String>(
            initialValue: _region,
            isExpanded: true,
            items: [
              for (final r in IntegrationsRepository.regions)
                DropdownMenuItem(value: r.id, child: Text(r.label)),
            ],
            onChanged: (v) => setState(() => _region = v!),
          ),
          const SizedBox(height: 12),
          const InfoBanner(
            'Documents are stored and processed in this region. Check that '
            'the chosen OCR processor and model are offered there before '
            'switching.',
            warning: true,
          ),
          const SizedBox(height: 20),
          Align(
            alignment: Alignment.centerLeft,
            child: ListenableBuilder(
              listenable: _model,
              builder: (context, _) => FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size(160, 44)),
                onPressed: _dirty ? _save : null,
                child: const Text('Save Changes'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w500,
          color: AppColors.textPrimary,
        ),
      ),
    );
  }
}
