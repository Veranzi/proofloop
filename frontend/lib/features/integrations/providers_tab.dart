import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/integration_models.dart';
import '../../core/integrations_api.dart';
import '../../widgets/async_view.dart';
import 'integration_widgets.dart';

/// OCR and AI providers plus the processing region.
///
/// API: read (48), save (49). Provider credentials are configured on the
/// server; this screen only chooses between the ones the backend supports,
/// and the API refuses providers, models or regions it can't use.
class ProvidersTab extends StatefulWidget {
  const ProvidersTab({super.key});

  @override
  State<ProvidersTab> createState() => _ProvidersTabState();
}

class _ProvidersTabState extends State<ProvidersTab> {
  final _api = IntegrationsApi();
  late Future<ProviderSettings> _future = _api.providers();

  @override
  Widget build(BuildContext context) {
    return AsyncView<ProviderSettings>(
      future: _future,
      onRetry: () => setState(() { _future = _api.providers(); }),
      builder: (context, saved) => _ProvidersForm(
        key: ValueKey(saved),
        saved: saved,
        onSaved: (s) => setState(() { _future = Future.value(s); }),
      ),
    );
  }
}

class _ProvidersForm extends StatefulWidget {
  const _ProvidersForm({super.key, required this.saved, required this.onSaved});
  final ProviderSettings saved;
  final ValueChanged<ProviderSettings> onSaved;

  @override
  State<_ProvidersForm> createState() => _ProvidersFormState();
}

class _ProvidersFormState extends State<_ProvidersForm> {
  late OcrProvider _ocr = widget.saved.ocr;
  late AiProvider _ai = widget.saved.ai;
  late String _region = widget.saved.region;
  late String _model = widget.saved.model;
  bool _saving = false;

  ProviderSettings get _saved => widget.saved;

  bool get _dirty =>
      _ocr != _saved.ocr ||
      _ai != _saved.ai ||
      _region != _saved.region ||
      _model != _saved.model;

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final saved = await IntegrationsApi().saveProviders(ProviderSettings(
        ocr: _ocr,
        ai: _ai,
        model: _model,
        region: _region,
      ));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Saved. New evidence will use these settings.'),
      ));
      widget.onSaved(saved);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final models = {...allowedModels, _saved.model}.toList();
    final regions = [
      ...processingRegions,
      if (!processingRegions.any((r) => r.id == _saved.region))
        ProcessingRegion(_saved.region, _saved.region),
    ];
    return ListView(
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
        const _Label('Model'),
        DropdownButtonFormField<String>(
          initialValue: _model,
          isExpanded: true,
          items: [
            for (final m in models)
              DropdownMenuItem(
                  value: m,
                  child: Text(m, style: const TextStyle(fontFamily: 'monospace'))),
          ],
          onChanged: (v) => setState(() => _model = v!),
        ),
        const SizedBox(height: 16),
        const _Label('Processing region'),
        DropdownButtonFormField<String>(
          initialValue: _region,
          isExpanded: true,
          items: [
            for (final r in regions)
              DropdownMenuItem(value: r.id, child: Text(r.label)),
          ],
          onChanged: (v) => setState(() => _region = v!),
        ),
        const SizedBox(height: 12),
        const InfoBanner(
          'Documents are stored and processed in this region. Only Google '
          'Document AI and Gemini on Vertex AI are available today; the API '
          'refuses other providers until they are added.',
          warning: true,
        ),
        const SizedBox(height: 20),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(160, 44)),
            onPressed: _dirty && !_saving ? _save : null,
            child: Text(_saving ? 'Saving…' : 'Save Changes'),
          ),
        ),
      ],
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
