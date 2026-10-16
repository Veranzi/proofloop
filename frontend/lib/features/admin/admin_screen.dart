import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/api.dart';
import '../../core/auth_service.dart';
import '../../core/integration_models.dart';
import '../../core/integrations_api.dart';
import '../../core/models.dart';
import '../../widgets/async_view.dart';
import '../../widgets/form_fields.dart';
import '../../widgets/page_header.dart';
import '../../widgets/status_chip.dart';
import '../integrations/integration_widgets.dart';
import 'admin_audit_tab.dart';
import 'admin_customers_tab.dart';

/// Admin console: users, customers, audit log, roles and system settings.
///
/// API (all under /v1/admin, admin role required): list users (24),
/// invite (25), change role or disable (26), remove (27), customers (28–30),
/// audit log (33).
class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key});

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  final _api = PrufloApi();
  late Future<List<OrgUser>> _users = _api.users();

  void _reload() => setState(() {
        _users = _api.users();
      });

  Future<void> _addUser() async {
    final user = await showDialog<OrgUser>(
      context: context,
      builder: (_) => const _AddUserDialog(),
    );
    if (user == null || !mounted) return;
    _reload();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
          'Invited ${user.email}. They can sign in with this email address.'),
    ));
  }

  /// Role and status changes; the API refuses to remove the last active admin.
  Future<void> _update(Future<void> Function() call) async {
    try {
      await call();
      _reload();
      // Your own role may have changed.
      await AuthService.instance.refresh();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _remove(OrgUser u) async {
    final ok = await confirmAction(
      context,
      title: 'Remove ${u.displayName}?',
      message: 'They lose access to this organisation and its cases. '
          'Their past actions stay in the audit trail.',
      action: 'Remove',
    );
    if (ok) await _update(() => _api.removeUser(u.id));
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Admin',
            subtitle: 'Manage users, roles and system settings',
            action: FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
              onPressed: _addUser,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add User'),
            ),
          ),
          SectionCard(
            padding: EdgeInsets.zero,
            child: DefaultTabController(
              length: 5,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const TabBar(
                    isScrollable: true,
                    tabAlignment: TabAlignment.start,
                    tabs: [
                      Tab(text: 'Users'),
                      Tab(text: 'Customers'),
                      Tab(text: 'Audit log'),
                      Tab(text: 'Roles'),
                      Tab(text: 'System'),
                    ],
                  ),
                  const Divider(height: 1),
                  SizedBox(
                    height: 480,
                    child: TabBarView(
                      children: [
                        AsyncView<List<OrgUser>>(
                          future: _users,
                          onRetry: _reload,
                          builder: (context, users) => _UsersTab(
                            users: users,
                            onRole: (u, role) => _update(
                                () => _api.updateUser(u.id, role: role)),
                            onToggleActive: (u) => _update(() =>
                                _api.updateUser(u.id, active: !u.active)),
                            onRemove: _remove,
                          ),
                        ),
                        const AdminCustomersTab(),
                        const AdminAuditTab(),
                        const _RolesTab(),
                        const _SystemTab(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _UsersTab extends StatelessWidget {
  const _UsersTab({
    required this.users,
    required this.onRole,
    required this.onToggleActive,
    required this.onRemove,
  });

  final List<OrgUser> users;
  final void Function(OrgUser, UserRole) onRole;
  final void Function(OrgUser) onToggleActive;
  final void Function(OrgUser) onRemove;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    const header = TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: AppColors.textSecondary);

    if (users.isEmpty) {
      return const EmptyPanel(
        icon: Icons.group_outlined,
        title: 'No users yet',
        message: 'Use Add User to invite people to this organisation.',
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (wide)
          Container(
            color: AppColors.background,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: const Row(
              children: [
                Expanded(flex: 4, child: Text('Name', style: header)),
                Expanded(flex: 4, child: Text('Email', style: header)),
                Expanded(flex: 2, child: Text('Role', style: header)),
                Expanded(flex: 2, child: Text('Status', style: header)),
                SizedBox(width: 48, child: Text('Actions', style: header)),
              ],
            ),
          ),
        for (final u in users)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: AppColors.border)),
            ),
            child: Row(
              children: [
                Expanded(
                  flex: 4,
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 16,
                        backgroundColor: AppColors.primarySoft,
                        child: Text(u.initials,
                            style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: AppColors.primary)),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(u.displayName,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500)),
                            if (!wide)
                              Text('${u.email} · ${roleLabel(u.role)}',
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 12,
                                      color: AppColors.textSecondary)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                if (wide)
                  Expanded(
                    flex: 4,
                    child: Text(u.email,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13)),
                  ),
                if (wide)
                  Expanded(
                    flex: 2,
                    child: Text(roleLabel(u.role),
                        style: const TextStyle(fontSize: 13)),
                  ),
                Expanded(
                  flex: 2,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: !u.active
                        ? const Pill('Inactive',
                            foreground: AppColors.danger,
                            background: AppColors.dangerSoft)
                        : u.signedIn
                            ? const Pill('Active',
                                foreground: AppColors.success,
                                background: AppColors.successSoft)
                            : const Pill('Invited',
                                foreground: AppColors.warning,
                                background: AppColors.warningSoft),
                  ),
                ),
                SizedBox(
                  width: 48,
                  child: PopupMenuButton<Object>(
                    tooltip: 'User actions',
                    icon: const Icon(Icons.more_vert, size: 18),
                    onSelected: (v) => switch (v) {
                      UserRole r => onRole(u, r),
                      'toggle' => onToggleActive(u),
                      _ => onRemove(u),
                    },
                    itemBuilder: (_) => [
                      for (final r in UserRole.values)
                        CheckedPopupMenuItem<Object>(
                          value: r,
                          checked: u.role == r,
                          child: Text('Role: ${roleLabel(r)}'),
                        ),
                      const PopupMenuDivider(),
                      PopupMenuItem<Object>(
                        value: 'toggle',
                        child: Text(u.active ? 'Deactivate' : 'Activate'),
                      ),
                      const PopupMenuItem<Object>(
                        value: 'remove',
                        child: Text('Remove from organisation'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _RolesTab extends StatelessWidget {
  const _RolesTab();

  @override
  Widget build(BuildContext context) {
    // Matches the permission table in Docs/backend_plan.md, which the API enforces.
    const roles = [
      ('Investigator',
          'Creates and edits cases, uploads evidence, generates reports and exports.'),
      ('Reviewer',
          'Approves, rejects or marks findings pending, and generates reports.'),
      ('Admin',
          'Everything above for every case in the organisation, plus users, '
              'integrations and settings.'),
      ('Viewer', 'Read-only access to the cases they are added to.'),
    ];
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        for (final (name, description) in roles)
          ListTile(
            leading:
                const Icon(Icons.shield_outlined, color: AppColors.primary),
            title: Text(name),
            subtitle: Text(description),
          ),
      ],
    );
  }
}

class _SystemTab extends StatefulWidget {
  const _SystemTab();

  @override
  State<_SystemTab> createState() => _SystemTabState();
}

class _SystemTabState extends State<_SystemTab> {
  final _api = IntegrationsApi();
  late Future<ProviderSettings> _future = _api.providers();

  @override
  Widget build(BuildContext context) {
    return AsyncView<ProviderSettings>(
      future: _future,
      onRetry: () => setState(() {
        _future = _api.providers();
      }),
      builder: (context, p) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
              title: const Text('Processing region'),
              subtitle: Text(regionLabel(p.region))),
          ListTile(
              title: const Text('OCR and AI'),
              subtitle: Text('${p.ocr.label} · ${p.ai.label} (${p.model})')),
          const ListTile(
              title: Text('Audit log'),
              subtitle: Text('All admin and review actions are recorded')),
        ],
      ),
    );
  }
}

class _AddUserDialog extends StatefulWidget {
  const _AddUserDialog();

  @override
  State<_AddUserDialog> createState() => _AddUserDialogState();
}

class _AddUserDialogState extends State<_AddUserDialog> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  UserRole _role = UserRole.investigator;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    super.dispose();
  }

  Future<void> _invite() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final user = await PrufloApi().inviteUser(
        email: _email.text.trim(),
        name: _name.text.trim(),
        role: _role,
      );
      if (mounted) Navigator.of(context).pop(user);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add User'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LabeledField(
                label: 'Full name',
                controller: _name,
                validator: (v) => Validators.required(v, 'Full name'),
              ),
              const SizedBox(height: 14),
              LabeledField(
                label: 'Email address',
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                validator: Validators.email,
              ),
              const SizedBox(height: 14),
              const Text('Role',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
              const SizedBox(height: 6),
              DropdownButtonFormField<UserRole>(
                initialValue: _role,
                items: [
                  for (final r in UserRole.values)
                    DropdownMenuItem(value: r, child: Text(roleLabel(r))),
                ],
                onChanged: (v) => setState(() => _role = v!),
              ),
              const SizedBox(height: 10),
              const Text(
                'No email is sent. Tell them to sign in to Pruflo with this '
                'email address.',
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!,
                    style:
                        const TextStyle(fontSize: 13, color: AppColors.danger)),
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
          onPressed: _busy ? null : _invite,
          child: Text(_busy ? 'Inviting…' : 'Invite'),
        ),
      ],
    );
  }
}
