import 'dart:async';

import 'package:demo_ai_even/ble_manager.dart';
import 'package:demo_ai_even/controllers/bmp_update_manager.dart';
import 'package:demo_ai_even/services/keepalive_service.dart';
import 'package:demo_ai_even/services/proto.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'face_defs.dart';
import 'face_renderer.dart';

/// Drives the Apple-Watch-style face loop:
///
///   - renders the active face (576x136, 1-bit) and pushes it to BOTH arms
///     in parallel via the BMP pipeline
///   - per-face refresh cadence (clock: on the minute; text: on change;
///     link: every N seconds)
///   - single-tap L/R navigation (wrap-around), EvenAI long-press always wins
///   - pauses rendering while the glasses are off the face (wear events)
///   - keeps an eye on link health (success counter + LINK OK / NO LINK)
///   - starts/stops the iOS silent-audio keep-alive
///
/// All settings are persisted via SharedPreferences.
class FaceScheduler extends GetxService {
  FaceScheduler._();

  static FaceScheduler create() =>
      Get.put(FaceScheduler._(), permanent: true);
  static FaceScheduler get get => Get.find<FaceScheduler>();

  /// Face order; single-tap left/right cycles through this list (wrap-around).
  static const List<Face> faces = [ClockFace(), TextFace(), LinkFace()];

  final BmpUpdateManager _bmp = BmpUpdateManager();
  final FaceRenderer _renderer = FaceRenderer();

  // ---- settings (persisted) ----
  final RxBool facesEnabled = true.obs; // on by default: G1 behaves like a watch
  final RxBool keepAliveEnabled = true.obs; // silent-tone keep-alive, default ON
  final RxInt activeFaceIndex = 0.obs; // 0..faces.length-1
  final RxString customText = 'Hallo Even!'.obs;
  final RxInt linkIntervalSec = 2.obs; // clamped to 2..10

  // ---- runtime state ----
  final RxBool glassesWorn = true.obs;
  final RxBool pushing = false.obs;
  final RxInt linkCounter = 0.obs;
  final Rxn<DateTime> lastSuccessAt = Rxn<DateTime>();
  final Rxn<int> batteryL = Rxn<int>();
  final Rxn<int> batteryR = Rxn<int>();

  bool _connected = false;
  bool _initDone = false;
  Timer? _tick;
  int _tickCounter = 0;
  int _lastMinute = -1;
  int _lastLinkPushTick = -100000;
  String _lastPushedText = '';

  bool get connected => _connected;
  Face get activeFace => faces[activeFaceIndex.value % faces.length];

  /// Loads persisted settings, wires live observers, starts if already
  /// connected. Call once at app startup.
  Future<void> init() async {
    if (_initDone) return;
    _initDone = true;

    try {
      final prefs = await SharedPreferences.getInstance();
      facesEnabled.value = prefs.getBool('faces.enabled') ?? true;
      keepAliveEnabled.value = prefs.getBool('faces.keepalive') ?? true;
      activeFaceIndex.value = (prefs.getInt('faces.active') ?? 0) % faces.length;
      customText.value = prefs.getString('faces.text') ?? 'Hallo Even!';
      linkIntervalSec.value = _clampInterval(prefs.getInt('faces.linkInterval') ?? 2);
    } catch (e) {
      print('FaceScheduler init failed: $e');
    }

    facesEnabled.listen((_) {
      _persist();
      _onEnabledChanged();
    });
    keepAliveEnabled.listen((_) {
      _persist();
      _syncKeepAlive();
    });
    activeFaceIndex.listen((_) => _persist());
    customText.listen((_) {
      _persist();
      // live edit: refresh immediately while the text face is on the glasses
      if (activeFaceIndex.value == 1 &&
          _connected &&
          facesEnabled.value &&
          glassesWorn.value) {
        _lastPushedText = '';
        pushActiveFace();
      }
    });
    linkIntervalSec.listen((_) {
      linkIntervalSec.value = _clampInterval(linkIntervalSec.value);
      _persist();
    });

    if (BleManager.get().isConnected) {
      onConnected();
    }
  }

  // ---------------------------------------------------------------- settings

