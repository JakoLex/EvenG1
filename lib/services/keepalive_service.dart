import 'dart:io';

import 'package:flutter/services.dart';
import 'package:get/get.dart';

/// Dart side of the silent-audio background keep-alive (see
/// ios/Runner/KeepAlive.swift).
///
/// While the Face engine is active the app must survive in the background.
/// `UIBackgroundModes: bluetooth-central` covers normal BLE sessions; the
/// looping silent tone is the belt-and-suspenders mechanism that keeps the
/// process alive indefinitely, unaffected by the silent switch.
class KeepAliveService extends GetxService {
  KeepAliveService._();

  static KeepAliveService create() =>
      Get.put(KeepAliveService._(), permanent: true);
  static KeepAliveService get get => Get.find<KeepAliveService>();

  static const MethodChannel _channel = MethodChannel('method.keepalive');

  /// Starts (on) or stops (off) the silent-tone keep-alive.
  ///
  /// On non-iOS platforms this is a no-op (the Android build of this demo
  /// does not declare the audio background mode).
  Future<bool> set(bool on) async {
    if (!Platform.isIOS) return false;
    try {
      final res = await _channel.invokeMethod<bool>(on ? 'start' : 'stop');
      return res ?? false;
    } catch (e) {
      print('KeepAliveService: $e');
      return false;
    }
  }

  Future<void> stop() => set(false);
}
