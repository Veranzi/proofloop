import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pruflo/app/router.dart';
import 'package:pruflo/core/api.dart';
import 'package:pruflo/core/api_client.dart';
import 'package:pruflo/core/auth_service.dart';
import 'package:pruflo/main.dart';

import 'support/fake_api.dart';

Future<void> _open(WidgetTester tester, String route,
    {Size size = const Size(1440, 900)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(const PrufloApp());
  appRouter.go(route);
  await _settle(tester);
}

/// Let the fake API answer; no pumpAndSettle because spinners animate.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<FakeApi> _signedIn(WidgetTester tester, FakeApi api) async {
  await tester.runAsync(() async {
    await api.install();
    await AuthService.instance.signIn('tester@example.com', '');
  });
  return api;
}

void main() {
  group('notifications bell', () {
    testWidgets('shows the unread count; mark all as read clears it',
        (tester) async {
      final api = await _signedIn(tester, FakeApi());
      await _open(tester, '/dashboard');

      expect(find.byTooltip('Notifications, 2 unread'), findsOneWidget);
      expect(
          find.descendant(of: find.byType(Badge), matching: find.text('2')),
          findsOneWidget);

      await tester.tap(find.byTooltip('Notifications, 2 unread'));
      await _settle(tester);
      expect(find.text('T-001 was assigned to you'), findsOneWidget);
      expect(find.text('order.pdf was processed'), findsOneWidget);

      await tester.tap(find.text('Mark all as read'));
      await _settle(tester);
      expect(api.sent('POST', '/v1/me/notifications/read-all'), hasLength(1));
      expect(find.text('Mark all as read'), findsNothing);
      expect(find.byTooltip('Notifications'), findsOneWidget);
    });

    testWidgets('tapping a notification marks it read and opens its link',
        (tester) async {
      final api = await _signedIn(tester, FakeApi());
      await _open(tester, '/dashboard');
      await tester.tap(find.byTooltip('Notifications, 2 unread'));
      await _settle(tester);

      await tester.tap(find.text('T-001 was assigned to you'));
      await _settle(tester);
      expect(api.sent('POST', '/notifications/ntf_1/read'), hasLength(1));
      expect(appRouter.routeInformationProvider.value.uri.path,
          '/cases/case_1');
    });

    testWidgets('an empty inbox says so', (tester) async {
      await _signedIn(tester, FakeApi(empty: true));
      await _open(tester, '/dashboard');
      await tester.tap(find.byTooltip('Notifications'));
      await _settle(tester);
      expect(find.text('No notifications yet'), findsOneWidget);
    });

    testWidgets('the bell is on phones too', (tester) async {
      await _signedIn(tester, FakeApi());
      await _open(tester, '/dashboard', size: const Size(390, 844));
      expect(find.byTooltip('Notifications, 2 unread'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('a notification preference is saved with PATCH /v1/me',
      (tester) async {
    final api = await _signedIn(tester, FakeApi());
    await _open(tester, '/profile');
    await tester.tap(find.text('Notifications'));
    await _settle(tester);

    final weekly = find.widgetWithText(
        SwitchListTile, 'Weekly case summary (Mondays, in the app)');
    expect(tester.widget<SwitchListTile>(weekly).value, isFalse);
    await tester.tap(weekly);
    await _settle(tester);

    final patch = api.sent('PATCH', '/v1/me');
    expect(patch, hasLength(1));
    expect(jsonDecode(patch.single.body), {
      'notification_preferences': {'weekly_summary': true}
    });
    expect(tester.widget<SwitchListTile>(weekly).value, isTrue);
  });

  test('profile photo: upload URL, PUT, then complete', () async {
    final api = FakeApi();
    ApiClient.instance = ApiClient(
      httpClient: api.client,
      baseUrl: 'http://api.test',
      tokenProvider: () async => 'dev:local:tester@example.com',
    );
    final me = await PrufloApi()
        .uploadAvatar(Uint8List.fromList([1, 2, 3]), 'image/png');
    expect(me.avatarUrl, 'http://api.test/avatar.jpg');
    expect([for (final r in api.requests) '${r.method} ${r.url.path}'], [
      'POST /v1/me/avatar/upload-url',
      'PUT /upload/avatar',
      'POST /v1/me/avatar/complete',
    ]);
    expect(jsonDecode(api.requests.first.body),
        {'content_type': 'image/png', 'size_bytes': 3});
  });

  group('development sign-in survives a reload', () {
    testWidgets('a saved email is restored on launch', (tester) async {
      final api = FakeApi(role: 'reviewer');
      await tester.runAsync(() =>
          api.install(storage: {'pruflo.dev_email': 'tester@example.com'}));
      expect(AuthService.instance.isSignedIn, isTrue);
      expect(AuthService.instance.user!.name, 'Test Reviewer');
      expect(api.sent('GET', '/v1/me'), hasLength(1));

      await _open(tester, '/cases');
      expect(find.text('Test case T-001'), findsOneWidget);
    });

    testWidgets('a saved email the API refuses is forgotten', (tester) async {
      final api = FakeApi();
      api.overrides['GET /v1/me'] = (_) => FakeApi.error(
          403, 'not_invited', "This account hasn't been invited to Pruflo.");
      await tester.runAsync(() =>
          api.install(storage: {'pruflo.dev_email': 'gone@example.com'}));
      expect(AuthService.instance.isSignedIn, isFalse);

      // Next launch: nothing saved, so no call is made.
      api.requests.clear();
      api.overrides.clear();
      await tester.runAsync(AuthService.instance.init);
      expect(api.sent('GET', '/v1/me'), isEmpty);
    });

    testWidgets('sign-in saves the email and sign-out forgets it',
        (tester) async {
      final api = await _signedIn(tester, FakeApi());
      await tester.runAsync(AuthService.instance.init); // a "reload"
      expect(AuthService.instance.isSignedIn, isTrue);

      await tester.runAsync(AuthService.instance.signOut);
      api.requests.clear();
      await tester.runAsync(AuthService.instance.init);
      expect(AuthService.instance.isSignedIn, isFalse);
      expect(api.sent('GET', '/v1/me'), isEmpty);
    });
  });

  group('admin', () {
    testWidgets('customers tab lists and adds customers', (tester) async {
      final api = await _signedIn(tester, FakeApi());
      await _open(tester, '/admin');
      await tester.tap(find.text('Customers'));
      await _settle(tester);
      expect(find.text('Acme Supplies'), findsOneWidget);

      await tester.tap(find.text('Add customer'));
      await _settle(tester);
      await tester.enterText(find.byType(TextFormField).first, 'Nusantara Trading');
      await tester.tap(find.text('Save'));
      await _settle(tester);

      final post = api.sent('POST', '/v1/admin/customers');
      expect(post, hasLength(1));
      expect(jsonDecode(post.single.body),
          {'name': 'Nusantara Trading', 'contact_email': ''});
      expect(find.text('Nusantara Trading'), findsOneWidget);
    });

    testWidgets('audit log shows who did what', (tester) async {
      await _signedIn(tester, FakeApi());
      await _open(tester, '/admin');
      await tester.tap(find.text('Audit log'));
      await _settle(tester);
      expect(find.text('User invited'), findsOneWidget);
      expect(find.text('Case status changed'), findsOneWidget);
      expect(find.textContaining('System ·'), findsOneWidget);
      expect(find.text('Open case'), findsOneWidget);
    });

    testWidgets('managing members sends the selected users', (tester) async {
      final api = await _signedIn(tester, FakeApi());
      await _open(tester, '/cases/case_1');
      final manage = find.text('Manage members');
      await tester.ensureVisible(manage);
      await _settle(tester);
      expect(find.text('Test Reviewer'), findsWidgets);

      await tester.tap(manage);
      await _settle(tester);
      await tester.tap(find.widgetWithText(CheckboxListTile, 'Other Investigator'));
      await tester.pump();
      await tester.tap(find.text('Save'));
      await _settle(tester);

      final put = api.sent('PUT', '/v1/admin/cases/case_1/members');
      expect(put, hasLength(1));
      expect(jsonDecode(put.single.body), {
        'user_ids': ['u_other', 'u_test']
      });
      expect(find.text('Other Investigator'), findsOneWidget);
    });

    testWidgets('members are hidden from non-admins', (tester) async {
      await _signedIn(tester, FakeApi(role: 'investigator'));
      await _open(tester, '/cases/case_1');
      expect(find.text('Manage members'), findsNothing);
    });
  });
}
