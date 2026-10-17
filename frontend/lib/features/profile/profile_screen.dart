import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/api.dart';
import '../../core/auth_service.dart';
import '../../core/models.dart';
import '../../core/push_service.dart';
import '../../widgets/async_view.dart';
import '../../widgets/form_fields.dart';
import '../../widgets/page_header.dart';
import '../../widgets/status_chip.dart';
import '../../widgets/user_avatar.dart';

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
            const _PhotoHeader(),
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

/// Photo, name and role, with "Change photo" and "Remove photo"
/// (endpoints 54–56).
class _PhotoHeader extends StatefulWidget {
  const _PhotoHeader();

  @override
  State<_PhotoHeader> createState() => _PhotoHeaderState();
}

class _PhotoHeaderState extends State<_PhotoHeader> {
  static const _maxBytes = 5 * 1024 * 1024;
  bool _busy = false;

  Future<void> _change() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['png', 'jpg', 'jpeg'],
    );
    if (picked.isEmpty || !mounted) return;
    final file = picked.first;
    final size = await file.length() ?? 0;
    if (!mounted) return;
    if (size > _maxBytes) {
      showError(context, 'Photos must be 5 MB or smaller.');
      return;
    }
    final ext = file.name.split('.').last.toLowerCase();
    setState(() => _busy = true);
    try {
      final updated = await PrufloApi().uploadAvatar(
          await file.readAsBytes(), ext == 'png' ? 'image/png' : 'image/jpeg');
      AuthService.instance.updateProfile(updated);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Photo updated')));
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove() async {
    setState(() => _busy = true);
    try {
      await PrufloApi().removeAvatar();
      await AuthService.instance.refresh();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AuthService.instance,
      builder: (context, _) {
        final user = AuthService.instance.user;
        if (user == null) return const SizedBox.shrink();
        return Row(
          children: [
            UserAvatar(
              initials: user.initials,
              url: user.avatarUrl,
              radius: 32,
              background: AppColors.primary,
              foreground: Colors.white,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(user.displayName,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text('Role: ${roleLabel(user.role)}',
                      style: const TextStyle(
                          fontSize: 13, color: AppColors.textSecondary)),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 4,
                    children: [
                      TextButton.icon(
                        onPressed: _busy ? null : _change,
                        icon: const Icon(Icons.photo_camera_outlined, size: 18),
                        label: Text(_busy ? 'Saving…' : 'Change photo'),
                      ),
                      if (user.avatarUrl != null)
                        TextButton(
                          onPressed: _busy ? null : _remove,
                          child: const Text('Remove photo'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Which notifications to receive, saved with PATCH /v1/me (21).
class _NotificationsTab extends StatefulWidget {
  const _NotificationsTab();

  @override
  State<_NotificationsTab> createState() => _NotificationsTabState();
}

class _NotificationsTabState extends State<_NotificationsTab> {
  static const _labels = [
    ('evidence_processed', 'Evidence processing finished or failed'),
    ('case_assigned', 'Case assigned to me'),
    ('case_in_review', 'Case ready for my review'),
    ('report_ready', 'Report ready to download'),
    ('weekly_summary', 'Weekly case summary (Mondays, in the app)'),
  ];

  // Shown until the server says otherwise (Docs/API_Contract.md defaults).
  static const _defaults = {
    'evidence_processed': true,
    'case_assigned': true,
    'case_in_review': true,
    'report_ready': true,
    'weekly_summary': false,
    'push': true,
  };

  final _saving = <String>{};

  bool _value(String key) =>
      AuthService.instance.user?.notificationPreferences[key] ??
      _defaults[key] ??
      false;

  Future<void> _set(String key, bool value) async {
    final auth = AuthService.instance;
    final before = auth.user;
    if (before == null) return;
    // Show the change at once; undo it if the server refuses.
    auth.updateProfile(before.copyWith(notificationPreferences: {
      ...before.notificationPreferences,
      key: value,
    }));
    setState(() => _saving.add(key));
    try {
      final updated =
          await PrufloApi().updateMe(notificationPreferences: {key: value});
      auth.updateProfile(updated);
    } catch (e) {
      auth.updateProfile(before);
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _saving.remove(key));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AuthService.instance,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'Notifications appear under the bell at the top of the page.',
              style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
            ),
          ),
          for (final (key, label) in _labels)
            SwitchListTile(
              value: _value(key),
              title: Text(label),
              onChanged: _saving.contains(key) ? null : (v) => _set(key, v),
            ),
          const Divider(height: 24),
          SwitchListTile(
            value: _value('push'),
            title: const Text('Also send to my devices (push)'),
            subtitle: Text(PushService.instance.enabled
                ? 'Your browser will ask for permission the first time.'
                : "Push isn't set up for this build; you'll still see them "
                    'under the bell.'),
            onChanged:
                _saving.contains('push') ? null : (v) => _set('push', v),
          ),
        ],
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
