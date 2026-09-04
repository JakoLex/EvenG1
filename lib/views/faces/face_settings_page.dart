import 'dart:async';

import 'package:demo_ai_even/faces/face_defs.dart';
import 'package:demo_ai_even/faces/face_scheduler.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// Face settings: how it works, live preview (the exact canvas code the
/// glasses see), face picker, custom text, link-face refresh interval and the
/// background keep-alive.
class FaceSettingsPage extends StatefulWidget {
  const FaceSettingsPage({super.key});

  @override
  State<FaceSettingsPage> createState() => _FaceSettingsPageState();
}

/// Waveguide green - the panel is a green monochrome micro-LED.
const Color kPanelGreen = Color(0xFF35E07F);
const Color kPanelBlack = Color(0xFF07120C);
const double kRadius = 16;

class _FaceSettingsPageState extends State<FaceSettingsPage> {
  late final TextEditingController _textController;
  Timer? _previewTicker;
  Timer? _textDebounce;
  String? _pendingText;

  @override
  void initState() {
    super.initState();
    _textController =
        TextEditingController(text: FaceScheduler.get.customText.value);
    // keeps the preview moving (clock seconds, link status); the rest of the
    // page is reactive through Obx and does not depend on this.
    _previewTicker =
        Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _previewTicker?.cancel();
    _textDebounce?.cancel();
    _commitText(); // do not drop what was typed right before leaving
    _textController.dispose();
    super.dispose();
  }

  /// Every keystroke persists the text and (on the text face) triggers a BMP
  /// push that takes seconds - so only commit once typing pauses.
  void _onTextChanged(String value) {
    _pendingText = value;
    _textDebounce?.cancel();
    _textDebounce = Timer(const Duration(milliseconds: 500), _commitText);
  }

  void _commitText() {
    final value = _pendingText;
    _pendingText = null;
    if (value != null) {
      FaceScheduler.get.customText.value = value;
    }
  }

