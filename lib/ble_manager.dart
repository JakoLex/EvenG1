import 'dart:async';
import 'dart:typed_data';

import 'package:demo_ai_even/app.dart';
import 'package:demo_ai_even/faces/face_scheduler.dart';
import 'package:demo_ai_even/services/ble.dart';
import 'package:demo_ai_even/services/evenai.dart';
import 'package:demo_ai_even/services/proto.dart';
import 'package:flutter/services.dart';

typedef SendResultParse = bool Function(Uint8List value);

class BleManager {
  Function()? onStatusChanged;
  BleManager._() {}

  static BleManager? _instance;
  static BleManager get() {
    if (_instance == null) {
      _instance ??= BleManager._();
      _instance!._init();
    }
    return _instance!;
  }

  static const methodSend = "send";
  static const _eventBleReceive = "eventBleReceive";
  static const _channel = MethodChannel('method.bluetooth');
  
  final eventBleReceive = const EventChannel(_eventBleReceive)
      .receiveBroadcastStream(_eventBleReceive)
      .map((ret) => BleReceive.fromMap(ret));

  Timer? beatHeartTimer;
  
  final List<Map<String, String>> pairedGlasses = [];
  bool isConnected = false;
  String connectionStatus = 'Not connected';

  void _init() {}

  void startListening() {
    eventBleReceive.listen((res) {
      _handleReceivedData(res);
    });
  }

  Future<void> startScan() async {
    try {
      await _channel.invokeMethod('startScan');
    } catch (e) {
      print('Error starting scan: $e');
    }
  }

  Future<void> stopScan() async {
    try {
      await _channel.invokeMethod('stopScan');
    } catch (e) {
      print('Error stopping scan: $e');
    }
  }

  Future<void> connectToGlasses(String deviceName) async {
    try {
      await _channel.invokeMethod('connectToGlasses', {'deviceName': deviceName});
      connectionStatus = 'Connecting...';
    } catch (e) {
      print('Error connecting to device: $e');
    }
  }

  void setMethodCallHandler() {
    _channel.setMethodCallHandler(_methodCallHandler);
  }

  Future<void> _methodCallHandler(MethodCall call) async {
    switch (call.method) {
      case 'glassesConnected':
        _onGlassesConnected(call.arguments);
        break;
      case 'glassesConnecting':
        _onGlassesConnecting();
        break;
      case 'glassesDisconnected':
        _onGlassesDisconnected();
        break;
      case 'foundPairedGlasses':
        _onPairedGlassesFound(Map<String, String>.from(call.arguments));
        break;
      default:
        print('Unknown method: ${call.method}');
    }
  }

  void _onGlassesConnected(dynamic arguments) {
    print("_onGlassesConnected----arguments----$arguments------");
    connectionStatus = 'Connected: \n${arguments['leftDeviceName']} \n${arguments['rightDeviceName']}';
    isConnected = true;

    final leftName = arguments['leftDeviceName'] as String? ?? '';
    _lastChannelNumber = _channelFromName(leftName);
    _stopReconnect();

    onStatusChanged?.call();
    startSendBeatHeart();
    _initGlassesSession();
  }

  /// Session init after (re-)connect, from the community protocol research:
  ///  - 0x4D 0xFB INIT on the LEFT arm (the official app always sends this;
  ///    some features misbehave without it)
  ///  - 0x27 0x01 wear detection ON (enables 0xF5 06/07 worn/removed events)
  ///  - 0x2C 0x01 battery read (reply is handled in _handleReceivedData,
  ///    battery levels also arrive as unsolicited pushes)
  Future<void> _initGlassesSession() async {
    try {
      await request(Uint8List.fromList([0x4D, 0xFB]), lr: 'L', timeoutMs: 1500);
      final wearL =
          await request(Uint8List.fromList([0x27, 0x01]), lr: 'L', timeoutMs: 1500);
      if (!wearL.isTimeout) {
        await request(Uint8List.fromList([0x27, 0x01]), lr: 'R', timeoutMs: 1500);
      }
      await sendData(Uint8List.fromList([0x2C, 0x01]), lr: 'L');
      await sendData(Uint8List.fromList([0x2C, 0x01]), lr: 'R');
    } catch (e) {
      print('Glasses session init failed: $e');
    }
    FaceScheduler.get.onConnected();
  }

