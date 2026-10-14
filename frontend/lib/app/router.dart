import 'package:go_router/go_router.dart';

import '../core/auth_service.dart';
import '../features/auth/forgot_password_screen.dart';
import '../features/auth/login_screen.dart';
import '../features/auth/signup_screen.dart';
import '../features/auth/splash_screen.dart';
import '../features/auth/verify_email_screen.dart';
import '../features/cases/cases_screen.dart';
import '../features/dashboard/dashboard_screen.dart';
import '../widgets/app_shell.dart';

/// Routes that can be opened without signing in.
const _publicRoutes = {
  '/',
  '/login',
  '/signup',
  '/forgot-password',
  '/verify-email',
};

final appRouter = GoRouter(
  initialLocation: '/',
  refreshListenable: AuthService.instance,
  redirect: (context, state) {
    final signedIn = AuthService.instance.isSignedIn;
    final path = state.matchedLocation;
    final isPublic = _publicRoutes.contains(path);

    if (!signedIn && !isPublic) return '/login';
    // Signed-in users skip the auth screens (the splash handles itself).
    if (signedIn && isPublic && path != '/') return '/dashboard';
    return null;
  },
  routes: [
    GoRoute(path: '/', builder: (context, state) => const SplashScreen()),
    GoRoute(path: '/login', builder: (context, state) => const LoginScreen()),
    GoRoute(path: '/signup', builder: (context, state) => const SignUpScreen()),
    GoRoute(
      path: '/forgot-password',
      builder: (context, state) => const ForgotPasswordScreen(),
    ),
    GoRoute(
      path: '/verify-email',
      builder: (context, state) => VerifyEmailScreen(
        email: state.uri.queryParameters['email'] ?? '',
      ),
    ),

    // Signed-in area: sidebar on wide screens, bottom navigation on phones.
    ShellRoute(
      builder: (context, state, child) =>
          AppShell(location: state.uri.path, child: child),
      routes: [
        GoRoute(
          path: '/dashboard',
          builder: (context, state) => const DashboardScreen(),
        ),
        GoRoute(
          path: '/cases',
          builder: (context, state) => CasesScreen(
            openNewCase: state.uri.queryParameters['new'] == '1',
          ),
        ),
      ],
    ),
  ],
);
