import 'dart:async';

import 'package:demo_ai_even/faces/face_defs.dart';
import 'package:demo_ai_even/faces/face_scheduler.dart';
import 'package:flutter/material.dart';

/// Face settings: master switch, face picker, live preview (the exact
/// canvas code the glasses see), custom text editor, link-face refresh
/// interval and the keep-alive toggle.
class FaceSettingsPage extends StatefulWidget {
  const FaceSettingsPage({super.key});

  @override
  State<FaceSettingsPage> createState() => _FaceSettingsPageState();
}

class _FaceSettingsPageState extends State<FaceSettingsPage> {
  late final TextEditingController _textController;
  Timer? _previewTicker;

  @override
  void initState() {
    super.initState();
    _textController =
        TextEditingController(text: FaceScheduler.get.customText.value);
    // keep the preview moving (clock seconds, link status)
    _previewTicker =
        Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _previewTicker?.cancel();
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fs = FaceScheduler.get;
    return Scaffold(
      appBar: AppBar(title: const Text('Even Faces')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: SwitchListTile(
              title: const Text('Faces active'),
              subtitle: const Text(
                'Switch face: single tap on the LEFT or RIGHT touchpad.\n'
                'Even AI (long press left touchpad) still works in parallel.',
              ),
              value: fs.facesEnabled.value,
              onChanged: (v) => fs.facesEnabled.value = v,
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Preview (what the glasses show)',
                    style: TextStyle(fontSize: 14, color: Colors.grey),
                  ),
                  const SizedBox(height: 8),
                  _preview(fs),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          for (var i = 0; i < FaceScheduler.faces.length; i++)
            _faceTile(i, FaceScheduler.faces[i], fs),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Custom text (Text face)',
                    style: TextStyle(fontSize: 14, color: Colors.grey),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _textController,
                    maxLines: 3,
                    onChanged: (v) => fs.customText.value = v,
                    decoration: const InputDecoration(
                      hintText: 'Type something…',
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Link face refresh: ${fs.linkIntervalSec.value}s',
                    style: const TextStyle(fontSize: 14, color: Colors.grey),
                  ),
                  Slider(
                    value: fs.linkIntervalSec.value.toDouble(),
                    min: 2,
                    max: 10,
                    divisions: 8,
                    label: '${fs.linkIntervalSec.value}s',
                    onChanged: (v) => fs.linkIntervalSec.value = v.round(),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: SwitchListTile(
              title: const Text('Background keep-alive'),
              subtitle: const Text(
                'Silent audio loop keeps this app running in the iOS '
                'background so faces keep updating.',
              ),
              value: fs.keepAliveEnabled.value,
              onChanged: (v) => fs.keepAliveEnabled.value = v,
            ),
          ),
        ],
      ),
    );
  }

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
    final w = MediaQuery.of(context).size.width - 80;
    return Align(
      alignment: Alignment.centerLeft,
      child: SizedBox(
        width: w,
        height: w * kFaceHeight / kFaceWidth,
        child: CustomPaint(painter: _PreviewPainter(face, data)),
      ),
    );
  }

  Widget _faceTile(int index, Face face, FaceScheduler fs) {
    final active = fs.activeFaceIndex.value == index;
    const subs = ['updates every minute', 'your text', 'refresh + battery'];
    return GestureDetector(
      onTap: () => fs.selectFace(index),
      child: Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: active ? const Color(0xFF1B5E20) : Colors.white,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(
              active ? Icons.check_circle : Icons.radio_button_unchecked,
              color: active ? Colors.white : Colors.grey,
              size: 20,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    face.name,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: active ? Colors.white : Colors.black,
                    ),
                  ),
                  Text(
                    subs[index],
                    style: TextStyle(
                      fontSize: 12,
                      color: active
                          ? Colors.white.withOpacity(0.7)
                          : Colors.grey,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
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
      Rect.fromLTWH(0, 0, kFaceWidth, kFaceHeight),
      Paint()..color = Colors.black,
    );
    _face.paint(canvas, Size(kFaceWidth, kFaceHeight), _data);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PreviewPainter oldDelegate) => true;
}
