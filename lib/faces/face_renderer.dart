import 'dart:typed_data';
import 'dart:ui' show ImageByteFormat, PictureRecorder;

import 'package:demo_ai_even/faces/face_defs.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

/// Turns a [Face] + [FaceData] into the exact byte stream the G1 firmware
/// expects for a 0x15 BMP transfer:
///
///   1. paint the face into a 576 x 136 canvas (white on black)
///   2. rasterize to RGBA
///   3. Floyd-Steinberg dither to 1 bit (1 = pixel ON = green)
///   4. pack to a 9856-byte BMP: 64-byte header (byte-identical to
///      assets/images/image_2.bmp) + 9792 bottom-up rows of 72 bytes,
///      MSB-first.
///
/// Steps 3 and 4 are pure Dart and fully unit-testable; step 2 uses the
/// Flutter software rasterizer (also available in flutter_test).
class FaceRenderer {
  static const int width = kFaceWidth;
  static const int height = kFaceHeight;
  static const int rowBytes = (width + 7) ~/ 8; // 72
  static const int pixelBytes = rowBytes * height; // 9792
  static const int bmpBytes = 64 + pixelBytes; // 9856

  /// Cached 64-byte BMP header, byte-identical to the working template.
  Uint8List? _header;

  Future<Uint8List> header() async {
    _header ??= await _loadHeader();
    return _header!;
  }

  Future<Uint8List> _loadHeader() async {
    final bytes = await rootBundle.load('assets/images/image_2.bmp');
    final h = bytes.buffer.asUint8List(bytes.offsetInBytes, 64);
    if (h.length != 64) {
      throw StateError('image_2.bmp header must be 64 bytes, got ${h.length}');
    }
    return Uint8List.fromList(h);
  }

  /// Renders the face to a 1-bit row-major bitmap (width*height bytes,
  /// 1 = ON). Row 0 is the top of the picture.
  Future<Uint8List> renderBits(Face face, FaceData data) async {
    final recorder = PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      Rect.fromLTWH(0.0, 0.0, width.toDouble(), height.toDouble()),
      Paint()..color = const Color(0xFF000000),
    );
    face.paint(canvas, Size(width.toDouble(), height.toDouble()), data);
    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    final byteData = await image.toByteData(format: ImageByteFormat.rawRgba);
    image.dispose();
    picture.dispose();
    if (byteData == null) {
      throw StateError('toByteData returned null');
    }

    final rgba = byteData.buffer.asUint8List(byteData.offsetInBytes);
    return floydSteinberg(rgba, width, height);
  }

  /// Full pipeline: face -> 9856-byte BMP file bytes.
  Future<Uint8List> renderBmp(Face face, FaceData data,
      {Uint8List? header}) async {
    final bits = await renderBits(face, data);
    final hdr = header ?? await this.header();
    return encodeBmp(bits, header: hdr);
  }

  /// Floyd-Steinberg dither of RGBA to 1 bit (row-major, MSB of each
  /// 8-pixel group unused until packing).
  static Uint8List floydSteinberg(Uint8List rgba, int w, int h) {
    final n = w * h;
    final gray = Float64List(n);
    for (var i = 0; i < n; i += 4) {
      gray[i ~/ 4] = (rgba[i] + rgba[i + 1] + rgba[i + 2]) / 3.0;
    }
    final bits = Uint8List(n);
    for (var y = 0; y < h; y++) {
      final row = y * w;
      for (var x = 0; x < w; x++) {
        final i = row + x;
        final v = gray[i];
        final on = v >= 127.5 ? 1 : 0;
        bits[i] = on;
        final err = v - (on == 1 ? 255.0 : 0.0);
        if (err == 0) continue;
        if (x + 1 < w) gray[i + 1] += err * 7 / 16;
        if (y + 1 < h) {
          if (x > 0) gray[i + w - 1] += err * 3 / 16;
          gray[i + w] += err * 5 / 16;
          if (x + 1 < w) gray[i + w + 1] += err * 1 / 16;
        }
      }
    }
    return bits;
  }

  /// Packs 1-bit row-major (top-down, 1=ON) pixels into BMP file bytes:
  /// [header] + 9792 bytes, bottom-up, 72 bytes/row, MSB-first.
  static Uint8List encodeBmp(Uint8List bits, {required Uint8List header}) {
    assert(bits.length == width * height,
        'bits must be ${width * height} bytes');
    assert(header.length == 64, 'header must be 64 bytes');

    final px = Uint8List(pixelBytes);
    for (var y = 0; y < height; y++) {
      final imageRow = y; // 0 = top
      final fileRow = height - 1 - y; // BMP is bottom-up
      for (var x = 0; x < width; x++) {
        if (bits[imageRow * width + x] == 1) {
          final idx = fileRow * rowBytes + (x ~/ 8);
          px[idx] = px[idx] | (0x80 >> (x % 8));
        }
      }
    }

    final out = Uint8List(bmpBytes);
    out.setRange(0, 64, header);
    out.setRange(64, bmpBytes, px);
    return out;
  }
}
