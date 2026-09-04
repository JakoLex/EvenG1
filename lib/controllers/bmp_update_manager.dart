import 'dart:io';
import 'dart:typed_data';

import 'package:crclib/catalog.dart';
import 'package:demo_ai_even/ble_manager.dart';
import 'package:demo_ai_even/utils/utils.dart';

/// BMP transfer to the glasses, in three phases (see
/// docs/G1_PROTOCOL_REFERENCE.md §3.1):
///
///   1. `0x15` chunks  - 194 bytes each, written to arm-local storage
///   2. `0x20 0D 0E`   - end marker, acknowledged with `0xC9`
///   3. `0x16 <crc32>` - CRC over address + file; this is what makes the
///                       arm latch the new frame
///
/// Phase 1 may run on both arms concurrently, phases 2 and 3 must not: §2.4
/// requires display-affecting commands to go left first, wait for the
/// acknowledgement, then right. Doing all three phases concurrently (the old
/// `Future.wait([updateBmp("L"), updateBmp("R")])`) lets the two halves latch
/// at different moments, which reads as a torn or out-of-sync display.
/// [updateBmpBothArms] implements the ordered variant.
class BmpUpdateManager {
  static const int _packLen = 194; //198;

  /// Number of transfers currently on the wire. The face pump uses this to
  /// stay off the link while e.g. the BMP demo page is sending.
  static int _activeTransfers = 0;
  static bool get isTransferring => _activeTransfers > 0;

  /// Single arm, all three phases. Used by the BMP demo page.
  Future<bool> updateBmp(String lr, Uint8List image, {int? seq}) async {
    _activeTransfers++;
    try {
      if (!await _sendChunks(lr, image, seq: seq)) return false;
      if (!await _sendEnd(lr)) return false;
      return await _sendCrc(lr, image);
    } finally {
      _activeTransfers--;
    }
  }

  /// Both arms, ordered so that they latch the same frame as closely together
  /// as the link allows. Returns the per-arm outcome so the caller can retry
  /// just the arm that dropped out.
  Future<({bool left, bool right})> updateBmpBothArms(Uint8List image) async {
    _activeTransfers++;
    try {
      // Phase 1: bulk data. Concurrent is fine - this only fills arm-local
      // storage and nothing is displayed yet.
      final chunks = await Future.wait([
        _sendChunks('L', image),
        _sendChunks('R', image),
      ]);
      var okL = chunks[0];
      var okR = chunks[1];

      // Phases 2 and 3: one command at a time, left before right.
      if (okL) okL = await _sendEnd('L');
      if (okR) okR = await _sendEnd('R');
      if (okL) okL = await _sendCrc('L', image);
      if (okR) okR = await _sendCrc('R', image);

      return (left: okL, right: okR);
    } finally {
      _activeTransfers--;
    }
  }

  /// Phase 1 - `0x15` chunks. [seq] resumes a partial transfer.
  Future<bool> _sendChunks(String lr, Uint8List image, {int? seq}) async {
    final List<Uint8List> multiPacks = [];
    for (int i = 0; i < image.length; i += _packLen) {
      final int end =
          (i + _packLen < image.length) ? i + _packLen : image.length;
      multiPacks.add(image.sublist(i, end));
    }

    // The chunk index is a single byte on the wire - refuse rather than wrap.
    if (multiPacks.length > 256) {
      print('BmpUpdate -> $lr: ${multiPacks.length} packs exceed the 1-byte '
          'index, aborting');
      return false;
    }

    print('BmpUpdate -> $lr: sending ${multiPacks.length} packs');

    for (int index = 0; index < multiPacks.length; index++) {
      if (seq != null && index < seq) continue;

      final pack = multiPacks[index];
      // Pack 0 carries the destination address [0x00, 0x1c, 0x00, 0x00].
      final Uint8List data = index == 0
          ? Utils.addPrefixToUint8List(
              [0x15, index & 0xff, 0x00, 0x1c, 0x00, 0x00], pack)
          : Utils.addPrefixToUint8List([0x15, index & 0xff], pack);

      await BleManager.sendData(data, lr: lr);
      await Future.delayed(
        Duration(milliseconds: Platform.isIOS ? 8 : 5), // 4 6 10 14 30 / 5
      );
    }
    return true;
  }

  /// Phase 2 - `BMP_END`, retried until the arm acknowledges with 0xC9.
  Future<bool> _sendEnd(String lr) async {
    const maxRetryTime = 10;
    for (var attempt = 0; attempt < maxRetryTime; attempt++) {
      final ret = await BleManager.request(
        Uint8List.fromList([0x20, 0x0d, 0x0e]),
        lr: lr,
        timeoutMs: 3000,
      );
      if (ret.isTimeout) {
        print('BmpUpdate -> $lr: end marker timed out (${attempt + 1}'
            '/$maxRetryTime)');
        await Future.delayed(const Duration(seconds: 1));
        continue;
      }
      final ok = ret.data.length > 1 && ret.data[1].toInt() == 0xc9;
      if (!ok) print('BmpUpdate -> $lr: end marker rejected: ${ret.data}');
      return ok;
    }
    return false;
  }

  /// Phase 3 - `BMP_CRC` over the storage address followed by the file.
  Future<bool> _sendCrc(String lr, Uint8List image) async {
    final crc32 = Crc32Xz().convert(prependAddress(image));
    final val = crc32.toBigInt().toInt();
    final crc = Uint8List.fromList([
      val >> 8 * 3 & 0xff,
      val >> 8 * 2 & 0xff,
      val >> 8 & 0xff,
      val & 0xff,
    ]);

    final ret = await BleManager.request(
      Utils.addPrefixToUint8List([0x16], crc),
      lr: lr,
    );

    if (ret.isTimeout) {
      print('BmpUpdate -> $lr: CRC check timed out');
      return false;
    }
    // Reply is [0x16, ..., 0xC9] - guard the index, a short reply used to
    // throw a RangeError right here.
    if (ret.data.length > 5 && ret.data[5].toInt() != 0xc9) {
      print('BmpUpdate -> $lr: CRC check failed: ${ret.data}');
      return false;
    }
    return true;
  }

  Uint8List prependAddress(Uint8List image) {
    const addressBytes = [0x00, 0x1c, 0x00, 0x00];
    final newImage = Uint8List(addressBytes.length + image.length);
    newImage.setRange(0, addressBytes.length, addressBytes);
    newImage.setRange(addressBytes.length, newImage.length, image);
    return newImage;
  }
}
