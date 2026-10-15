import 'package:flutter/material.dart';

import 'app/router.dart';
import 'app/theme.dart';

void main() {
  runApp(const ProofLoopApp());
}

class ProofLoopApp extends StatelessWidget {
  const ProofLoopApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'ProofLoop',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      routerConfig: appRouter,
    );
  }
}
