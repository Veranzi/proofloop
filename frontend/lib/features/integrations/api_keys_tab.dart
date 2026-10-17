import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/formatters.dart';
import '../../core/integration_models.dart';
import '../../core/integrations_api.dart';
import '../../widgets/async_view.dart';
import '../../widgets/form_fields.dart';
import '../../widgets/status_chip.dart';
import 'integration_widgets.dart';

/// API keys let other systems call the API without a person signing in.
///
/// API: list (34), create (35), revoke (36).
class ApiKeysTab extends StatefulWidget {
  const ApiKeysTab({super.key});

  @override
  State<ApiKeysTab> createState() => _ApiKeysTabState();
}

class _ApiKeysTabState extends State<ApiKeysTab> {
  final _api = IntegrationsApi();
  late Future<List<ApiKey>> _future = _api.apiKeys();

  void _reload() => setState(() { _future = _api.apiKeys(); });

  Future<void> _create() async {
    final result = await showDialog<(String, Set<ApiScope>)>(
      context: context,
      builder: (_) => const _CreateKeyDialog(),
    );
    if (result == null || !mounted) return;
    final (name, scopes) = result;
    final String secret;
    try {
      (_, secret) = await _api.createApiKey(name: name, scopes: scopes);
    } catch (e) {
      if (mounted) showError(context, e);
      return;
    }
    _reload();
    if (!mounted) return;
    await showSecretOnce(
      context,
      title: 'API key created',
      secret: secret,
      note:
          'Send it as "Authorization: Bearer <key>". Store it in the other '
          "system's secret store, never in source code.",
    );
  }

  Future<void> _revoke(ApiKey key) async {
    final ok = await confirmAction(
      context,
      title: 'Revoke "${key.name}"?',
      message:
          'Any system using this key will stop working straight away. '
          'This cannot be undone.',
      action: 'Revoke',
    );
    if (!ok) return;
    try {
      await _api.revokeApiKey(key.id);
      _reload();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AsyncView<List<ApiKey>>(
      future: _future,
      onRetry: _reload,
      builder: (context, keys) => _list(keys),
    );
  }

  Widget _list(List<ApiKey> keys) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        TabIntro(
          title: 'API keys',
          action: FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
            onPressed: _create,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Create key'),
          ),
        ),
        const InfoBanner(
          'Keys let another system, such as an ERP or a script, create cases, '
          'upload evidence and read findings without a person signing in. '
          'Give each system its own key with only the permissions it needs.',
        ),
        const SizedBox(height: 12),
        if (keys.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'No API keys yet.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ),
        for (final k in keys)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: AppColors.border)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 2, right: 12),
                  child: Icon(
                    Icons.key_outlined,
                    size: 20,
                    color: AppColors.textSecondary,
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            k.name,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          k.revoked
                              ? const Pill(
                                  'Revoked',
                                  foreground: AppColors.danger,
                                  background: AppColors.dangerSoft,
                                )
                              : const Pill(
                                  'Active',
                                  foreground: AppColors.success,
                                  background: AppColors.successSoft,
                                ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${k.prefix}••••••••',
                        style: const TextStyle(
                          fontSize: 12,
                          fontFamily: 'monospace',
                        ),
                      ),
                      const SizedBox(height: 6),
                      TagList(k.scopes.map((s) => s.wire)),
                      const SizedBox(height: 6),
                      Text(
                        '${k.createdBy.isEmpty ? 'Created' : 'Created by ${k.createdBy}'}'
                        ' · ${timeAgo(k.createdAt)}'
                        ' · ${k.lastUsedAt == null ? 'Never used' : 'Last used ${timeAgo(k.lastUsedAt!)}'}',
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                if (!k.revoked)
                  TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.danger,
                    ),
                    onPressed: () => _revoke(k),
                    child: const Text('Revoke'),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _CreateKeyDialog extends StatefulWidget {
  const _CreateKeyDialog();

  @override
  State<_CreateKeyDialog> createState() => _CreateKeyDialogState();
}

class _CreateKeyDialogState extends State<_CreateKeyDialog> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _scopes = <ApiScope>{ApiScope.casesRead, ApiScope.findingsRead};
  bool _showScopeError = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final valid = _formKey.currentState!.validate();
    setState(() => _showScopeError = _scopes.isEmpty);
    if (!valid || _scopes.isEmpty) return;
    Navigator.of(context).pop((_name.text.trim(), Set.of(_scopes)));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Create API key'),
      content: SizedBox(
        width: 440,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LabeledField(
                  label: 'Name',
                  hint: 'e.g. ERP sync job',
                  controller: _name,
                  validator: (v) => Validators.required(v, 'Name'),
                ),
                const SizedBox(height: 14),
                const Text(
                  'Permissions',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                ),
                for (final s in ApiScope.values)
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: _scopes.contains(s),
                    title: Text(s.label),
                    subtitle: Text(
                      s.wire,
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                    onChanged: (v) =>
                        setState(() => v! ? _scopes.add(s) : _scopes.remove(s)),
                  ),
                if (_showScopeError)
                  const Text(
                    'Select at least one permission',
                    style: TextStyle(fontSize: 12, color: AppColors.danger),
                  ),
                const SizedBox(height: 8),
                const Text(
                  'Keys can never review or decide findings. Only a signed-in '
                  'reviewer can do that.',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
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
          onPressed: _submit,
          child: const Text('Create key'),
        ),
      ],
    );
  }
}
