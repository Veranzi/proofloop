import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pruflo/app/router.dart';
import 'package:pruflo/core/auth_service.dart';
import 'package:pruflo/main.dart';

import 'support/fake_api.dart';

/// Renders every route at phone and desktop sizes against the fake API.
/// Layout overflows and build errors fail the test.
void main() {
  const sizes = {
    'phone': Size(390, 844),
    'desktop': Size(1440, 900),
  };

  const publicRoutes = [
    '/login',
    '/signup',
    '/forgot-password',
    '/verify-email?email=tester@example.com',
  ];

  const signedInRoutes = [
    '/dashboard',
    '/cases',
    '/cases/case_1',
    '/cases/case_missing',
    '/evidence',
    '/review',
    '/reports',
    '/profile',
    '/admin',
    '/integrations',
  ];

  Future<void> show(WidgetTester tester, Size size, String route) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const PrufloApp());
    appRouter.go(route);
    // Let the fake API answer and the screen rebuild.
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  for (final entry in sizes.entries) {
    group('${entry.key} (${entry.value.width.toInt()}px)', () {
      for (final route in publicRoutes) {
        testWidgets('renders $route', (tester) async {
          await tester.runAsync(() => FakeApi().install());
          await show(tester, entry.value, route);
          expect(tester.takeException(), isNull);
          expect(find.byType(Scaffold), findsWidgets);
        });
      }

      for (final route in signedInRoutes) {
        testWidgets('renders $route', (tester) async {

          await tester.runAsync(() async {
            await FakeApi().install();
            await AuthService.instance.signIn('tester@example.com', '');
          });

          await tester.runAsync(
              () => AuthService.instance.signInWithProvider('google'));

          await show(tester, entry.value, route);
          expect(tester.takeException(), isNull);
          expect(find.byType(Scaffold), findsWidgets);
          expect(find.textContaining('Something went wrong'), findsNothing);
          expect(find.textContaining('No route for'), findsNothing);
        });
      }
    });
  }
}
