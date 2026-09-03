import 'package:demo_ai_even/faces/face_scheduler.dart';
import 'package:demo_ai_even/services/keepalive_service.dart';
import 'package:demo_ai_even/views/faces/face_settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

void main() {
  testWidgets('Face settings page renders (smoke)', (tester) async {
    Get.reset();
    KeepAliveService.create();
    FaceScheduler.create();

    await tester.pumpWidget(
      const MaterialApp(home: FaceSettingsPage()),
    );

    expect(find.text('Even Faces'), findsOneWidget);
    expect(find.text('Preview (what the glasses show)'), findsOneWidget);
    expect(find.text('Clock'), findsOneWidget);
    expect(find.text('Text'), findsOneWidget);
    expect(find.text('Link'), findsOneWidget);

    // let the 1 s preview ticker fire a few times, then settle
    await tester.pump(const Duration(seconds: 3));
    expect(tester.takeException(), isNull);

    // unmount so the preview ticker's periodic Timer is cancelled
    await tester.pumpWidget(const SizedBox.shrink());

    Get.reset();
  });
}
