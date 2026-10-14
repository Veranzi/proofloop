import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/auth_service.dart';
import '../../widgets/auth_layout.dart';
import '../../widgets/form_fields.dart';
import '../../widgets/social_buttons.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      if (mounted) context.go('/dashboard');
    } on AuthException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    _run(() => AuthService.instance.signIn(_email.text.trim(), _password.text));
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 600;

    return AuthLayout(
      title: 'Welcome back',
      subtitle: 'Sign in to your account to continue',
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LabeledField(
              label: 'Email address',
              hint: 'you@company.com',
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.next,
              validator: Validators.email,
            ),
            const SizedBox(height: 16),
            PasswordField(
              label: 'Password',
              controller: _password,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              validator: (v) => Validators.required(v, 'Password'),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => context.go('/forgot-password'),
                child: const Text('Forgot password?'),
              ),
            ),
            if (_error != null) ...[
              Text(_error!,
                  style: const TextStyle(color: AppColors.danger, fontSize: 13)),
              const SizedBox(height: 12),
            ],
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Text('Sign In'),
            ),
            const SizedBox(height: 24),
            const OrDivider(),
            const SizedBox(height: 16),
            SocialButtons(
              compact: compact,
              onPressed: (p) =>
                  _run(() => AuthService.instance.signInWithProvider(p)),
            ),
            const SizedBox(height: 24),
            Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text("Don't have an account?",
                    style: TextStyle(color: AppColors.textSecondary)),
                TextButton(
                  onPressed: () => context.go('/signup'),
                  child: const Text('Sign up'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
