import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:testev/main.dart';

void main() {
  testWidgets('TESTEV boots to the connect screen', (WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AppModel(),
        child: const TESTEVApp(),
      ),
    );

    expect(find.text('TESTEV'), findsOneWidget);
    expect(find.text('Connect via WiFi'), findsOneWidget);
    expect(find.text('Connect via Bluetooth'), findsOneWidget);
  });
}
