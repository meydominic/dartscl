import 'package:dartscl_app/crop_overlay.dart';
import 'package:dartscl_protocol/dartscl_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('CropOverlay allows drawing rectangle upwards from bottom to top',
      (WidgetTester tester) async {
    CropRegion? currentCrop;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              height: 400,
              child: CropOverlay(
                onCropChanged: (crop) => currentCrop = crop,
              ),
            ),
          ),
        ),
      ),
    );

    final overlayFinder = find.byType(CropOverlay);
    expect(overlayFinder, findsOneWidget);

    // Drag upwards from (300, 300) to (100, 100)
    final center = tester.getCenter(overlayFinder);
    final start = center + const Offset(100, 100);
    final end = center - const Offset(100, 100);

    final gesture = await tester.startGesture(start);
    await tester.pump();
    await gesture.moveTo(end);
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(currentCrop, isNotNull);
    expect(currentCrop!.widthRatio, greaterThan(0));
    expect(currentCrop!.heightRatio, greaterThan(0));
    // The top/left should correspond to the 'end' point, not the 'start' point
    expect(currentCrop!.xRatio, lessThan(0.5));
    expect(currentCrop!.yRatio, lessThan(0.5));
  });

  testWidgets('CropOverlay initializes with initialCrop and retains it',
      (WidgetTester tester) async {
    CropRegion? currentCrop;
    const initial = CropRegion(
      xRatio: 0.1,
      yRatio: 0.2,
      widthRatio: 0.5,
      heightRatio: 0.6,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              height: 400,
              child: CropOverlay(
                initialCrop: initial,
                onCropChanged: (crop) => currentCrop = crop,
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.byType(CropOverlay), findsOneWidget);
    // When rendered with initialCrop, no changes yet triggered until user action
    expect(currentCrop, isNull);
  });
}
