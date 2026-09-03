import 'package:flutter/material.dart';

/// One rendered frame of a face: the G1 panel is 576 x 136, 1-bit.
const int kFaceWidth = 576;
const int kFaceHeight = 136;

/// Snapshot of everything a face may need to draw.
class FaceData {
  final DateTime now;
  final bool connected;
  final bool glassesWorn;
  final int linkCounter;
  final DateTime? lastSuccessAt;
  final int linkIntervalSec;
  final int? batteryL; // 0..100, null = unknown
  final int? batteryR;
  final String customText;

  const FaceData({
    required this.now,
    required this.connected,
    required this.glassesWorn,
    required this.linkCounter,
    required this.lastSuccessAt,
    required this.linkIntervalSec,
    this.batteryL,
    this.batteryR,
    this.customText = '',
  });

  /// LINK OK when the last full push (L+R) succeeded within 3 refresh
  /// intervals; otherwise NO LINK.
  bool get linkOk {
    final last = lastSuccessAt;
    if (last == null) return false;
    return now.difference(last) < Duration(seconds: 3 * linkIntervalSec);
  }
}

/// A face = a name + a paint function. All faces draw white on black;
/// the 1-bit dithering (see FaceRenderer) turns it into green pixels.
abstract class Face {
  const Face();

  String get id;
  String get name;

  void paint(Canvas canvas, Size size, FaceData data);

  static String _two(int v) => v.toString().padLeft(2, '0');

  static String hhmm(DateTime d) => '${_two(d.hour)}:${_two(d.minute)}';

  static String hhmmss(DateTime d) => '${_two(d.hour)}:${_two(d.minute)}:${_two(d.second)}';

  /// "Mi, 24.09." – short weekday + day.month (German, locale of the device).
  static const _weekdayDe = ['So', 'Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa'];

  static String shortDate(DateTime d) =>
      '${_weekdayDe[d.weekday % 7]}, ${_two(d.day)}.${_two(d.month)}.';

  static void paintText(
    Canvas canvas,
    String text, {
    required double size,
    required Offset position,
    FontWeight weight = FontWeight.normal,
    double? maxWidth,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: Colors.white,
          fontSize: size,
          fontWeight: weight,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxWidth: maxWidth,
    )..layout();
    tp.paint(canvas, position);
  }
}

/// Face 0 – Clock: HH:MM + short date. Refreshes on the minute.
class ClockFace extends Face {
  const ClockFace();

  @override
  String get id => 'clock';
  @override
  String get name => 'Clock';

  @override
  void paint(Canvas canvas, Size size, FaceData data) {
    final now = data.now;
    // hero time, centered
    final time = Face.hhmm(now);
    final tp = TextPainter(
      text: TextSpan(
        text: time,
        style: TextStyle(color: Colors.white, fontSize: 72, fontWeight: FontWeight.bold),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset((size.width - tp.width) / 2, 8));
    // date below
    final dt = TextPainter(
      text: TextSpan(
        text: Face.shortDate(now),
        style: TextStyle(color: Colors.white, fontSize: 20),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    dt.paint(canvas, Offset((size.width - dt.width) / 2, 96));
  }
}

/// Face 1 – Custom text: multi-line user text, persisted.
/// Refreshes when the text changes (and on face switch / wear).
class TextFace extends Face {
  const TextFace();

  @override
  String get id => 'text';
  @override
  String get name => 'Text';

  @override
  void paint(Canvas canvas, Size size, FaceData data) {
    final text = data.customText.trim().isEmpty ? '(empty)' : data.customText;
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: Colors.white, fontSize: 22, height: 1.35),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
      maxWidth: size.width - 40,
    )..layout();

    // cap to ~5 lines
    final maxLines = 5;
    final blockHeight = tp.height > maxLines * 22 * 1.35
        ? maxLines * 22 * 1.35
        : tp.height;
    final y = (size.height - blockHeight) / 2;
    final x = (size.width - (tp.width > 0 ? tp.width : 0)) / 2;
    tp.paint(canvas, Offset(x.clamp(20.0, size.width - 20.0), y));
  }
}

/// Face 2 – Link / diagnostics: HH:MM:SS (updates every push, so the
/// refresh cadence is visible), LINK OK / NO LINK with success counter and
/// per-side G1 battery.
class LinkFace extends Face {
  const LinkFace();

  @override
  String get id => 'link';
  @override
  String get name => 'Link';

  @override
  void paint(Canvas canvas, Size size, FaceData data) {
    // HH:MM:SS hero
    final t = TextPainter(
      text: TextSpan(
        text: Face.hhmmss(data.now),
        style: TextStyle(color: Colors.white, fontSize: 44, fontWeight: FontWeight.bold),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    t.paint(canvas, Offset((size.width - t.width) / 2, 4));

    // link status
    final status = data.linkOk
        ? 'LINK OK  #${data.linkCounter}'
        : (data.lastSuccessAt == null
            ? 'NO LINK'
            : 'NO LINK (last ${Face.hhmm(data.lastSuccessAt!)})');
    Face.paintText(canvas, status, size: 19, position: _centered(canvas, size, status, 19, 62));

    // battery per side
    final String bl = data.batteryL == null ? 'L  --' : 'L ${data.batteryL}%';
    final String br = data.batteryR == null ? 'R  --' : 'R ${data.batteryR}%';
    final batt = 'BATT   $bl   $br';
    Face.paintText(canvas, batt, size: 19, position: _centered(canvas, size, batt, 19, 98));
  }

  Offset _centered(Canvas canvas, Size size, String text, double fontSize, double y) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: TextStyle(color: Colors.white, fontSize: fontSize)),
      textDirection: TextDirection.ltr,
    )..layout();
    return Offset((size.width - tp.width) / 2, y);
  }
}
