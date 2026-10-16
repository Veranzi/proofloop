import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/api.dart';
import '../../core/formatters.dart';
import '../../core/models.dart';
import '../../widgets/async_view.dart';

/// Everything that happened in the organisation, newest first
/// (GET /v1/admin/audit, 33). The audit trail is append-only.
class AdminAuditTab extends StatefulWidget {
  const AdminAuditTab({super.key});

  /// Common actions for the filter; '' means all.
  static const actions = <(String, String)>[
    ('', 'All actions'),
    ('case.created', 'Case created'),
    ('case.updated', 'Case updated'),
    ('case.status_changed', 'Case status changed'),
    ('case.members_changed', 'Case members changed'),
    ('evidence.uploaded', 'Evidence uploaded'),
    ('evidence.processed', 'Evidence processed'),
    ('evidence.failed', 'Evidence failed'),
    ('finding.decided', 'Finding decided'),
    ('report.requested', 'Report requested'),
    ('report.downloaded', 'Report downloaded'),
    ('case.exported', 'Findings exported'),
    ('user.invited', 'User invited'),
    ('user.updated', 'User updated'),
    ('user.removed', 'User removed'),
    ('customer.created', 'Customer created'),
    ('api_key.created', 'API key created'),
    ('api_key.revoked', 'API key revoked'),
    ('webhook.created', 'Webhook created'),
  ];

  @override
  State<AdminAuditTab> createState() => _AdminAuditTabState();
}

class _AdminAuditTabState extends State<AdminAuditTab> {
  final _api = PrufloApi();
  final _items = <AuditEntry>[];
  String _action = '';
  String? _cursor;
  bool _loading = true;
  bool _loadingMore = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await _api.audit(action: _action);
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(page.items);
        _cursor = page.nextCursor;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _more() async {
    setState(() => _loadingMore = true);
    try {
      final page = await _api.audit(action: _action, cursor: _cursor);
      if (!mounted) return;
      setState(() {
        _items.addAll(page.items);
        _cursor = page.nextCursor;
      });
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final filter = Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: [
          const Text('Show', style: TextStyle(fontSize: 13)),
          const SizedBox(width: 12),
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 280),
              child: DropdownButtonFormField<String>(
                initialValue: _action,
                isExpanded: true,
                items: [
                  for (final (value, label) in AdminAuditTab.actions)
                    DropdownMenuItem(value: value, child: Text(label)),
                ],
                onChanged: (v) {
                  _action = v ?? '';
                  _load();
                },
              ),
            ),
          ),
        ],
      ),
    );

    Widget body;
    if (_loading) {
      body = const Padding(
        padding: EdgeInsets.all(32),
        child: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
        ),
      );
    } else if (_error != null) {
      body = ErrorPanel(message: '$_error', onRetry: _load);
    } else if (_items.isEmpty) {
      body = const EmptyPanel(
        icon: Icons.history,
        title: 'Nothing recorded yet',
        message: 'Changes to cases, users and settings appear here.',
      );
    } else {
      body = Column(
        children: [
          for (final e in _items) ...[_AuditRow(e), const Divider(height: 1)],
          if (_cursor != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: TextButton(
                onPressed: _loadingMore ? null : _more,
                child: Text(_loadingMore ? 'Loading…' : 'Load more'),
              ),
            ),
        ],
      );
    }

    return ListView(children: [filter, const Divider(height: 1), body]);
  }
}

class _AuditRow extends StatelessWidget {
  const _AuditRow(this.e);
  final AuditEntry e;

  @override
  Widget build(BuildContext context) {
    final title = e.details['title'];
    final caseId = e.caseId;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.history, size: 18, color: AppColors.textSecondary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  e.actionLabel,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (title is String && title.isNotEmpty)
                  Text(title, style: const TextStyle(fontSize: 13)),
                const SizedBox(height: 2),
                Text(
                  '${e.actorLabel} · ${formatDateTime(e.at)} · '
                  '${e.targetType} ${e.targetId}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          if (caseId != null)
            TextButton(
              onPressed: () => context.go('/cases/$caseId'),
              child: const Text('Open case'),
            ),
        ],
      ),
    );
  }
}
