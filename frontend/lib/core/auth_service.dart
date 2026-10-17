import 'dart:async';

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'api_client.dart';
import 'config.dart';
import 'models.dart';
import 'push_service.dart';

/// What happened after a sign-in attempt.
enum SignInResult { signedIn, needsEmailVerification }

/// Who is signed in.
///
/// - With Firebase configured (`--dart-define=FIREBASE_API_KEY=...`), people
///   sign in with Firebase Auth and every API call carries their ID token.
/// - Without it, development sign-in takes an invited email and sends the
///   API's `dev:<uid>:<email>` token, which the API only accepts when it runs
///   with PRUFLO_ENV=local.
///
/// Either way the signed-in [user] (name, email, role) comes from
/// GET /v1/me, never from local values.
class AuthService extends ChangeNotifier {
  AuthService._();
  static final instance = AuthService._();

  AppUser? _user;
  String? _devEmail;
  bool _ready = false;
  StreamSubscription<User?>? _authSub;

  AppUser? get user => _user;
  bool get isSignedIn => _user != null;
  bool get isAdmin => _user?.role == UserRole.admin;

  /// False until the saved session (if any) has been checked on launch.
  bool get ready => _ready;

  bool get usesFirebase => AppConfig.firebaseConfigured;

  /// The email waiting for verification after sign-up, if any.
  String? get pendingVerificationEmail {
    if (!usesFirebase) return null;
    final u = FirebaseAuth.instance.currentUser;
    return u != null && !u.emailVerified ? u.email : null;
  }

  /// Where development sign-in remembers who is signed in, so a page reload
  /// keeps the session. Firebase Auth persists its own session.
  static const _devEmailKey = 'pruflo.dev_email';

  /// Call once on launch. [ready] turns true when the saved session (if
  /// any) has been restored or rejected.
  Future<void> init() async {
    ApiClient.instance.tokenProvider = _idToken;
    if (!usesFirebase) {
      final saved =
          (await SharedPreferences.getInstance()).getString(_devEmailKey);
      if (saved != null && saved.isNotEmpty) {
        _devEmail = saved;
        try {
          await _loadMe();
        } on AuthException {
          // Rejected (no longer invited) or the API is down: show sign-in.
        }
      }
      _ready = true;
      notifyListeners();
      return;
    }
    await Firebase.initializeApp(options: AppConfig.firebaseOptions);
    if (AppConfig.appCheckSiteKey.isNotEmpty) {
      await FirebaseAppCheck.instance.activate(
        providerWeb: ReCaptchaV3Provider(AppConfig.appCheckSiteKey),
      );
      ApiClient.instance.appCheckTokenProvider =
          () => FirebaseAppCheck.instance.getToken();
    }
    // The first event is the session Firebase restored from the browser.
    final first = Completer<void>();
    _authSub = FirebaseAuth.instance.authStateChanges().listen((u) async {
      if (u == null) {
        _setUser(null);
      } else if (_user == null && _verifiedOrSocial(u)) {
        try {
          await _loadMe();
        } on AuthException {
          // Not invited or the API is unreachable: stay signed out.
        }
      }
      if (!first.isCompleted) first.complete();
    });
    await first.future;
    _ready = true;
    notifyListeners();
  }

  Future<String> _idToken() async {
    if (!usesFirebase) {
      final email = _devEmail;
      if (email == null) throw const AuthException('Sign in first.');
      return devToken(email);
    }
    final token = await FirebaseAuth.instance.currentUser?.getIdToken();
    if (token == null) throw const AuthException('Sign in first.');
    return token;
  }

  /// The API's local development token for [email].
  static String devToken(String email) {
    final e = email.trim().toLowerCase();
    final uid = 'local-${e.replaceAll(RegExp('[^a-z0-9]'), '-')}';
    return 'dev:$uid:$e';
  }

  bool _verifiedOrSocial(User u) =>
      u.emailVerified ||
      u.providerData.any((p) => p.providerId != 'password');

  void _setUser(AppUser? u) {
    _user = u;
    notifyListeners();
  }

  /// Loads the profile and role. If the API refuses the person (401, or 403
  /// such as not_invited) the session is cleared. Any other failure, such as
  /// the API being unreachable, leaves the saved session for the next try.
  Future<void> _loadMe() async {
    final wasSignedIn = _user != null;
    try {
      _setUser(await PrufloApi().me());
    } on ApiException catch (e) {
      if (e.status == 401 || e.status == 403) {
        await _clearSession();
      } else {
        _setUser(null);
      }
      throw AuthException(e.message);
    }
    if (!wasSignedIn) unawaited(PushService.instance.register());
  }

