import AVFoundation
import AudioToolbox
import CoreLocation
import Foundation
import UIKit

// 被控端：另一台设备通过云盘发来的一条指令 → 用本机硬件执行 → 结果（文字 + 可选文件）。
// 和安卓「小橘遥控」同一套指令协议。

struct RemoteResult {
    let text: String
    var files: [(String, Data)] = []
}

enum RemoteCommands {

    static func run(_ cmd: [String: Any]) async -> RemoteResult {
        let action = cmd["do"] as? String ?? ""
        do {
            switch action {
            case "info": return RemoteResult(text: info())
            case "torch": return try torch(on: (cmd["on"] as? Bool) ?? true)
            case "photo": return try await photo(front: (cmd["lens"] as? String) == "front")
            case "audio": return try await audio(seconds: clampInt(cmd["seconds"], 5, 1, 60))
            case "location": return try await location()
            case "vibrate": AudioServicesPlaySystemSound(kSystemSoundID_Vibrate); return RemoteResult(text: "震动了")
            case "ring": await ring(seconds: clampInt(cmd["seconds"], 5, 1, 60)); return RemoteResult(text: "响了")
            case "shell": return RemoteResult(text: "遥控里暂时没接本机命令。要跑命令，在对话框里直接说，或用安卓那台。")
            default: return RemoteResult(text: "不认识的指令：\(action)")
            }
        } catch {
            return RemoteResult(text: "执行出错：\(error.localizedDescription)")
        }
    }

    private static func clampInt(_ v: Any?, _ def: Int, _ lo: Int, _ hi: Int) -> Int {
        let n = (v as? Int) ?? (v as? NSNumber)?.intValue ?? def
        return min(max(n, lo), hi)
    }

    private static func info() -> String {
        let d = UIDevice.current
        d.isBatteryMonitoringEnabled = true
        let batt = d.batteryLevel < 0 ? "未知" : "\(Int(d.batteryLevel * 100))%"
        return "型号：\(d.model)（\(d.name)）\n系统：\(d.systemName) \(d.systemVersion)\n电量：\(batt)"
    }

    private static func torch(on: Bool) throws -> RemoteResult {
        guard let dev = AVCaptureDevice.default(for: .video), dev.hasTorch else {
            return RemoteResult(text: "这台设备没有手电筒")
        }
        try dev.lockForConfiguration()
        dev.torchMode = on ? .on : .off
        dev.unlockForConfiguration()
        return RemoteResult(text: "手电筒已\(on ? "打开" : "关闭")")
    }

    private static func photo(front: Bool) async throws -> RemoteResult {
        guard await ensureAuth(.video) else { return RemoteResult(text: "没有相机权限，去系统设置里给小橘推送开相机") }
        let data = try await RemotePhotoCapturer().capture(front: front)
        return RemoteResult(text: "拍了一张（\(front ? "前" : "后")摄，\(data.count / 1024) KB）", files: [("photo.jpg", data)])
    }

    private static func audio(seconds: Int) async throws -> RemoteResult {
        guard await ensureRecordPermission() else { return RemoteResult(text: "没有麦克风权限") }
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.record)
        try s.setActive(true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        let rec = try AVAudioRecorder(url: url, settings: settings)
        guard rec.record() else { return RemoteResult(text: "录音没启动") }
        try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
        rec.stop()
        try? s.setActive(false)
        let data = (try? Data(contentsOf: url)) ?? Data()
        try? FileManager.default.removeItem(at: url)
        return RemoteResult(text: "录了 \(seconds) 秒（\(data.count / 1024) KB）", files: [("audio.m4a", data)])
    }

    private static func location() async throws -> RemoteResult {
        guard let l = await RemoteOneShotLocation().get() else {
            return RemoteResult(text: "暂时拿不到定位（权限没给，或信号差）")
        }
        return RemoteResult(text: "纬度 \(l.coordinate.latitude)，经度 \(l.coordinate.longitude)，精度 \(Int(l.horizontalAccuracy)) 米\n地图：https://maps.apple.com/?ll=\(l.coordinate.latitude),\(l.coordinate.longitude)")
    }

    private static func ring(seconds: Int) async {
        let end = Date().addingTimeInterval(TimeInterval(seconds))
        while Date() < end {
            AudioServicesPlaySystemSound(1005)
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            try? await Task.sleep(nanoseconds: 1_300_000_000)
        }
    }

    private static func ensureAuth(_ type: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: type)
        default: return false
        }
    }

    private static func ensureRecordPermission() async -> Bool {
        await withCheckedContinuation { c in
            AVAudioApplication.requestRecordPermission { ok in c.resume(returning: ok) }
        }
    }
}

final class RemotePhotoCapturer: NSObject, AVCapturePhotoCaptureDelegate {
    private let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private var cont: CheckedContinuation<Data, Error>?

    func capture(front: Bool) async throws -> Data {
        try await withCheckedThrowingContinuation { c in
            self.cont = c
            do {
                session.beginConfiguration()
                session.sessionPreset = .photo
                let pos: AVCaptureDevice.Position = front ? .front : .back
                let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: pos)
                    ?? AVCaptureDevice.default(for: .video)
                guard let device = dev,
                      let input = try? AVCaptureDeviceInput(device: device),
                      session.canAddInput(input) else { throw PushError("打不开摄像头") }
                session.addInput(input)
                guard session.canAddOutput(output) else { throw PushError("相机输出失败") }
                session.addOutput(output)
                session.commitConfiguration()
                session.startRunning()
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.7) { [weak self] in
                    guard let self else { return }
                    let settings: AVCapturePhotoSettings = self.output.availablePhotoCodecTypes.contains(.jpeg)
                        ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                        : AVCapturePhotoSettings()
                    self.output.capturePhoto(with: settings, delegate: self)
                }
            } catch { finish(.failure(error)) }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        session.stopRunning()
        if let error { finish(.failure(error)); return }
        guard let data = photo.fileDataRepresentation() else { finish(.failure(PushError("拿不到照片数据"))); return }
        finish(.success(data))
    }

    private func finish(_ r: Result<Data, Error>) {
        guard let c = cont else { return }
        cont = nil
        switch r {
        case .success(let d): c.resume(returning: d)
        case .failure(let e): c.resume(throwing: e)
        }
    }
}

final class RemoteOneShotLocation: NSObject, CLLocationManagerDelegate {
    private let mgr = CLLocationManager()
    private var cont: CheckedContinuation<CLLocation?, Never>?

    func get() async -> CLLocation? {
        await withCheckedContinuation { c in
            self.cont = c
            mgr.delegate = self
            mgr.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            mgr.requestWhenInUseAuthorization()
            mgr.requestLocation()
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                self?.finish(self?.mgr.location)
            }
        }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) { finish(locs.last) }
    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) { finish(nil) }

    private func finish(_ l: CLLocation?) {
        guard let c = cont else { return }
        cont = nil
        c.resume(returning: l)
    }
}
