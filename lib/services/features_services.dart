import 'dart:typed_data';
import 'package:demo_ai_even/ble_manager.dart';
import 'package:demo_ai_even/controllers/bmp_update_manager.dart';
import 'package:demo_ai_even/services/proto.dart';
import 'package:demo_ai_even/utils/utils.dart';

class FeaturesServices {
  final bmpUpdateManager = BmpUpdateManager();
  Future<void> sendBmp(String imageUrl) async {
    Uint8List bmpData = await Utils.loadBmpImage(imageUrl);
    bool isSuccess = await Proto.sendHeartBeat();
    print("${DateTime.now()} testBMP -------startSendBeatHeart----isSuccess---$isSuccess------");
    BleManager.get().startSendBeatHeart();

    // Ordered dual-arm push: concurrent bulk data, then end marker and CRC
    // left-before-right so both halves latch the same frame.
    final results = await bmpUpdateManager.updateBmpBothArms(bmpData);

    bool successL = results.left;
    bool successR = results.right;

    if (successL) {
      print("${DateTime.now()} left ble success");
    } else {
      print("${DateTime.now()} left ble fail");
    }

    if (successR) {
      print("${DateTime.now()} right ble success");
    } else {
      print("${DateTime.now()} right ble fail");
    }
  }

  Future<void> exitBmp() async {
    bool isSuccess = await Proto.exit();
    print("exitBmp----isSuccess---$isSuccess--");
  }
}