  Future<void> _clearSession() async {
    _devEmail = null;
    await (await SharedPreferences.getInstance()).remove(_devEmailKey);
    if (usesFirebase) await FirebaseAuth.instance.signOut();
    _setUser(null);
  }

  Future<SignInResult> signIn(String email, String password) async {
    if (!usesFirebase) {
      final normalised = email.trim().toLowerCase();
      _devEmail = normalised;
      await _loadMe();
      await (await SharedPreferences.getInstance())
          .setString(_devEmailKey, normalised);
      return SignInResult.signedIn;
    }
    final cred = await _firebase(() => FirebaseAuth.instance
        .signInWithEmailAndPassword(email: email.trim(), password: password));
    if (!cred.user!.emailVerified) return SignInResult.needsEmailVerification;
    await _loadMe();
    return SignInResult.signedIn;
  }

  /// `google` or `microsoft`; Firebase only.
  Future<SignInResult> signInWithProvider(String provider) async {
    if (!usesFirebase) {
      throw const AuthException(
          'Single sign-on needs Firebase to be configured for this build.');
    }
    final AuthProvider p = provider == 'microsoft'
        ? OAuthProvider('microsoft.com')
        : GoogleAuthProvider();
    await _firebase(() => FirebaseAuth.instance.signInWithPopup(p));
    await _loadMe();
    return SignInResult.signedIn;
  }

  /// Creates the Firebase account and sends the verification email. Access
  /// to Pruflo still needs an admin's invite for the same address.
  Future<void> signUp(String name, String email, String password) async {
    if (!usesFirebase) {
      throw const AuthException(
          'Accounts are created by your Pruflo admin. Ask them to invite you, '
          'then sign in with that email.');
    }
    final cred = await _firebase(() => FirebaseAuth.instance
        .createUserWithEmailAndPassword(email: email.trim(), password: password));
    await cred.user!.updateDisplayName(name.trim());
    await cred.user!.sendEmailVerification();
  }

  Future<void> sendPasswordReset(String email) async {
    if (!usesFirebase) {
      throw const AuthException(
          'Password reset needs Firebase to be configured for this build.');
    }
    await _firebase(() =>
        FirebaseAuth.instance.sendPasswordResetEmail(email: email.trim()));
  }

  Future<void> resendVerification() async {
    final u = usesFirebase ? FirebaseAuth.instance.currentUser : null;
    if (u == null) throw const AuthException('Sign in again to continue.');
    await _firebase(u.sendEmailVerification);
  }

  /// After the person clicks the link in their email.
  Future<bool> checkEmailVerified() async {
    final u = usesFirebase ? FirebaseAuth.instance.currentUser : null;
    if (u == null) throw const AuthException('Sign in again to continue.');
    await u.reload();
    final fresh = FirebaseAuth.instance.currentUser!;
    if (!fresh.emailVerified) return false;
    await fresh.getIdToken(true); // the API reads email_verified from the token
    await _loadMe();
    return true;
  }

  /// Reload the profile after an edit or a role change.
  Future<void> refresh() => _loadMe();

  void updateProfile(AppUser updated) => _setUser(updated);

  Future<void> signOut() async {
    if (_user != null) await PushService.instance.unregister();
    await _clearSession();
  }

  Future<T> _firebase<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on FirebaseAuthException catch (e) {
      throw AuthException(_message(e));
    }
  }

  static String _message(FirebaseAuthException e) => switch (e.code) {
        'invalid-credential' ||
        'wrong-password' ||
        'user-not-found' ||
        'invalid-email' =>
          'Incorrect email or password.',
        'email-already-in-use' =>
          'An account with this email already exists. Sign in instead.',
        'weak-password' => 'Choose a stronger password (at least 6 characters).',
        'too-many-requests' => 'Too many attempts. Wait a moment and try again.',
        'popup-closed-by-user' || 'cancelled-popup-request' =>
          'Sign-in was cancelled.',
        'user-disabled' => 'This account has been disabled.',
        'network-request-failed' =>
          "Can't reach the sign-in service. Check your connection.",
        _ => e.message ?? 'Sign-in failed.',
      };

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }
}

class AuthException implements Exception {
  const AuthException(this.message);
  final String message;

  @override
  String toString() => message;
}
