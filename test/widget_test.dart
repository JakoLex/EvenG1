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

    // The page is a lazy ListView: on the default 800x600 surface the lower
    // cards are never built and the finders below would miss them.
    await tester.binding.setSurfaceSize(const Size(1200, 3000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const MaterialApp(home: FaceSettingsPage()),
    );

    expect(find.text('Even Faces'), findsOneWidget);
    expect(find.text('Faces aktiv'), findsOneWidget);
    expect(find.text('So funktioniert es'), findsOneWidget);
    expect(find.text('Vorschau'), findsOneWidget);
    // one tile per face, each with its own description
    for (final face in FaceScheduler.faces) {
      expect(find.text(face.name), findsOneWidget, reason: face.id);
      expect(find.text(face.description), findsOneWidget, reason: face.id);
    }

    // let the 1 s preview ticker fire a few times, then settle
    await tester.pump(const Duration(seconds: 3));
    expect(tester.takeException(), isNull);

    // unmount so the preview ticker's periodic Timer is cancelled
    await tester.pumpWidget(const SizedBox.shrink());

    Get.reset();
  });
}
