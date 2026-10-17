import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'config.dart';

/// Web push through Firebase Cloud Messaging.
///
/// Only active when the build has the Firebase config and a VAPID key
/// (`--dart-define=FIREBASE_VAPID_KEY=...`); otherwise every method is a
/// no-op and people get in-app notifications only. The device is registered
/// with POST /v1/devices (2) after sign-in and removed with
/// DELETE /v1/devices/{id} (22) on sign-out. Whether pushes are actually sent
/// is up to the person's `push` preference on the server.
class PushService {
  PushService._();
  static final instance = PushService._();

  static const _deviceKey = 'pruflo.push_device_id';

  bool get enabled => AppConfig.pushConfigured;

  /// Ask for permission once and register this browser. Never throws.
  Future<void> register() async {
    if (!enabled) return;
    try {
      final messaging = FirebaseMessaging.instance;
      final settings = await messaging.requestPermission();
      if (settings.authorizationStatus == AuthorizationStatus.denied) return;
      // getToken returns the FCM registration token the API sends to. The
      // newer register()/onRegistered gives an installation ID instead, which
      // the API's sender doesn't accept, so keep getToken for now.
      // ignore: deprecated_member_use
      final token = await messaging.getToken(vapidKey: AppConfig.vapidKey);
      if (token == null) return;
      final id = await PrufloApi().registerDevice(token);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_deviceKey, id);
    } catch (e) {
      // Push is a convenience: never block sign-in because of it.
      debugPrint('Push registration skipped: $e');
    }
  }

  /// Stop pushes to this browser. Call before the session is cleared.
  Future<void> unregister() async {
    if (!enabled) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final id = prefs.getString(_deviceKey);
      if (id != null) {
        await PrufloApi().removeDevice(id);
        await prefs.remove(_deviceKey);
      }
      // Matches getToken above.
      // ignore: deprecated_member_use
      await FirebaseMessaging.instance.deleteToken();
    } catch (e) {
      debugPrint('Push unregistration skipped: $e');
    }
  }
}
