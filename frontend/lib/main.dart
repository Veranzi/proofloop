import 'package:flutter/material.dart';

import 'app/router.dart';
import 'app/theme.dart';
import 'core/auth_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PrufloApp());
  // The splash screen waits until the saved session has been checked.
  await AuthService.instance.init();
}

class PrufloApp extends StatelessWidget {
  const PrufloApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Pruflo',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      routerConfig: appRouter,
    );
  }
}
