import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pruflo/app/router.dart';
import 'package:pruflo/core/auth_service.dart';
import 'package:pruflo/main.dart';

/// Renders every route at phone and desktop sizes. Layout overflows and
/// build errors fail the test.
void main() {
  const sizes = {
    'phone': Size(390, 844),
    'desktop': Size(1440, 900),
  };

  const publicRoutes = [
    '/login',
    '/signup',
    '/forgot-password',
    '/verify-email?email=alex@company.com',
  ];

  const signedInRoutes = [
    '/dashboard',
    '/cases',
    '/cases/PL-001',
    '/evidence',
    '/review',
    '/reports',
    '/profile',
    '/admin',
  ];

  Future<void> show(WidgetTester tester, Size size, String route) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const PrufloApp());
    appRouter.go(route);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  for (final entry in sizes.entries) {
    group('${entry.key} (${entry.value.width.toInt()}px)', () {
      for (final route in publicRoutes) {
        testWidgets('renders $route', (tester) async {
          AuthService.instance.signOut();
          await show(tester, entry.value, route);
          expect(tester.takeException(), isNull);
          expect(find.byType(Scaffold), findsWidgets);
        });
      }

      for (final route in signedInRoutes) {
        testWidgets('renders $route', (tester) async {
          await tester.runAsync(() =>
              AuthService.instance.signIn('alex@company.com', 'password123'));
          await show(tester, entry.value, route);
          expect(tester.takeException(), isNull);
          expect(find.byType(Scaffold), findsWidgets);
        });
      }
    });
  }
}
