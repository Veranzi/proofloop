import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/api.dart';
import '../../core/formatters.dart';
import '../../core/models.dart';
import '../../widgets/async_view.dart';
import '../../widgets/form_fields.dart';

/// Customers that cases can be filed under: list (28), add (29), edit (30).
class AdminCustomersTab extends StatefulWidget {
  const AdminCustomersTab({super.key});

  @override
  State<AdminCustomersTab> createState() => _AdminCustomersTabState();
}

class _AdminCustomersTabState extends State<AdminCustomersTab> {
  final _api = PrufloApi();
  final _items = <Customer>[];
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
      final page = await _api.adminCustomers();
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
      final page = await _api.adminCustomers(cursor: _cursor);
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

  Future<void> _edit([Customer? existing]) async {
    final saved = await showDialog<Customer>(
      context: context,
      builder: (_) => _CustomerDialog(existing: existing),
    );
    if (saved == null || !mounted) return;
    setState(() {
      final i = _items.indexWhere((c) => c.id == saved.id);
      if (i >= 0) {
        _items[i] = saved;
      } else {
        _items.insert(0, saved);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final addButton = Align(
      alignment: Alignment.centerRight,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: OutlinedButton.icon(
          style: OutlinedButton.styleFrom(minimumSize: const Size(0, 40)),
          onPressed: () => _edit(),
          icon: const Icon(Icons.add, size: 18),
          label: const Text('Add customer'),
        ),
      ),
    );
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
      );
    }
    if (_error != null) return ErrorPanel(message: '$_error', onRetry: _load);
    if (_items.isEmpty) {
      return Column(
        children: [
          addButton,
          const EmptyPanel(
            icon: Icons.storefront_outlined,
            title: 'No customers yet',
            message:
                'Add the customers your cases are about, then pick one '
                'when creating a case.',
          ),
        ],
      );
    }
    return ListView(
      children: [
        addButton,
        for (final c in _items) ...[
          ListTile(
            leading: const Icon(Icons.storefront_outlined),
            title: Text(c.name),
            subtitle: Text(
              [
                if (c.contactEmail.isNotEmpty) c.contactEmail,
                if (c.createdAt != null) 'Added ${timeAgo(c.createdAt!)}',
              ].join(' · '),
            ),
            trailing: IconButton(
              tooltip: 'Edit ${c.name}',
              icon: const Icon(Icons.edit_outlined, size: 20),
              onPressed: () => _edit(c),
            ),
          ),
          const Divider(height: 1),
        ],
        if (_cursor != null)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Center(
              child: TextButton(
                onPressed: _loadingMore ? null : _more,
                child: Text(_loadingMore ? 'Loading…' : 'Load more'),
              ),
            ),
          ),
      ],
    );
  }
}

class _CustomerDialog extends StatefulWidget {
  const _CustomerDialog({this.existing});
  final Customer? existing;

  @override
  State<_CustomerDialog> createState() => _CustomerDialogState();
}

class _CustomerDialogState extends State<_CustomerDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.existing?.name);
  late final _email = TextEditingController(
    text: widget.existing?.contactEmail,
  );
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final api = PrufloApi();
    try {
      final existing = widget.existing;
      final saved = existing == null
          ? await api.createCustomer(
              name: _name.text.trim(),
              contactEmail: _email.text.trim(),
            )
          : await api.updateCustomer(
              existing.id,
              name: _name.text.trim(),
              contactEmail: _email.text.trim(),
            );
      if (mounted) Navigator.of(context).pop(saved);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.existing != null;
    return AlertDialog(
      title: Text(editing ? 'Edit customer' : 'Add customer'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LabeledField(
                label: 'Name',
                controller: _name,
                validator: (v) => Validators.required(v, 'Name'),
              ),
              const SizedBox(height: 14),
              LabeledField(
                label: 'Contact email (optional)',
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? null
                    : Validators.email(v),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  style: const TextStyle(fontSize: 13, color: AppColors.danger),
                ),
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
          onPressed: _busy ? null : _save,
          child: Text(_busy ? 'Saving…' : 'Save'),
        ),
      ],
    );
  }
}
