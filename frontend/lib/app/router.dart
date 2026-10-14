import 'package:go_router/go_router.dart';

import '../core/auth_service.dart';
import '../features/auth/forgot_password_screen.dart';
import '../features/auth/login_screen.dart';
import '../features/auth/signup_screen.dart';
import '../features/auth/splash_screen.dart';

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
    if (!signedIn && !_publicRoutes.contains(path)) return '/login';
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
  ],
);