  @override
  Widget build(BuildContext context) {
    final fs = FaceScheduler.get;
    return Scaffold(
      backgroundColor: const Color(0xFFF2F3F5),
      appBar: AppBar(
        title: const Text('Even Faces'),
        backgroundColor: Colors.white,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          _masterSwitch(fs),
          const SizedBox(height: 12),
          _howItWorks(),
          const SizedBox(height: 12),
          _previewCard(fs),
          const SizedBox(height: 12),
          _sectionLabel('Face auswählen'),
          Obx(() => Column(
                children: [
                  for (var i = 0; i < FaceScheduler.faces.length; i++)
                    _faceTile(i, FaceScheduler.faces[i], fs),
                ],
              )),
          const SizedBox(height: 20),
          _sectionLabel('Eigener Text'),
          _textCard(),
          const SizedBox(height: 20),
          _sectionLabel('Aktualisierung'),
          _intervalCard(fs),
          const SizedBox(height: 20),
          _sectionLabel('Hintergrund'),
          _keepAliveCard(fs),
        ],
      ),
    );
  }

  // ------------------------------------------------------------- building

  Widget _card({required Widget child, EdgeInsets? padding}) => Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(kRadius),
        ),
        padding: padding ?? const EdgeInsets.all(16),
        child: child,
      );

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 8),
        child: Text(
          text.toUpperCase(),
          style: const TextStyle(
            fontSize: 12,
            letterSpacing: 0.8,
            fontWeight: FontWeight.w600,
            color: Colors.black54,
          ),
        ),
      );

  Widget _masterSwitch(FaceScheduler fs) => Obx(() {
        final on = fs.facesEnabled.value;
        return Container(
          decoration: BoxDecoration(
            color: on ? const Color(0xFF14351F) : Colors.white,
            borderRadius: BorderRadius.circular(kRadius),
          ),
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Row(
            children: [
              Icon(Icons.watch_later_outlined,
                  color: on ? kPanelGreen : Colors.black38),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Faces aktiv',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: on ? Colors.white : Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      on
                          ? 'Die Brille zeigt das gewählte Face'
                          : 'Die Brille zeigt ihr eigenes Dashboard',
                      style: TextStyle(
                        fontSize: 12,
                        color: on ? Colors.white70 : Colors.black54,
                      ),
                    ),
                  ],
                ),
              ),
              Switch(
                value: on,
                activeColor: kPanelGreen,
                onChanged: (v) => fs.facesEnabled.value = v,
              ),
            ],
          ),
        );
      });

  Widget _howItWorks() => _card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.help_outline, size: 18, color: Colors.black54),
                SizedBox(width: 8),
                Text('So funktioniert es',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 12),
            _bullet(Icons.touch_app_outlined, 'Face wechseln',
                'Einmal auf das linke oder rechte Touchpad tippen. Even AI (langes Drücken links) funktioniert weiter.'),
            _bullet(Icons.visibility_outlined, 'Nur beim Tragen',
                'Nimmst du die Brille ab, pausiert die Aktualisierung und spart Akku. Beim Aufsetzen geht es sofort weiter.'),
            _bullet(Icons.speed_outlined, 'Tempo',
                'Ein voller Bildaufbau dauert rund eine Sekunde pro Bügel. Deshalb läuft die Uhr auf Minuten, nicht auf Sekunden.'),
            _bullet(Icons.battery_saver_outlined, 'Verbindung',
                'Bricht die Verbindung ab, verbindet die App automatisch neu — zuerst im 2-Sekunden-Takt, danach in größeren Abständen.',
                last: true),
          ],
        ),
      );

  Widget _bullet(IconData icon, String title, String body,
          {bool last = false}) =>
      Padding(
        padding: EdgeInsets.only(bottom: last ? 0 : 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: kPanelGreen.withOpacity(0.9)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: 13.5, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(body,
                      style: const TextStyle(
                          fontSize: 12.5, height: 1.35, color: Colors.black54)),
                ],
              ),
            ),
          ],
        ),
      );

  Widget _previewCard(FaceScheduler fs) => _card(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
              child: Row(
                children: [
                  const Icon(Icons.visibility, size: 16, color: Colors.black54),
                  const SizedBox(width: 6),
                  const Text('Vorschau',
                      style: TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600)),
                  const Spacer(),
                  Obx(() => Text(
                        '576 × 136 px  ·  ${FaceScheduler.faces[fs.activeFaceIndex.value].name}',
                        style: const TextStyle(
                            fontSize: 11, color: Colors.black45),
                      )),
                ],
              ),
            ),
            _preview(fs),
            const SizedBox(height: 6),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                'Genau dieses Bild geht an beide Gläser.',
                style: TextStyle(fontSize: 11.5, color: Colors.black45),
              ),
            ),
          ],
        ),
      );

  Widget _preview(FaceScheduler fs) {
    final face = FaceScheduler.faces[fs.activeFaceIndex.value];
    final data = FaceData(
      now: DateTime.now(),
      connected: fs.connected,
      glassesWorn: fs.glassesWorn.value,
      linkCounter: fs.linkCounter.value,
      lastSuccessAt: fs.lastSuccessAt.value,
      linkIntervalSec: fs.linkIntervalSec.value,
      batteryL: fs.batteryL.value,
      batteryR: fs.batteryR.value,
      customText: fs.customText.value,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        return ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Container(
            color: kPanelBlack,
            width: w,
            height: w * kFaceHeight / kFaceWidth,
            // white-on-black canvas, tinted to the panel's green
            child: ColorFiltered(
              colorFilter: const ColorFilter.matrix(<double>[
                0, 0, 0, 0, 0, //
                0.30, 0.59, 0.11, 0, 0, //
                0.10, 0.20, 0.04, 0, 0, //
                0, 0, 0, 1, 0, //
              ]),
              child: CustomPaint(painter: _PreviewPainter(face, data)),
            ),
          ),
        );
      },
    );
  }

  Widget _faceTile(int index, Face face, FaceScheduler fs) {
    final active = fs.activeFaceIndex.value == index;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: active ? const Color(0xFF14351F) : Colors.white,
        borderRadius: BorderRadius.circular(kRadius),
        child: InkWell(
          borderRadius: BorderRadius.circular(kRadius),
          onTap: () => fs.selectFace(index),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            child: Row(
              children: [
                Icon(
                  active
                      ? Icons.check_circle
                      : Icons.radio_button_unchecked,
                  color: active ? kPanelGreen : Colors.black26,
                  size: 22,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        face.name,
                        style: TextStyle(
                          fontSize: 15.5,
                          fontWeight: FontWeight.w600,
                          color: active ? Colors.white : Colors.black87,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        face.description,
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.3,
                          color: active ? Colors.white70 : Colors.black54,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _textCard() => _card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _textController,
              maxLines: 3,
              onChanged: _onTextChanged,
              decoration: InputDecoration(
                hintText: 'Schreib etwas …',
                filled: true,
                fillColor: const Color(0xFFF4F5F7),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.all(14),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Wird auf dem Text-Face angezeigt, maximal vier Zeilen. '
              'Die Brille aktualisiert kurz nachdem du aufhörst zu tippen.',
              style: TextStyle(fontSize: 12, height: 1.35, color: Colors.black54),
            ),
          ],
        ),
      );

  Widget _intervalCard(FaceScheduler fs) => _card(
        child: Obx(() => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text('Link-Face: Aktualisierung',
                          style: TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600)),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE8F5EC),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text('alle ${fs.linkIntervalSec.value} s',
                          style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF14351F))),
                    ),
                  ],
                ),
                Slider(
                  value: fs.linkIntervalSec.value.toDouble(),
                  min: 2,
                  max: 10,
                  divisions: 8,
                  activeColor: const Color(0xFF14351F),
                  label: '${fs.linkIntervalSec.value}s',
                  onChanged: (v) => fs.linkIntervalSec.value = v.round(),
                ),
                const Text(
                  'Betrifft nur das Link-Face. Uhr und Text aktualisieren, '
                  'wenn sich etwas ändert.',
                  style: TextStyle(
                      fontSize: 12, height: 1.35, color: Colors.black54),
                ),
              ],
            )),
      );

  Widget _keepAliveCard(FaceScheduler fs) => _card(
        child: Obx(() => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text('Im Hintergrund aktiv halten',
                          style: TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600)),
                    ),
                    Switch(
                      value: fs.keepAliveEnabled.value,
                      activeColor: kPanelGreen,
                      onChanged: (v) => fs.keepAliveEnabled.value = v,
                    ),
                  ],
                ),
                const Text(
                  'Spielt eine lautlose Tonspur, damit iOS die App im '
                  'Hintergrund nicht beendet und die Faces weiterlaufen. '
                  'Kostet etwas Akku — zum Sparen ausschalten.',
                  style: TextStyle(
                      fontSize: 12, height: 1.35, color: Colors.black54),
                ),
              ],
            )),
      );
}

/// Draws the exact 576x136 face canvas, scaled to the widget size.
class _PreviewPainter extends CustomPainter {
  final Face _face;
  final FaceData _data;

  _PreviewPainter(this._face, this._data);

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / kFaceWidth;
    canvas.save();
    canvas.scale(scale, scale);
    canvas.drawRect(
      Rect.fromLTWH(0.0, 0.0, kFaceWidth.toDouble(), kFaceHeight.toDouble()),
      Paint()..color = Colors.black,
    );
    _face.paint(
        canvas, Size(kFaceWidth.toDouble(), kFaceHeight.toDouble()), _data);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PreviewPainter oldDelegate) => true;
}
