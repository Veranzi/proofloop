import 'package:go_router/go_router.dart';

import '../core/auth_service.dart';
import '../features/admin/admin_screen.dart';
import '../features/auth/forgot_password_screen.dart';
import '../features/auth/login_screen.dart';
import '../features/auth/signup_screen.dart';
import '../features/auth/splash_screen.dart';
import '../features/auth/verify_email_screen.dart';
import '../features/cases/case_details_screen.dart';
import '../features/cases/cases_screen.dart';
import '../features/dashboard/dashboard_screen.dart';
import '../features/evidence/evidence_upload_screen.dart';
import '../features/integrations/integrations_screen.dart';
import '../features/profile/profile_screen.dart';
import '../features/reports/reports_screen.dart';
import '../features/review/review_workspace_screen.dart';
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
    final auth = AuthService.instance;
    final signedIn = auth.isSignedIn;
    final path = state.matchedLocation;
    final isPublic = _publicRoutes.contains(path);

    // On launch or reload the saved session is still being checked: wait on
    // the splash, then come back to the page that was open.
    if (!auth.ready && !isPublic) {
      return Uri(path: '/', queryParameters: {'from': state.uri.toString()})
          .toString();
    }
    if (!signedIn && !isPublic) return '/login';
    // Signed-in users skip the auth screens (the splash handles itself).
    if (signedIn && isPublic && path != '/') return '/dashboard';
    return null;
  },
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) =>
          SplashScreen(from: state.uri.queryParameters['from']),
    ),
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
            initialQuery: state.uri.queryParameters['q'],
          ),
        ),
        GoRoute(
          path: '/cases/:id',
          builder: (context, state) =>
              CaseDetailsScreen(caseId: state.pathParameters['id']!),
        ),
        GoRoute(
          path: '/evidence',
          builder: (context, state) => EvidenceUploadScreen(
            initialCaseId: state.uri.queryParameters['case'],
          ),
        ),
        GoRoute(
          path: '/review',
          builder: (context, state) => ReviewWorkspaceScreen(
            initialCaseId: state.uri.queryParameters['case'],
          ),
        ),
        GoRoute(
          path: '/reports',
          builder: (context, state) => ReportsScreen(
            initialCaseId: state.uri.queryParameters['case'],
          ),
        ),
        GoRoute(
          path: '/profile',
          builder: (context, state) => const ProfileScreen(),
        ),
        GoRoute(
          path: '/admin',
          // Hidden from the menu for non-admins; the API enforces it too.
          redirect: (context, state) =>
              AuthService.instance.isAdmin ? null : '/dashboard',
          builder: (context, state) => const AdminScreen(),
        ),
        GoRoute(
          path: '/integrations',
          redirect: (context, state) =>
              AuthService.instance.isAdmin ? null : '/dashboard',
          builder: (context, state) => const IntegrationsScreen(),
        ),
      ],
    ),
  ],
);
