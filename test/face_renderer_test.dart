import 'dart:io';
import 'dart:typed_data';

import 'package:demo_ai_even/faces/face_defs.dart';
import 'package:demo_ai_even/faces/face_renderer.dart';
import 'package:flutter_test/flutter_test.dart';

/// Unit tests for the pure-Dart parts of the face pipeline:
/// Floyd-Steinberg dithering and the 9856-byte BMP packing that the
/// G1 firmware expects (64-byte template header + 9792 px, bottom-up,
/// MSB-first, 72 bytes/row).
void main() {
  const int w = 576;
  const int h = 136;
  const int rowBytes = 72;

  /// Decode the px region of a rendered file back to bits (top-down).
  List<int> decodePxBits(Uint8List file) {
    final out = <int>[];
    for (var y = 0; y < h; y++) {
      final fileRow = h - 1 - y;
      final row = file.sublist(
        64 + fileRow * rowBytes,
        64 + (fileRow + 1) * rowBytes,
      );
      for (var x = 0; x < w; x++) {
        out.add((row[x ~/ 8] >> (7 - x % 8)) & 1);
      }
    }
    return out;
  }

  group('floydSteinberg', () {
    test('pure black and pure white', () {
      final black = Uint8List(4 * w * h);
      final white = Uint8List(4 * w * h)..fillRange(0, 4 * w * h, 255);
      expect(FaceRenderer.floydSteinberg(black, w, h).toSet(), {0});
      expect(FaceRenderer.floydSteinberg(white, w, h).toSet(), {1});
    });

    test('sharp half split stays exact (flat areas do not dither)', () {
      final rgba = Uint8List(4 * w * h);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final v = x < w ~/ 2 ? 0 : 255;
          final i = 4 * (y * w + x);
          rgba[i] = rgba[i + 1] = rgba[i + 2] = v;
          rgba[i + 3] = 255;
        }
      }
      final bits = FaceRenderer.floydSteinberg(rgba, w, h);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          expect(bits[y * w + x], x < w ~/ 2 ? 0 : 1, reason: 'pixel ($x,$y)');
        }
      }
    });

    test('mid gray dithers instead of becoming a flat block', () {
      final rgba = Uint8List(4 * w * h);
      for (var i = 0; i < w * h; i++) {
        rgba[4 * i] = rgba[4 * i + 1] = rgba[4 * i + 2] = 100;
        rgba[4 * i + 3] = 255;
      }
      final bits = FaceRenderer.floydSteinberg(rgba, w, h);
      var ones = 0;
      for (final b in bits) {
        ones += b;
      }
      final frac = ones / bits.length;
      // ~100/255 = 39 % coverage expected, clearly dithered
      expect(frac, greaterThan(0.2));
      expect(frac, lessThan(0.6));
      expect(bits[0], 0); // 100 < 127.5 threshold
      expect(bits.contains(0), isTrue);
      expect(bits.contains(1), isTrue);
    });
  });

  group('encodeBmp', () {
    final header = Uint8List.fromList(List.filled(64, 0xAB));

    test('keeps the header and packs corners bottom-up MSB-first', () {
      final bits = Uint8List(w * h);
      bits[0] = 1; // top-left
      bits[w - 1] = 1; // top-right
      bits[(h - 1) * w] = 1; // bottom-left
      bits[h * w - 1] = 1; // bottom-right

      final file = FaceRenderer.encodeBmp(bits, header: header);
      expect(file.length, 64 + rowBytes * h); // 9856
      for (var i = 0; i < 64; i++) {
        expect(file[i], 0xAB, reason: 'header byte $i');
      }
      // top row of the image = LAST file row
      expect(file[64 + (h - 1) * rowBytes] & 0x80, 0x80);
      expect(file[64 + (h - 1) * rowBytes + rowBytes - 1] & 0x01, 0x01);
      // bottom row of the image = FIRST file row
      expect(file[64] & 0x80, 0x80);
      expect(file[64 + rowBytes - 1] & 0x01, 0x01);
      // and nothing else is set
      expect(
        decodePxBits(file),
        [
          for (var i = 0; i < w * h; i++)
            (i == 0 || i == w - 1 || i == (h - 1) * w || i == h * w - 1)
                ? 1
                : 0
        ],
      );
    });

    test('all-on bits -> every px byte is 0xFF', () {
      final bits = Uint8List(w * h)..fillRange(0, w * h, 1);
      final file = FaceRenderer.encodeBmp(bits, header: header);
      for (var i = 64; i < file.length; i++) {
        expect(file[i], 0xFF, reason: 'px byte $i');
      }
    });

    test('round-trips an arbitrary pattern', () {
      final bits = Uint8List(w * h);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          bits[y * w + x] = (x * 7 + y * 13) % 3 == 0 ? 1 : 0;
        }
      }
      final file = FaceRenderer.encodeBmp(bits, header: header);
      expect(decodePxBits(file), [for (final b in bits) b]);
    });
  });

  group('TextFace', () {
    testWidgets('long text stays inside the 136 px panel', (tester) async {
      final data = FaceData(
        now: DateTime(2026, 9, 24, 12, 0, 0),
        connected: true,
        glassesWorn: true,
        linkCounter: 0,
        lastSuccessAt: null,
        linkIntervalSec: 2,
        customText: List.generate(20, (i) => 'line $i').join('\n'),
      );
      final bits = await FaceRenderer().renderBits(const TextFace(), data);
      // maxLines keeps the block centered; the outermost rows must stay off.
      for (final y in [0, h - 1]) {
        for (var x = 0; x < w; x++) {
          expect(bits[y * w + x], 0, reason: 'pixel ($x,$y) outside the block');
        }
      }
      // and something was actually drawn
      expect(bits.contains(1), isTrue);
    });
  });

  group('template header (golden)', () {
    testWidgets('matches the shipped image_2.bmp', (tester) async {
      final f = File('assets/images/image_2.bmp');
      expect(f.existsSync(), isTrue,
          reason: 'flutter test runs with the project root as cwd');
      final template = f.readAsBytesSync();
      expect(template.length, 9856);
      expect(template[0], 0x42); // 'B'
      expect(template[1], 0x4D); // 'M'

      final viaBundle = await FaceRenderer().header();
      expect(viaBundle.length, 64);
      expect(viaBundle, template.sublist(0, 64));
    });
  });
}
