import 'package:go_router/go_router.dart';

import '../core/auth_service.dart';
import '../features/auth/splash_screen.dart';

/// Routes that can be opened without signing in.
const _publicRoutes = {'/'};

final appRouter = GoRouter(
  initialLocation: '/',
  refreshListenable: AuthService.instance,
  redirect: (context, state) {
    final signedIn = AuthService.instance.isSignedIn;
    final path = state.matchedLocation;
    if (!signedIn && !_publicRoutes.contains(path)) return '/';
    return null;
  },
  routes: [
    GoRoute(path: '/', builder: (context, state) => const SplashScreen()),
  ],
);
