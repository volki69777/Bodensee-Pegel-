import 'package:flutter_test/flutter_test.dart';

import 'package:bodensee_pegel/main.dart';

void main() {
  testWidgets('shows the live Bodensee Pegel view', (WidgetTester tester) async {
    await tester.pumpWidget(const BodenseePegelApp());

    expect(find.text('Bodensee Pegel+'), findsOneWidget);
    expect(find.text('BODENSEE INDEX'), findsOneWidget);
    expect(find.byType(DashboardPage), findsOneWidget);
  });
}
