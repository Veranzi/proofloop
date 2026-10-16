import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/formatters.dart';
import '../../core/integration_models.dart';
import '../../core/integrations_repository.dart';
import '../../widgets/form_fields.dart';
import '../../widgets/status_chip.dart';
import 'integration_widgets.dart';

/// Webhook endpoints PruFlo notifies when case events happen.
///
/// API: list (37), create (38), pause/resume (39), delete (40),
/// send test (41), delivery log (42).
class WebhooksTab extends StatefulWidget {
  const WebhooksTab({super.key});

  @override
  State<WebhooksTab> createState() => _WebhooksTabState();
}

class _WebhooksTabState extends State<WebhooksTab> {
  final _repo = IntegrationsRepository.instance;

  Future<void> _add() async {
    final result = await showDialog<(String, String, Set<WebhookEvent>)>(
      context: context,
      builder: (_) => const _AddWebhookDialog(),
    );
    if (result == null || !mounted) return;
    final (url, description, events) = result;
    final (_, secret) = _repo.createWebhook(
      url: url,
      description: description,
      events: events,
    );
    setState(() {});
    await showSecretOnce(
      context,
      title: 'Webhook added',
      secret: secret,
      note:
          'Use this signing secret to check the X-Pruflo-Signature header '
          'on every request, so the receiver knows it came from PruFlo.',
    );
  }

  void _test(WebhookEndpoint w) {
    final d = _repo.sendTestEvent(w.id);
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Test event sent: HTTP ${d.statusCode}')),
    );
  }

  Future<void> _delete(WebhookEndpoint w) async {
    final ok = await confirmAction(
      context,
      title: 'Delete webhook?',
      message: '${w.url} will stop receiving events.',
      action: 'Delete',
    );
    if (ok) setState(() => _repo.deleteWebhook(w.id));
  }

  @override
  Widget build(BuildContext context) {
    final hooks = _repo.webhooks();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        TabIntro(
          title: 'Webhooks',
          action: FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
            onPressed: _add,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add endpoint'),
          ),
        ),
        const InfoBanner(
          'PruFlo sends a signed POST to these URLs when something happens, '
          'so other systems do not have to keep checking. Failed deliveries '
          'are retried with increasing delays for up to 24 hours.',
        ),
        const SizedBox(height: 12),
        if (hooks.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'No webhook endpoints yet.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ),
        for (final w in hooks)
          Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              w.url,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                fontFamily: 'monospace',
                              ),
                            ),
                            if (w.description.isNotEmpty)
                              Text(
                                w.description,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: AppColors.textSecondary,
                                ),
                              ),
                          ],
                        ),
                      ),
                      Switch(
                        value: w.active,
                        onChanged: (v) =>
                            setState(() => _repo.setWebhookActive(w.id, v)),
                      ),
                      PopupMenuButton<String>(
                        tooltip: 'Webhook actions',
                        icon: const Icon(Icons.more_vert, size: 18),
                        onSelected: (v) => v == 'test' ? _test(w) : _delete(w),
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            value: 'test',
                            enabled: w.active,
                            child: const Text('Send test event'),
                          ),
                          const PopupMenuItem(
                            value: 'delete',
                            child: Text('Delete'),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TagList(w.events.map((e) => e.wire)),
                  if (w.deliveries.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    const Text(
                      'Recent deliveries',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    for (final d in w.deliveries.take(5))
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Row(
                          children: [
                            d.succeeded
                                ? Pill(
                                    '${d.statusCode}',
                                    foreground: AppColors.success,
                                    background: AppColors.successSoft,
                                  )
                                : Pill(
                                    d.statusCode == 0
                                        ? 'Failed'
                                        : '${d.statusCode}',
                                    foreground: AppColors.danger,
                                    background: AppColors.dangerSoft,
                                  ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                d.event.wire +
                                    (d.attempt > 1
                                        ? ' · attempt ${d.attempt}'
                                        : ''),
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontFamily: 'monospace',
                                ),
                              ),
                            ),
                            Text(
                              timeAgo(d.at),
                              style: const TextStyle(
                                fontSize: 12,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _AddWebhookDialog extends StatefulWidget {
  const _AddWebhookDialog();

  @override
  State<_AddWebhookDialog> createState() => _AddWebhookDialogState();
}

class _AddWebhookDialogState extends State<_AddWebhookDialog> {
  final _formKey = GlobalKey<FormState>();
  final _url = TextEditingController();
  final _description = TextEditingController();
  final _events = <WebhookEvent>{
    WebhookEvent.caseReviewRequired,
    WebhookEvent.caseReviewed,
  };
  bool _showEventError = false;

  @override
  void dispose() {
    _url.dispose();
    _description.dispose();
    super.dispose();
  }

  void _submit() {
    final valid = _formKey.currentState!.validate();
    setState(() => _showEventError = _events.isEmpty);
    if (!valid || _events.isEmpty) return;
    Navigator.of(context)
        .pop((_url.text.trim(), _description.text.trim(), Set.of(_events)));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add webhook endpoint'),
      content: SizedBox(
        width: 460,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LabeledField(
                  label: 'Endpoint URL',
                  hint: 'https://example.com/hooks/pruflo',
                  controller: _url,
                  keyboardType: TextInputType.url,
                  validator: httpsUrl,
                ),
                const SizedBox(height: 14),
                LabeledField(
                  label: 'Description (optional)',
                  controller: _description,
                ),
                const SizedBox(height: 14),
                const Text(
                  'Events to send',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                ),
                for (final e in WebhookEvent.values)
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: _events.contains(e),
                    title: Text(e.label),
                    subtitle: Text(
                      e.wire,
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                    onChanged: (v) =>
                        setState(() => v! ? _events.add(e) : _events.remove(e)),
                  ),
                if (_showEventError)
                  const Text(
                    'Select at least one event',
                    style: TextStyle(fontSize: 12, color: AppColors.danger),
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
          child: const Text('Add endpoint'),
        ),
      ],
    );
  }
}
