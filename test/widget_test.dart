import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:testev/main.dart';

void main() {
  testWidgets('App launches without error', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: TESTEVApp()));
    expect(find.text('TESTEV — Connect'), findsOneWidget);
  });
}