  int tryTime = 0;
  void startSendBeatHeart() async {
    beatHeartTimer?.cancel();
    beatHeartTimer = null;

    beatHeartTimer = Timer.periodic(Duration(seconds: 8), (timer) async {
      bool isSuccess = await Proto.sendHeartBeat();
      if (!isSuccess && tryTime < 2) {
        tryTime++;
        await Proto.sendHeartBeat();
      } else {
        tryTime = 0;
      }
    });
  }

  void _onGlassesConnecting() {
    connectionStatus = 'Connecting...';

      onStatusChanged?.call();
  }

  void _onGlassesDisconnected() {
    connectionStatus = 'Not connected';
    isConnected = false;

    onStatusChanged?.call();
    FaceScheduler.get.onDisconnected();
    // A failed reconnect attempt reports this event too - in both cases the
    // chain continues (a new chain starts if none is running).
    if (_reconnectActive) {
      _scheduleNextReconnect();
    } else {
      _startReconnect();
    }
  }

  // ------------------------------------------------------- auto-reconnect
  // Strategy from G1_Extended: retry every 2 s for the first 30 s, then
  // ramp the delay up to 5 min. Gives up after ~2 h of attempts so we do
  // not fight the official Even G1 app forever.
  String? _lastChannelNumber;
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  bool _reconnectActive = false;
  static const int _maxReconnectAttempts = 40;

  /// "Even G1_<channel>_<L|R>_<serial>" -> "<channel>"
  String? _channelFromName(String name) {
    final parts = name.split('_');
    if (parts.length >= 3 && parts[0].trim().startsWith('Even G1')) {
      return parts[1];
    }
    return null;
  }

  void _startReconnect() {
    if (_lastChannelNumber == null) return;
    _reconnectActive = true;
    _reconnectAttempt = 0;
    _scheduleNextReconnect();
  }

