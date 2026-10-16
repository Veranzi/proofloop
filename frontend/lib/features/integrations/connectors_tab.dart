import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/formatters.dart';
import '../../core/integration_models.dart';
import '../../core/integrations_repository.dart';
import '../../widgets/form_fields.dart';
import '../../widgets/status_chip.dart';
import 'integration_widgets.dart';

/// Sources documents can be pulled in from.
///
/// API: list (43), connect (44), disconnect (45). Credentials are sent once
/// to the API and kept in Secret Manager; they are never returned.
class ConnectorsTab extends StatefulWidget {
  const ConnectorsTab({super.key});

  @override
  State<ConnectorsTab> createState() => _ConnectorsTabState();
}

class _ConnectorsTabState extends State<ConnectorsTab> {
  final _repo = IntegrationsRepository.instance;

  Future<void> _connect(ConnectorKind kind) async {
    final Widget? dialog = switch (kind) {
      ConnectorKind.googleDrive ||
      ConnectorKind.sharePoint => _FolderDialog(kind: kind),
      ConnectorKind.odoo => const _OdooDialog(),
      ConnectorKind.emailInbox || ConnectorKind.sap => null,
    };
    // The email inbox needs no input: the API generates the address.
    final detail = dialog == null
        ? ''
        : await showDialog<String>(context: context, builder: (_) => dialog);
    if (detail == null || !mounted) return;
    final c = _repo.connect(kind, detail: detail);
    setState(() {});
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('${c.kind.label} connected')));
  }

  Future<void> _disconnect(Connector c) async {
    final ok = await confirmAction(
      context,
      title: 'Disconnect ${c.kind.label}?',
      message:
          'New documents will no longer be imported. Evidence already '
          'imported stays in its cases.',
      action: 'Disconnect',
    );
    if (ok) setState(() => _repo.disconnect(c.kind));
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const TabIntro(title: 'Document sources'),
        const InfoBanner(
          'Start with the email inbox: any system that can send email can '
          'deliver documents to PruFlo. Imported files go through the same '
          'checks and processing as manual uploads.',
        ),
        const SizedBox(height: 12),
        for (final c in _repo.connectors())
          _ConnectorRow(
            connector: c,
            onConnect: () => _connect(c.kind),
            onDisconnect: () => _disconnect(c),
          ),
      ],
    );
  }
}

class _ConnectorRow extends StatelessWidget {
  const _ConnectorRow({
    required this.connector,
    required this.onConnect,
    required this.onDisconnect,
  });

  final Connector connector;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;

  IconData get _icon => switch (connector.kind) {
    ConnectorKind.emailInbox => Icons.alternate_email,
    ConnectorKind.googleDrive => Icons.add_to_drive_outlined,
    ConnectorKind.sharePoint => Icons.folder_shared_outlined,
    ConnectorKind.odoo || ConnectorKind.sap => Icons.inventory_2_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final c = connector;
    final status = switch (c.status) {
      ConnectorStatus.connected => const Pill(
        'Connected',
        foreground: AppColors.success,
        background: AppColors.successSoft,
      ),
      ConnectorStatus.error => const Pill(
        'Error',
        foreground: AppColors.danger,
        background: AppColors.dangerSoft,
      ),
      ConnectorStatus.comingSoon => const Pill(
        'Coming soon',
        foreground: AppColors.textSecondary,
        background: AppColors.background,
      ),
      ConnectorStatus.notConnected => null,
    };

    final action = switch (c.status) {
      ConnectorStatus.connected => TextButton(
        style: TextButton.styleFrom(foregroundColor: AppColors.danger),
        onPressed: onDisconnect,
        child: const Text('Disconnect'),
      ),
      ConnectorStatus.comingSoon => null,
      _ => OutlinedButton(
        style: OutlinedButton.styleFrom(minimumSize: const Size(0, 38)),
        onPressed: onConnect,
        child: Text(c.kind == ConnectorKind.emailInbox ? 'Enable' : 'Connect'),
      ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 38,
            height: 38,
            margin: const EdgeInsets.only(right: 12),
            decoration: BoxDecoration(
              color: AppColors.primarySoft,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(_icon, size: 20, color: AppColors.primary),
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
                      c.kind.label,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    ?status,
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  c.kind.description,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
                if (c.status == ConnectorStatus.connected &&
                    c.detail.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  SelectableText(
                    c.detail,
                    style: const TextStyle(
                      fontSize: 12,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
                if (c.connectedAt != null)
                  Text(
                    'Connected ${timeAgo(c.connectedAt!)}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}

/// Drive and SharePoint: pick the folder, then the API sends the admin to
/// the provider's consent screen (read-only access to that folder).
class _FolderDialog extends StatefulWidget {
  const _FolderDialog({required this.kind});
  final ConnectorKind kind;

  @override
  State<_FolderDialog> createState() => _FolderDialogState();
}

class _FolderDialogState extends State<_FolderDialog> {
  final _formKey = GlobalKey<FormState>();
  final _folder = TextEditingController();

  @override
  void dispose() {
    _folder.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = widget.kind == ConnectorKind.googleDrive
        ? 'Google'
        : 'Microsoft';
    return AlertDialog(
      title: Text('Connect ${widget.kind.label}'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LabeledField(
                label: 'Folder link or path',
                hint: widget.kind == ConnectorKind.googleDrive
                    ? 'https://drive.google.com/drive/folders/...'
                    : 'https://contoso.sharepoint.com/sites/Finance/...',
                controller: _folder,
                validator: (v) => Validators.required(v, 'Folder'),
              ),
              const SizedBox(height: 10),
              Text(
                'You will be sent to $provider to approve read-only access to '
                'this folder. New files are imported every 15 minutes.',
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
          style: FilledButton.styleFrom(minimumSize: const Size(120, 44)),
          onPressed: () {
            if (!_formKey.currentState!.validate()) return;
            Navigator.of(context).pop(_folder.text.trim());
          },
          child: Text('Continue to $provider'),
        ),
      ],
    );
  }
}

class _OdooDialog extends StatefulWidget {
  const _OdooDialog();

  @override
  State<_OdooDialog> createState() => _OdooDialogState();
}

class _OdooDialogState extends State<_OdooDialog> {
  final _formKey = GlobalKey<FormState>();
  final _url = TextEditingController();
  final _db = TextEditingController();
  final _user = TextEditingController();
  final _key = TextEditingController();

  @override
  void dispose() {
    for (final c in [_url, _db, _user, _key]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Connect Odoo'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LabeledField(
                  label: 'Odoo URL',
                  hint: 'https://yourcompany.odoo.com',
                  controller: _url,
                  keyboardType: TextInputType.url,
                  validator: httpsUrl,
                ),
                const SizedBox(height: 12),
                LabeledField(
                  label: 'Database',
                  controller: _db,
                  validator: (v) => Validators.required(v, 'Database'),
                ),
                const SizedBox(height: 12),
                LabeledField(
                  label: 'Username',
                  controller: _user,
                  validator: (v) => Validators.required(v, 'Username'),
                ),
                const SizedBox(height: 12),
                LabeledField(
                  label: 'API key',
                  controller: _key,
                  obscure: true,
                  validator: (v) => Validators.required(v, 'API key'),
                ),
                const SizedBox(height: 10),
                const Text(
                  'Use an Odoo user with read-only access to Purchase, '
                  'Inventory and Accounting. The key is stored encrypted and '
                  'never shown again.',
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
          onPressed: () {
            if (!_formKey.currentState!.validate()) return;
            Navigator.of(context).pop(_url.text.trim());
          },
          child: const Text('Connect'),
        ),
      ],
    );
  }
}
