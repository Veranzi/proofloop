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
