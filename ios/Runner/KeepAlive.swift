//
//  KeepAlive.swift
//  Runner
//
//  Silent-audio background keep-alive for the Even Faces loop.
//
//  While a Face is active the app must stay alive in the background to keep
//  pushing frames to the glasses. iOS provides two background modes for that
//  (both declared in Info.plist):
//
//    1. bluetooth-central - keeps the process alive while an active BLE
//       connection with data exchange exists (the designed mechanism for
//       BLE companion apps).
//
//    2. audio (this class) - the most reliable keep-alive: an AVAudioSession
//       with category .playback that loops a *mathematically silent* buffer
//       keeps the process alive indefinitely, unaffected by the silent
//       switch. .mixWithOthers avoids ducking other audio. The buffer is all
//       zero samples, so nothing is audible even at full player volume.
//
//  Channel: "method.keepalive"  ->  start / stop / isRunning
//

import Foundation
import AVFoundation
import Flutter

final class KeepAlive {

    private var player: AVAudioPlayer?
    private(set) var isRunning = false
    private var sessionActive = false

    static func install(messenger: FlutterBinaryMessenger) {
        let instance = KeepAlive()
        let channel = FlutterMethodChannel(name: "method.keepalive", binaryMessenger: messenger)
        channel.setMethodCallHandler { call, result in
            switch call.method {
            case "start":
                instance.start()
                result(instance.isRunning)
            case "stop":
                instance.stop()
                result(!instance.isRunning)
            case "isRunning":
                result(instance.isRunning)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    func start() {
        guard player == nil else { return }

        if !sessionActive {
            let session = AVAudioSession.sharedInstance()
            do {
                // .playback is NOT stopped by the hardware silent switch,
                // .mixWithOthers keeps music/podcasts playing alongside.
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
                try session.setActive(true)
                sessionActive = true
            } catch {
                print("KeepAlive: failed to activate audio session: \(error)")
                return
            }
        }

        guard let url = KeepAlive.silentAudioUrl() else { return }
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.numberOfLoops = -1 // loop forever
            p.volume = 1.0        // buffer is all-zero samples: inaudible by definition
            p.prepareToPlay()
            p.play()
            player = p
            isRunning = true
            print("KeepAlive: silent tone started")
        } catch {
            print("KeepAlive: failed to start player: \(error)")
        }
    }

    func stop() {
        player?.stop()
        player = nil
        isRunning = false
        if sessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            sessionActive = false
        }
        print("KeepAlive: stopped")
    }

    /// Builds a 100 ms, 44.1 kHz mono 16-bit **all-zero** WAV file in the
    /// temporary directory and returns its URL (idempotent).
    static func silentAudioUrl() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("even_faces_silent.wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }

        let sampleRate = 44_100
        let sampleCount = sampleRate / 10            // 100 ms
        let byteRate = sampleRate * 2                // mono, 16 bit
        let dataSize = sampleCount * 2

        var header = Data()
        func append(_ s: String) { s.data(using: .ascii)!.withUnsafeBytes { header.append(contentsOf: $0) } }
        func appendU16(_ v: Int) { var le = UInt16(v).littleEndian; withUnsafeBytes(of: &le) { header.append(contentsOf: $0) } }
        func appendU32(_ v: Int) { var le = UInt32(v).littleEndian; withUnsafeBytes(of: &le) { header.append(contentsOf: $0) } }

        append("RIFF"); appendU32(36 + dataSize)
        append("WAVE")
        append("fmt "); appendU32(16); appendU16(1); appendU16(1)
        appendU32(sampleRate); appendU32(byteRate); appendU16(2); appendU16(16)
        append("data"); appendU32(dataSize)

        let pcm = Data(count: dataSize) // all zeros = digital silence
        do {
            try header + pcm.write(to: url)
            return url
        } catch {
            print("KeepAlive: failed to write silent wav: \(error)")
            return nil
        }
    }
}
