import 'package:flutter/foundation.dart';

import 'models.dart';

/// Mock sign-in state for UI development.
///
/// Replace the bodies with Firebase Auth calls once `flutterfire configure`
/// has been run for the project; the screens only depend on this API.
class AuthService extends ChangeNotifier {
  AuthService._();
  static final instance = AuthService._();

  AppUser? _user;
  AppUser? get user => _user;
  bool get isSignedIn => _user != null;
  bool get isAdmin => _user?.role == UserRole.admin;

  Future<void> signIn(String email, String password) async {
    await Future<void>.delayed(const Duration(milliseconds: 700));
    if (password.length < 6) {
      throw const AuthException('Incorrect email or password.');
    }
    _user = AppUser(
      name: 'Alex Carter',
      email: email,
      // The demo account gets admin so every screen can be reviewed.
      role: UserRole.admin,
      phone: '+1 (555) 123-4567',
      jobTitle: 'Investigator',
    );
    notifyListeners();
  }

  /// Token for `Authorization: Bearer ...` on API calls.
  ///
  /// Firebase Auth isn't wired in yet, so this returns the backend's local
  /// development token (`dev:<uid>:<email>`). The backend accepts it only
  /// when PRUFLO_ENV is local or test. Replace with
  /// `FirebaseAuth.instance.currentUser!.getIdToken()` once Firebase is set up.
  Future<String> idToken() async {
    final email = _user?.email;
    if (email == null) throw const AuthException('Sign in first.');
    final uid = 'local-${email.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '-')}';
    return 'dev:$uid:${email.toLowerCase()}';
  }

  Future<void> signInWithProvider(String provider) =>
      signIn('alex@company.com', 'provider-$provider');

  Future<void> signUp(String name, String email, String password) async {
    await Future<void>.delayed(const Duration(milliseconds: 700));
    // Firebase: createUserWithEmailAndPassword + sendEmailVerification.
  }

  Future<void> sendPasswordReset(String email) async {
    await Future<void>.delayed(const Duration(milliseconds: 600));
  }

  Future<void> resendVerification(String email) async {
    await Future<void>.delayed(const Duration(milliseconds: 600));
  }

  void updateProfile(AppUser updated) {
    _user = updated;
    notifyListeners();
  }

  void signOut() {
    _user = null;
    notifyListeners();
  }
}

class AuthException implements Exception {
  const AuthException(this.message);
  final String message;

  @override
  String toString() => message;
}