  /// int.clamp() returns num - keep the type int without a cast.
  static int _clampInterval(int v) => v < 2 ? 2 : (v > 10 ? 10 : v);

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await Future.wait([
        prefs.setBool('faces.enabled', facesEnabled.value),
        prefs.setBool('faces.keepalive', keepAliveEnabled.value),
        prefs.setInt('faces.active', activeFaceIndex.value),
        prefs.setString('faces.text', customText.value),
        prefs.setInt('faces.linkInterval', linkIntervalSec.value),
      ]);
    } catch (e) {
      print('FaceScheduler persist failed: $e');
    }
  }

  void _onEnabledChanged() {
    if (facesEnabled.value) {
      if (_connected) {
        _lastMinute = -1;
        pushActiveFace();
      }
    } else if (_connected) {
      // free the glasses so the user does not get stuck on a stale face
      exitToDashboard();
    }
    _syncKeepAlive();
  }

  // ------------------------------------------------------- connection events

  void onConnected() {
    if (_connected) return;
    _connected = true;
    _lastMinute = -1;
    _lastLinkPushTick = -100000;
    if (facesEnabled.value) {
      _startTicking();
      pushActiveFace();
    }
    _syncKeepAlive();
  }

  void onDisconnected() {
    if (!_connected) return;
    _connected = false;
    _tick?.cancel();
    _tick = null;
    lastSuccessAt.value = null;
    _syncKeepAlive();
  }

  // ----------------------------------------------------- wear + battery data

  /// 0xF5 idx 06 = worn / 07 = removed. While not worn we pause the face
  /// pump (battery saver) and push again as soon as the glasses are worn.
  void onWearChanged(bool worn) {
    if (glassesWorn.value == worn) return;
    glassesWorn.value = worn;
    if (worn && _connected && facesEnabled.value) {
      _lastMinute = -1;
      pushActiveFace();
    }
  }

  /// Battery percent per side from the 0x2C report (also pushed unsolicited).
  void onBattery(String lr, int percent) {
    if (percent < 0 || percent > 100) return;
    if (lr == 'L') {
      batteryL.value = percent;
    } else if (lr == 'R') {
      batteryR.value = percent;
    }
  }

  // ------------------------------------------------------------- navigation

  void nextFace() => _cycle(1);
  void prevFace() => _cycle(-1);

  void _cycle(int delta) {
    selectFace((activeFaceIndex.value + delta) % faces.length);
  }

  /// Selects a face (from tap navigation or the settings screen).
  void selectFace(int index) {
    activeFaceIndex.value =
        ((index % faces.length) + faces.length) % faces.length;
    if (_connected && facesEnabled.value && glassesWorn.value) {
      _lastMinute = -1;
      pushActiveFace();
    }
  }

  // ------------------------------------------------------------------ pump

  void _startTicking() {
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
  }

  void _onTick() {
    if (!_connected || !facesEnabled.value || !glassesWorn.value) return;
    if (pushing.value) return; // a push takes several seconds; never overlap
    _tickCounter++;

    final now = DateTime.now();
    final index = activeFaceIndex.value;
    if (index == 0) {
      // clock: on the minute
      if (now.minute != _lastMinute) {
        _lastMinute = now.minute;
        pushActiveFace();
      }
    } else if (index == 1) {
      // custom text: on change
      if (customText.value != _lastPushedText) {
        _lastPushedText = customText.value;
        pushActiveFace();
      }
    } else {
      // link/diagnostics: every N seconds (throughput is the real limiter)
      if (_tickCounter - _lastLinkPushTick >= linkIntervalSec.value) {
        _lastLinkPushTick = _tickCounter;
        pushActiveFace();
      }
    }
  }

  /// Renders the active face and pushes it to both arms in parallel
  /// (the BMP pipeline is the one both-arm flow that may run concurrently).
  Future<void> pushActiveFace() async {
    if (!_connected || !facesEnabled.value || pushing.value) return;
    pushing.value = true;
    final now = DateTime.now();
    try {
      final face = activeFace;
      final data = FaceData(
        now: now,
        connected: true,
        glassesWorn: glassesWorn.value,
        linkCounter: linkCounter.value,
        lastSuccessAt: lastSuccessAt.value,
        linkIntervalSec: linkIntervalSec.value,
        batteryL: batteryL.value,
        batteryR: batteryR.value,
        customText: customText.value,
      );
      final bits = await _renderer.renderBits(face, data);
      final bmp = FaceRenderer.encodeBmp(bits, header: await _renderer.header());
      final results = await Future.wait([
        _bmp.updateBmp('L', bmp),
        _bmp.updateBmp('R', bmp),
      ]);
      if (results[0] && results[1]) {
        linkCounter.value++;
        lastSuccessAt.value = DateTime.now();
      } else {
        print('FaceScheduler: push failed (L=${results[0]}, R=${results[1]})');
      }
    } catch (e) {
      print('FaceScheduler push failed: $e');
    } finally {
      _lastMinute = DateTime.now().minute;
      _lastPushedText = customText.value;
      _lastLinkPushTick = _tickCounter;
      pushing.value = false;
    }
  }

  /// 0x18: tell the glasses to go back to their dashboard.
  Future<void> exitToDashboard() async {
    if (!_connected) return;
    try {
      await Proto.exit();
    } catch (e) {
      print('FaceScheduler exitToDashboard failed: $e');
    }
  }

  // -------------------------------------------------------------- keep-alive

  void _syncKeepAlive() {
    final shouldRun =
        facesEnabled.value && _connected && keepAliveEnabled.value;
    KeepAliveService.get.set(shouldRun);
  }

  @override
  void onClose() {
    _tick?.cancel();
    _tick = null;
    try {
      KeepAliveService.get.stop();
    } catch (_) {
      // not registered (e.g. in tests) - nothing to stop
    }
    super.onClose();
  }
}
