import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/auth_service.dart';
import '../../core/models.dart';
import '../../widgets/form_fields.dart';
import '../../widgets/page_header.dart';

/// Account settings. API: GET/PATCH /v1/me (1, 21); password and email
/// changes go through Firebase Auth directly.
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
              length: 3,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: const [
                  TabBar(
                    isScrollable: true,
                    tabAlignment: TabAlignment.start,
                    tabs: [
                      Tab(text: 'Personal Info'),
                      Tab(text: 'Security'),
                      Tab(text: 'Notifications'),
                    ],
                  ),
                  Divider(height: 1),
                  SizedBox(
                    height: 520,
                    child: TabBarView(
                      children: [
                        _PersonalInfoTab(),
                        _SecurityTab(),
                        _NotificationsTab(),
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

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    AuthService.instance.updateProfile(AppUser(
      name: _name.text.trim(),
      email: _user.email,
      role: _user.role,
      phone: _phone.text.trim(),
      jobTitle: _job.text.trim(),
    ));
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Profile updated')));
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
                  child: TextButton.icon(
                    onPressed: () {},
                    icon: const Icon(Icons.photo_camera_outlined, size: 18),
                    label: const Text('Change photo',
                        overflow: TextOverflow.ellipsis),
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
                readOnly: true, // changed through Firebase Auth verification
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
              onPressed: _save,
              child: const Text('Save Changes'),
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
    final email = AuthService.instance.user?.email ?? '';
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.lock_reset_outlined),
          title: const Text('Change password'),
          subtitle: Text('We will email a reset link to $email'),
          trailing: OutlinedButton(
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 40)),
            onPressed: () async {
              await AuthService.instance.sendPasswordReset(email);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Password reset email sent')));
              }
            },
            child: const Text('Send link'),
          ),
        ),
        const Divider(height: 32),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.logout, color: AppColors.danger),
          title: const Text('Sign out'),
          subtitle: const Text('Sign out of ProofLoop on this device'),
          onTap: () {
            AuthService.instance.signOut();
            context.go('/login');
          },
        ),
      ],
    );
  }
}

class _NotificationsTab extends StatefulWidget {
  const _NotificationsTab();

  @override
  State<_NotificationsTab> createState() => _NotificationsTabState();
}

class _NotificationsTabState extends State<_NotificationsTab> {
  // Delivered through FCM; preferences saved with PATCH /v1/me.
  final _prefs = <String, bool>{
    'Evidence processing finished': true,
    'Case assigned to me for review': true,
    'Report ready to download': true,
    'Weekly case summary email': false,
  };

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        for (final e in _prefs.entries)
          SwitchListTile(
            value: e.value,
            title: Text(e.key),
            onChanged: (v) => setState(() => _prefs[e.key] = v),
          ),
      ],
    );
  }
}
