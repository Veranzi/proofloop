import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/api.dart';
import '../../core/models.dart';
import '../../widgets/async_view.dart';
import '../../widgets/status_chip.dart';

/// Who can see a case, for admins: list (31) and replace (32).
/// Non-admins only see cases they're members of.
class CaseMembersSection extends StatefulWidget {
  const CaseMembersSection({super.key, required this.caseId});
  final String caseId;

  @override
  State<CaseMembersSection> createState() => _CaseMembersSectionState();
}

class _CaseMembersSectionState extends State<CaseMembersSection> {
  final _api = PrufloApi();
  late Future<List<CaseMember>> _future = _api.caseMembers(widget.caseId);

  void _reload() => setState(() {
        _future = _api.caseMembers(widget.caseId);
      });

  Future<void> _manage(List<CaseMember> current) async {
    final saved = await showDialog<List<CaseMember>>(
      context: context,
      builder: (_) => ManageMembersDialog(
        caseId: widget.caseId,
        current: {for (final m in current) m.uid},
      ),
    );
    if (saved != null && mounted) {
      setState(() {
        _future = Future.value(saved);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Members',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        const Text(
          'Only members (and admins) can see this case.',
          style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
        ),
        const SizedBox(height: 8),
        AsyncView<List<CaseMember>>(
          future: _future,
          onRetry: _reload,
          compact: true,
          builder: (context, members) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (members.isEmpty)
                const Text(
                  'No members yet.',
                  style: TextStyle(color: AppColors.textSecondary),
                ),
              for (final m in members)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: const Icon(Icons.person_outline),
                  title: Text(m.displayName),
                  subtitle: Text('${m.email} · ${roleLabel(m.role)}'),
                ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 40),
                  ),
                  onPressed: () => _manage(members),
                  icon: const Icon(Icons.group_outlined, size: 18),
                  label: const Text('Manage members'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Tick who should be a member; saving replaces the whole list (32).
class ManageMembersDialog extends StatefulWidget {
  const ManageMembersDialog({
    super.key,
    required this.caseId,
    required this.current,
  });

  final String caseId;
  final Set<String> current;

  @override
  State<ManageMembersDialog> createState() => _ManageMembersDialogState();
}

class _ManageMembersDialogState extends State<ManageMembersDialog> {
  final _api = PrufloApi();
  late final Future<List<OrgUser>> _users = _api.users();
  late final Set<String> _selected = {...widget.current};
  bool _busy = false;
  String? _error;

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final saved = await _api.setCaseMembers(
        widget.caseId,
        _selected.toList()..sort(),
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
    return AlertDialog(
      title: const Text('Manage members'),
      content: SizedBox(
        width: 440,
        height: 380,
        child: FutureBuilder<List<OrgUser>>(
          future: _users,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(child: Text('${snapshot.error}'));
            }
            final users = snapshot.data;
            if (users == null) {
              return const Center(
                child: CircularProgressIndicator(strokeWidth: 2.5),
              );
            }
            final active = users.where((u) => u.active).toList();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: ListView(
                    children: [
                      for (final u in active)
                        CheckboxListTile(
                          value: _selected.contains(u.id),
                          onChanged: _busy
                              ? null
                              : (v) => setState(
                                  () => v == true
                                      ? _selected.add(u.id)
                                      : _selected.remove(u.id),
                                ),
                          title: Text(u.displayName),
                          subtitle: Text('${u.email} · ${roleLabel(u.role)}'),
                        ),
                    ],
                  ),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      _error!,
                      style: const TextStyle(
                        fontSize: 13,
                        color: AppColors.danger,
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(100, 44)),
          onPressed: _busy ? null : _save,
          child: Text(_busy ? 'Saving…' : 'Save'),
        ),
      ],
    );
  }
}
