import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/mock_repository.dart';
import '../../core/models.dart';
import '../../widgets/form_fields.dart';
import '../../widgets/page_header.dart';
import '../../widgets/status_chip.dart';

/// Admin console: users, roles and system settings.
///
/// API (all under /v1/admin, admin role required): list users (24),
/// invite (25), change role or disable (27). Admins manage access but do
/// not see case evidence unless they are a member of that case.
class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key});

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  late final List<AppUser> _users =
      List.of(MockRepository.instance.users());

  Future<void> _addUser() async {
    final user = await showDialog<AppUser>(
      context: context,
      builder: (_) => const _AddUserDialog(),
    );
    if (user == null || !mounted) return;
    setState(() => _users.insert(0, user));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Invitation sent to ${user.email}')),
    );
  }

  void _replace(AppUser old, AppUser updated) {
    final i = _users.indexOf(old);
    if (i >= 0) setState(() => _users[i] = updated);
  }

  int get _activeAdmins =>
      _users.where((u) => u.role == UserRole.admin && u.active).length;

  void _setRole(AppUser u, UserRole role) {
    if (u.role == UserRole.admin && role != UserRole.admin && _activeAdmins == 1) {
      _lastAdminWarning();
      return;
    }
    _replace(u, _copy(u, role: role));
  }

  void _toggleActive(AppUser u) {
    if (u.active && u.role == UserRole.admin && _activeAdmins == 1) {
      _lastAdminWarning();
      return;
    }
    _replace(u, _copy(u, active: !u.active));
  }

  void _lastAdminWarning() {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('There must always be at least one active admin.'),
    ));
  }

  AppUser _copy(AppUser u, {UserRole? role, bool? active}) => AppUser(
        name: u.name,
        email: u.email,
        role: role ?? u.role,
        active: active ?? u.active,
        phone: u.phone,
        jobTitle: u.jobTitle,
      );

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
              length: 3,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const TabBar(
                    isScrollable: true,
                    tabAlignment: TabAlignment.start,
                    tabs: [
                      Tab(text: 'Users'),
                      Tab(text: 'Roles'),
                      Tab(text: 'System'),
                    ],
                  ),
                  const Divider(height: 1),
                  SizedBox(
                    height: 480,
                    child: TabBarView(
                      children: [
                        _UsersTab(
                          users: _users,
                          onRole: _setRole,
                          onToggleActive: _toggleActive,
                        ),
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
  });

  final List<AppUser> users;
  final void Function(AppUser, UserRole) onRole;
  final void Function(AppUser) onToggleActive;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    const header = TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: AppColors.textSecondary);

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
                            Text(u.name,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500)),
                            if (!wide)
                              Text(u.email,
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
                    child: u.active
                        ? const Pill('Active',
                            foreground: AppColors.success,
                            background: AppColors.successSoft)
                        : const Pill('Inactive',
                            foreground: AppColors.danger,
                            background: AppColors.dangerSoft),
                  ),
                ),
                SizedBox(
                  width: 48,
                  child: PopupMenuButton<Object>(
                    tooltip: 'User actions',
                    icon: const Icon(Icons.more_vert, size: 18),
                    onSelected: (v) => v is UserRole
                        ? onRole(u, v)
                        : onToggleActive(u),
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
    const roles = [
      ('Investigator', 'Creates cases and uploads evidence.'),
      ('Reviewer', 'Reviews findings and records the decision.'),
      ('Admin', 'Manages users, roles and case access. No case content by default.'),
      ('Viewer', 'Read-only access to assigned cases and reports.'),
    ];
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        for (final (name, description) in roles)
          ListTile(
            leading: const Icon(Icons.shield_outlined, color: AppColors.primary),
            title: Text(name),
            subtitle: Text(description),
          ),
      ],
    );
  }
}

class _SystemTab extends StatelessWidget {
  const _SystemTab();

  @override
  Widget build(BuildContext context) {
    const settings = [
      ('Region', 'Singapore (asia-southeast1)'),
      ('Evidence retention', 'Set by the retention policy'),
      ('Audit log', 'All admin and review actions are recorded'),
    ];
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        for (final (label, value) in settings)
          ListTile(title: Text(label), subtitle: Text(value)),
      ],
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

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    super.dispose();
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
                'They will get an email invitation to set up their account.',
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
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
            Navigator.of(context).pop(AppUser(
              name: _name.text.trim(),
              email: _email.text.trim(),
              role: _role,
            ));
          },
          child: const Text('Send Invite'),
        ),
      ],
    );
  }
}
