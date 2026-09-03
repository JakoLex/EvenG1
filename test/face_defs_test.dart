import 'package:demo_ai_even/faces/face_defs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('formatting', () {
    test('hhmm / hhmmss pad with zeros', () {
      expect(Face.hhmm(DateTime(2026, 9, 24, 8, 5)), '08:05');
      expect(Face.hhmm(DateTime(2026, 12, 31, 23, 59)), '23:59');
      expect(Face.hhmmss(DateTime(2026, 1, 2, 3, 4, 5)), '03:04:05');
    });

    test('shortDate uses the German weekday', () {
      // 2026-09-24 is a Thursday
      expect(Face.shortDate(DateTime(2026, 9, 24)), 'Do, 24.09.');
      // 2026-10-04 is a Sunday
      expect(Face.shortDate(DateTime(2026, 10, 4)), 'So, 04.10.');
    });
  });

  group('link status', () {
    FaceData data(DateTime? last) => FaceData(
          now: DateTime(2026, 9, 24, 12, 0, 0),
          connected: true,
          glassesWorn: true,
          linkCounter: 3,
          lastSuccessAt: last,
          linkIntervalSec: 2,
          batteryL: 80,
          batteryR: 75,
          customText: 'x',
        );

    test('linkOk needs a success inside 3x the interval', () {
      expect(data(null).linkOk, isFalse);
      expect(data(DateTime(2026, 9, 24, 11, 59, 59)).linkOk, isTrue);
      // exactly 3 * 2 s old -> not fresh anymore (strict <)
      expect(data(DateTime(2026, 9, 24, 11, 59, 54)).linkOk, isFalse);
    });

    test('face ids and names are stable', () {
      expect(ClockFace().id, 'clock');
      expect(ClockFace().name, 'Clock');
      expect(TextFace().id, 'text');
      expect(LinkFace().id, 'link');
    });
  });
}
