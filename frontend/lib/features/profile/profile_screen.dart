import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/api.dart';
import '../../core/auth_service.dart';
import '../../core/models.dart';
import '../../widgets/form_fields.dart';
import '../../widgets/page_header.dart';
import '../../widgets/status_chip.dart';

/// Account settings. API: GET/PATCH /v1/me (1, 21). Email and role are
/// managed by an admin; passwords go through Firebase Auth directly.
class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PageHeader(
            title: 'Profile Settings',
            subtitle: 'Manage your account information and preferences',
          ),
          SectionCard(
            padding: EdgeInsets.zero,
            child: DefaultTabController(
              length: 2,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: const [
                  TabBar(
                    isScrollable: true,
                    tabAlignment: TabAlignment.start,
                    tabs: [
                      Tab(text: 'Personal Info'),
                      Tab(text: 'Security'),
                    ],
                  ),
                  Divider(height: 1),
                  SizedBox(
                    height: 520,
                    child: TabBarView(
                      children: [
                        _PersonalInfoTab(),
                        _SecurityTab(),
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

class _PersonalInfoTab extends StatefulWidget {
  const _PersonalInfoTab();

  @override
  State<_PersonalInfoTab> createState() => _PersonalInfoTabState();
}

class _PersonalInfoTabState extends State<_PersonalInfoTab> {
  final _formKey = GlobalKey<FormState>();
  late final AppUser _user;
  late final TextEditingController _name;
  late final TextEditingController _email;
  late final TextEditingController _phone;
  late final TextEditingController _job;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _user = AuthService.instance.user!;
    _name = TextEditingController(text: _user.name);
    _email = TextEditingController(text: _user.email);
    _phone = TextEditingController(text: _user.phone);
    _job = TextEditingController(text: _user.jobTitle);
  }

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _phone.dispose();
    _job.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final updated = await PrufloApi().updateMe(
        name: _name.text.trim(),
        phone: _phone.text.trim(),
        jobTitle: _job.text.trim(),
      );
      AuthService.instance.updateProfile(updated);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Profile updated')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final twoColumns = MediaQuery.sizeOf(context).width >= 700;

    Widget pair(Widget a, Widget b) => twoColumns
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: a),
              const SizedBox(width: 20),
              Expanded(child: b),
            ],
          )
        : Column(children: [a, const SizedBox(height: 16), b]);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 32,
                  backgroundColor: AppColors.primary,
                  child: Text(_user.initials,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w600)),
                ),
                const SizedBox(width: 16),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_user.displayName,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      Text('Role: ${roleLabel(_user.role)}',
                          style: const TextStyle(
                              fontSize: 13, color: AppColors.textSecondary)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            pair(
              LabeledField(
                label: 'Full name',
                controller: _name,
                validator: (v) => Validators.required(v, 'Full name'),
              ),
              LabeledField(
                label: 'Email address',
                controller: _email,
                readOnly: true, // managed by an admin
              ),
            ),
            const SizedBox(height: 16),
            pair(
              LabeledField(
                label: 'Phone number',
                controller: _phone,
                keyboardType: TextInputType.phone,
              ),
              LabeledField(label: 'Job title', controller: _job),
            ),
            const SizedBox(height: 24),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(160, 44)),
              onPressed: _saving ? null : _save,
              child: Text(_saving ? 'Saving…' : 'Save Changes'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SecurityTab extends StatelessWidget {
  const _SecurityTab();

  @override
  Widget build(BuildContext context) {
    final auth = AuthService.instance;
    final email = auth.user?.email ?? '';
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        if (auth.usesFirebase)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.lock_reset_outlined),
            title: const Text('Change password'),
            subtitle: Text('We will email a reset link to $email'),
            trailing: OutlinedButton(
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 40)),
              onPressed: () async {
                try {
                  await auth.sendPasswordReset(email);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('Password reset email sent')));
                  }
                } on AuthException catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context)
                        .showSnackBar(SnackBar(content: Text(e.message)));
                  }
                }
              },
              child: const Text('Send link'),
            ),
          )
        else
          const ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.info_outline),
            title: Text('Development sign-in'),
            subtitle: Text(
                'This build signs in without passwords. Password management '
                'is available when Firebase Auth is configured.'),
          ),
        // Phones have no sidebar, so admins reach these pages from here.
        if (AuthService.instance.isAdmin) ...[
          const Divider(height: 32),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.admin_panel_settings_outlined),
            title: const Text('Admin'),
            subtitle: const Text('Users, roles and system settings'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.go('/admin'),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.hub_outlined),
            title: const Text('Integrations'),
            subtitle: const Text('API keys, webhooks, sources and rules'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.go('/integrations'),
          ),
        ],
        const Divider(height: 32),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.logout, color: AppColors.danger),
          title: const Text('Sign out'),
          subtitle: const Text('Sign out of Pruflo on this device'),
          onTap: () async {
            await AuthService.instance.signOut();
            if (context.mounted) context.go('/login');
          },
        ),
      ],
    );
  }
}
