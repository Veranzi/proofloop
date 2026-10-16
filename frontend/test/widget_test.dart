import 'package:flutter_test/flutter_test.dart';

import 'package:pruflo/main.dart';

void main() {
  testWidgets('App starts and shows the Pruflo brand', (tester) async {
    await tester.pumpWidget(const PrufloApp());
    await tester.pump();
    expect(find.textContaining('Pruflo'), findsWidgets);
  });
}