  void _stopReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectActive = false;
    _reconnectAttempt = 0;
  }

  void _scheduleNextReconnect() {
    final channel = _lastChannelNumber;
    if (isConnected || !_reconnectActive || channel == null) return;
    if (_reconnectAttempt >= _maxReconnectAttempts) {
      print('AutoReconnect: giving up after $_maxReconnectAttempts attempts');
      _stopReconnect();
      return;
    }
    _reconnectAttempt++;
    final attempt = _reconnectAttempt;
    final delay = _reconnectDelaySec();
    print('AutoReconnect: attempt $attempt in ${delay}s');
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: delay), () {
      if (isConnected || connectionStatus == 'Connecting...') return;
      print('AutoReconnect: connecting to Pair_$channel (attempt $attempt)');
      connectToGlasses('Pair_$channel');
      // Fallback: if the native connect neither connects nor reports a
      // disconnect (device off), do not hang in "Connecting..." forever.
      _reconnectTimer = Timer(const Duration(seconds: 12), () {
        if (isConnected) return;
        if (connectionStatus == 'Connecting...') {
          connectionStatus = 'Not connected';
          onStatusChanged?.call();
        }
        _scheduleNextReconnect();
      });
    });
  }

  int _reconnectDelaySec() {
    if (_reconnectAttempt <= 15) return 2;
    var d = 30;
    var i = _reconnectAttempt - 15;
    while (i > 1 && d < 300) {
      d = (d * 2) > 300 ? 300 : d * 2;
      i--;
    }
    return d;
  }

  void _onPairedGlassesFound(Map<String, String> deviceInfo) {
    final String channelNumber = deviceInfo['channelNumber']!;
    final isAlreadyPaired = pairedGlasses.any((glasses) => glasses['channelNumber'] == channelNumber);

    if (!isAlreadyPaired) {
      pairedGlasses.add(deviceInfo);
    }

    onStatusChanged?.call();
  }

  void _handleReceivedData(BleReceive res) {
    if (res.type == "VoiceChunk") {
      return;
    }

    String cmd = "${res.lr}${res.getCmd().toRadixString(16).padLeft(2, '0')}";
    if (res.getCmd() != 0xf1) {
      print(
        "${DateTime.now()} BleManager receive cmd: $cmd, len: ${res.data.length}, data = ${res.data.hexString}",
      );
    }

    // Battery level report per side: [0x2C, 0x66, percent 0-100, ...]
    // (reply to GET_BATTERY and also pushed unsolicited)
    if (res.data[0].toInt() == 0x2C &&
        res.data.length >= 3 &&
        res.data[1].toInt() == 0x66) {
      FaceScheduler.get.onBattery(res.lr, res.data[2].toInt());
      return;
    }

    if (res.data[0].toInt() == 0xF5) {
      final notifyIndex = res.data[1].toInt();

      switch (notifyIndex) {
        case 0:
          App.get.exitAll();
          break;
        case 1: // single tap
          // Faces mode wins for single taps unless EvenAI is actively
          // running (long-press flow) - then EvenAI paging keeps working.
          if (FaceScheduler.get.facesEnabled.value &&
              !EvenAI.isRunning) {
            if (res.lr == 'L') {
              FaceScheduler.get.prevFace();
            } else {
              FaceScheduler.get.nextFace();
            }
          } else if (res.lr == 'L') {
            EvenAI.get.lastPageByTouchpad();
          } else {
            EvenAI.get.nextPageByTouchpad();
          }
          break;
        case 6: // worn
          FaceScheduler.get.onWearChanged(true);
          break;
        case 7: // removed
          FaceScheduler.get.onWearChanged(false);
          break;
        case 23: //BleEvent.evenaiStart:
          EvenAI.get.toStartEvenAIByOS();
          break;
        case 24: //BleEvent.evenaiRecordOver:
          EvenAI.get.recordOverByOS();
          break;
        default:
          print("Unknown Ble Event: $notifyIndex");
      }
      return;
    }
      _reqListen.remove(cmd)?.complete(res);
      _reqTimeout.remove(cmd)?.cancel();
      if (_nextReceive != null) {
        _nextReceive?.complete(res);
        _nextReceive = null;
      }

  }

  String getConnectionStatus() {
    return connectionStatus;
  }

  List<Map<String, String>> getPairedGlasses() {
    return pairedGlasses;
  }


  static final _reqListen = <String, Completer<BleReceive>>{};
  static final _reqTimeout = <String, Timer>{};
  static Completer<BleReceive>? _nextReceive;

  static _checkTimeout(String cmd, int timeoutMs, Uint8List data, String lr) {
    _reqTimeout.remove(cmd);
    var cb = _reqListen.remove(cmd);
    print('${DateTime.now()} _checkTimeout-----timeoutMs----$timeoutMs-----cb----$cb-----');
    if (cb != null) {
      var res = BleReceive();
      res.isTimeout = true;
      //var showData = data.length > 50 ? data.sublist(0, 50) : data;
      print(
          "send Timeout $cmd of $timeoutMs");
      cb.complete(res);
    }

    _reqTimeout[cmd]?.cancel();
    _reqTimeout.remove(cmd);
  }

  static Future<T?> invokeMethod<T>(String method, [dynamic params]) {
    return _channel.invokeMethod(method, params);
  }

  static Future<BleReceive> requestRetry(
    Uint8List data, {
    String? lr,
    Map<String, dynamic>? other,
    int timeoutMs = 200,
    bool useNext = false,
    int retry = 3,
  }) async {
    BleReceive ret;
    for (var i = 0; i <= retry; i++) {
      ret = await request(data,
          lr: lr, other: other, timeoutMs: timeoutMs, useNext: useNext);
      if (!ret.isTimeout) {
        return ret;
      }
      if (!BleManager.isBothConnected()) {
        break;
      }
    }
    ret = BleReceive();
    ret.isTimeout = true;
    print(
        "requestRetry $lr timeout of $timeoutMs");
    return ret;
  }

  static Future<bool> sendBoth(
    data, {
    int timeoutMs = 250,
    SendResultParse? isSuccess,
    int? retry,
  }) async {

    var ret = await BleManager.requestRetry(data,
        lr: "L", timeoutMs: timeoutMs, retry: retry ?? 0);
    if (ret.isTimeout) {
      print("sendBoth L timeout");

      return false;
    } else if (isSuccess != null) {
      final success = isSuccess.call(ret.data);
      if (!success) return false;
      var retR = await BleManager.requestRetry(data,
          lr: "R", timeoutMs: timeoutMs, retry: retry ?? 0);
      if (retR.isTimeout) return false;
      return isSuccess.call(retR.data);
    } else if (ret.data[1].toInt() == 0xc9) {
      var ret = await BleManager.requestRetry(data,
          lr: "R", timeoutMs: timeoutMs, retry: retry ?? 0);
      if (ret.isTimeout) return false;
    }
    return true;
  }

  static Future sendData(Uint8List data,
      {String? lr, Map<String, dynamic>? other, int secondDelay = 100}) async {

    var params = <String, dynamic>{
      'data': data,
    };
    if (other != null) {
      params.addAll(other);
    }
    dynamic ret;
    if (lr != null) {
      params["lr"] = lr;
      ret = await BleManager.invokeMethod(methodSend, params);
      return ret;
    } else {
      params["lr"] = "L"; // get().slave; 
      var ret = await _channel
          .invokeMethod(methodSend, params); //ret is true or false or null
      if (ret == true) {
        params["lr"] = "R"; // get().master;
        ret = await BleManager.invokeMethod(methodSend, params);
        return ret;
      }
      if (secondDelay > 0) {
        await Future.delayed(Duration(milliseconds: secondDelay));
      }
      params["lr"] = "R"; // get().master;
      ret = await BleManager.invokeMethod(methodSend, params);
      return ret;
    }
  }

  static Future<BleReceive> request(Uint8List data,
      {String? lr,
      Map<String, dynamic>? other,
      int timeoutMs = 1000, //500,
      bool useNext = false}) async {

    var lr0 = lr ?? Proto.lR();
    var completer = Completer<BleReceive>();
    String cmd = "$lr0${data[0].toRadixString(16).padLeft(2, '0')}";

    if (useNext) {
      _nextReceive = completer;
    } else {
      if (_reqListen.containsKey(cmd)) {
        var res = BleReceive();
        res.isTimeout = true;
        _reqListen[cmd]?.complete(res);
        print("already exist key: $cmd");

        _reqTimeout[cmd]?.cancel();
      }
      _reqListen[cmd] = completer;
    }
    print("request key: $cmd, ");

    if (timeoutMs > 0) {
      _reqTimeout[cmd] = Timer(Duration(milliseconds: timeoutMs), () {
        _checkTimeout(cmd, timeoutMs, data, lr0);
      });
    }

    completer.future.then((result) {
      _reqTimeout.remove(cmd)?.cancel();
    });

    await sendData(data, lr: lr, other: other).timeout(
      Duration(seconds: 2),
      onTimeout: () {
        _reqTimeout.remove(cmd)?.cancel();
        var ret = BleReceive();
        ret.isTimeout = true;
        _reqListen.remove(cmd)?.complete(ret);
      },
    );

    return completer.future;
  }

  static bool isBothConnected() {
    //return isConnectedL() && isConnectedR();

    // todo
    return true;
  }

  static Future<bool> requestList(
    List<Uint8List> sendList, {
    String? lr,
    int? timeoutMs,
  }) async {
    print("requestList---sendList---${sendList.first}----lr---$lr----timeoutMs----$timeoutMs-");

    if (lr != null) {
      return await _requestList(sendList, lr, timeoutMs: timeoutMs);
    } else {
      var rets = await Future.wait([
        _requestList(sendList, "L", keepLast: true, timeoutMs: timeoutMs),
        _requestList(sendList, "R", keepLast: true, timeoutMs: timeoutMs),
      ]);
      if (rets.length == 2 && rets[0] && rets[1]) {
        var lastPack = sendList[sendList.length - 1];
        return await sendBoth(lastPack, timeoutMs: timeoutMs ?? 250);
      } else {
        print("error request lr leg");
      }
    }
    return false;
  }

  static Future<bool> _requestList(List sendList, String lr,
      {bool keepLast = false, int? timeoutMs}) async {
    int len = sendList.length;
    if (keepLast) len = sendList.length - 1;
    for (var i = 0; i < len; i++) {
      var pack = sendList[i];
      var resp = await request(pack, lr: lr, timeoutMs: timeoutMs ?? 350);
      if (resp.isTimeout) {
        return false;
      } else if (resp.data[1].toInt() != 0xc9 && resp.data[1].toInt() != 0xcB) {
        return false;
      }
    }
    return true;
  }

}

extension Uint8ListEx on Uint8List {
  String get hexString {
    return map((e) => e.toRadixString(16).padLeft(2, '0')).join(' ');
  }
}
