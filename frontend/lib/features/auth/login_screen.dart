import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/auth_service.dart';
import '../../widgets/auth_layout.dart';
import '../../widgets/form_fields.dart';
import '../../widgets/social_buttons.dart';
import '../integrations/integration_widgets.dart';

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

  final _auth = AuthService.instance;

  Future<void> _run(Future<SignInResult> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await action();
      if (!mounted) return;
      if (result == SignInResult.needsEmailVerification) {
        context.go(Uri(
            path: '/verify-email',
            queryParameters: {'email': _email.text.trim()}).toString());
      } else {
        context.go('/dashboard');
      }
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    _run(() => _auth.signIn(_email.text.trim(), _password.text));
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 600;
    final firebase = _auth.usesFirebase;

    return AuthLayout(
      title: 'Welcome back',
      subtitle: 'Sign in to your account to continue',
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!firebase) ...[
              const InfoBanner(
                'Development sign-in: enter an email address your Pruflo '
                'admin has invited. No password is needed, and it only works '
                'with an API running locally.',
                warning: true,
              ),
              const SizedBox(height: 16),
            ],
            LabeledField(
              label: 'Email address',
              hint: 'you@company.com',
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              textInputAction:
                  firebase ? TextInputAction.next : TextInputAction.done,
              onSubmitted: firebase ? null : (_) => _submit(),
              validator: Validators.email,
            ),
            if (firebase) ...[
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
            ] else
              const SizedBox(height: 16),
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
            if (firebase) ...[
              const SizedBox(height: 24),
              const OrDivider(),
              const SizedBox(height: 16),
              SocialButtons(
                compact: compact,
                onPressed: (p) => _run(() => _auth.signInWithProvider(p)),
              ),
            ],
            const SizedBox(height: 24),
            if (firebase) Wrap(
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
