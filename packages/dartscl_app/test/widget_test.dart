@Tags(['web'])
library;

import 'package:dartscl_app/main.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// This app is web-only: main.dart transitively imports package:web and
// dart:js_interop, which are unavailable on the Dart VM. The default
// `flutter test` run skips this file (see dart_test.yaml); run it with
// `flutter test --platform chrome --run-skipped`.
void main() {
  testWidgets('DartSCL App loads successfully', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: DartSclWebApp(),
      ),
    );

    expect(find.text('DartSCL Web Scanner'), findsOneWidget);
  });
}
