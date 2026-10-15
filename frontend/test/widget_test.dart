import 'package:flutter_test/flutter_test.dart';

import 'package:proofloop/main.dart';

void main() {
  testWidgets('App starts and shows the ProofLoop brand', (tester) async {
    await tester.pumpWidget(const ProofLoopApp());
    await tester.pump();
    expect(find.textContaining('ProofLoop'), findsWidgets);
  });
}
