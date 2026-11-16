import AppKit
import CoreGraphics
import Foundation

/// ディスプレイの明るさ。**private framework（DisplayServices）を使う、条件つきの例外**（条件は AGENTS.md）。
/// - 実行時に `dlopen` で読み、無ければ「使えない」にする（落ちない）。読み書きするのは明るさだけ。通信・ファイル書き込みはしない。
/// - 対象の選び方は音量・マイクと同じ（`AudioDevices` を使い回す）。ディスプレイの UID は、抜き差しや再起動をまたいで同じ
///   `CGDisplayCreateUUIDFromDisplayID` の UUID。固定したディスプレイが消えても、指す先は変えず「使えない」表示になるだけ。
enum DisplayHardware {
    private typealias GetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (UInt32, Float) -> Int32
    private typealias CanFn = @convention(c) (UInt32) -> Bool

    private static let handle = dlopen(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let getFn: GetFn? = handle.flatMap { dlsym($0, "DisplayServicesGetBrightness") }
        .map { unsafeBitCast($0, to: GetFn.self) }
    private static let setFn: SetFn? = handle.flatMap { dlsym($0, "DisplayServicesSetBrightness") }
        .map { unsafeBitCast($0, to: SetFn.self) }
    private static let canFn: CanFn? = handle.flatMap { dlsym($0, "DisplayServicesCanChangeBrightness") }
        .map { unsafeBitCast($0, to: CanFn.self) }

    /// この OS で明るさを扱えるか（読み込めないときは false。ウィジェットは「使えない」表示にする）。
    static var isAvailable: Bool { getFn != nil && setFn != nil }

    /// 今つながっているディスプレイ。`hasVolume` は「明るさを変えられるか」の意味で使う（音量と同じ型を使い回すため）。
    static func displays() -> [AudioDeviceInfo] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        guard count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let names = screenNames()
        return ids.prefix(Int(count)).compactMap { id in
            guard let uid = uuidString(id) else { return nil }
            return AudioDeviceInfo(id: id, uid: uid, name: names[id] ?? "ディスプレイ \(id)", hasVolume: canChange(id))
        }
    }

    /// 既定の対象＝メインのディスプレイの UID。
    static func mainUID() -> String? { uuidString(CGMainDisplayID()) }

    /// 明るさ（0〜100）。読めないときは nil。
    static func brightness(_ id: UInt32) -> Int? {
        guard let getFn else { return nil }
        var value: Float = 0
        guard getFn(id, &value) == 0, value.isFinite else { return nil }
        return Int((min(1, max(0, value)) * 100).rounded())
    }

    @discardableResult
    static func setBrightness(_ percent: Int, _ id: UInt32) -> Bool {
        guard let setFn else { return false }
        return setFn(id, Float(min(100, max(0, percent))) / 100) == 0
    }

    private static func canChange(_ id: UInt32) -> Bool { canFn?(id) ?? false }

    private static func uuidString(_ id: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
              let text = CFUUIDCreateString(nil, uuid) else { return nil }
        return text as String
    }

    /// 表示名（NSScreen は画面のスレッドで読む）。
    private static func screenNames() -> [CGDirectDisplayID: String] {
        let read: () -> [CGDirectDisplayID: String] = {
            var result: [CGDirectDisplayID: String] = [:]
            for screen in NSScreen.screens {
                if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                    result[number.uint32Value] = screen.localizedName
                }
            }
            return result
        }
        return Thread.isMainThread ? read() : DispatchQueue.main.sync(execute: read)
    }
}

/// 輝度ウィジェットの対象と表示（純粋関数）。
enum DisplayChoice {
    /// 切り替え先を選んだときの結果。ディスプレイにはシステムの既定を切り替える手段が無いので、選んだら必ずそのディスプレイに固定する。
    /// 使えない項目は選べない（nil）。
    static func select(uid: String, name: String, available: Bool) -> AudioTarget? {
        available ? .pinned(uid: uid, name: name) : nil
    }

    /// 画面に出す文字と割合。明るさを変えられないディスプレイ・読めないときは「—」。
    static func reading(resolution: AudioResolution, brightness: Int?, isAvailable: Bool = true) -> AudioDisplay.Reading {
        let label = AudioDevices.label(for: resolution)
        guard isAvailable else { return .init(big: "—", detail: "この macOS では明るさを扱えません", fraction: nil) }
        switch resolution {
        case .noDevice: return .init(big: "—", detail: "ディスプレイがありません", fraction: nil)
        case .unavailable: return .init(big: "—", detail: label, fraction: nil)
        case .device:
            guard let brightness else { return .init(big: "—", detail: "\(label)：明るさを変えられないディスプレイです", fraction: nil) }
            return .init(big: "\(brightness)%", detail: "\(label)：明るさ \(brightness)%", fraction: Double(brightness) / 100)
        }
    }
}

/// 輝度ウィジェットが、対象のディスプレイの値を読む。短い間（1.5 秒）だけキャッシュし、呼び出しは裏のスレッドから行う。
enum DisplayReader {
    private static let lock = NSLock()
    private static var cache: [String: (reading: AudioDisplay.Reading, at: Date)] = [:]
    private static let ttl: TimeInterval = 1.5

    struct Snapshot: Equatable {
        var displays: [AudioDeviceInfo]
        var resolution: AudioResolution
        var brightness: Int?
    }

    static func snapshot(for widget: Widget) -> Snapshot {
        let displays = DisplayHardware.displays()
        let resolution = AudioDevices.resolve(widget.audioTarget, devices: displays, defaultUID: DisplayHardware.mainUID())
        var brightness: Int?
        if case .device(let display) = resolution, display.hasVolume { brightness = DisplayHardware.brightness(display.id) }
        return Snapshot(displays: displays, resolution: resolution, brightness: brightness)
    }

    static func reading(for widget: Widget) -> AudioDisplay.Reading {
        let key = widget.pinnedDeviceUID ?? ""
        lock.lock()
        if let hit = cache[key], Date().timeIntervalSince(hit.at) < ttl { lock.unlock(); return hit.reading }
        lock.unlock()
        let shot = snapshot(for: widget)
        let reading = DisplayChoice.reading(resolution: shot.resolution, brightness: shot.brightness,
                                            isAvailable: DisplayHardware.isAvailable)
        lock.lock()
        cache[key] = (reading, Date())
        lock.unlock()
        return reading
    }

    static func invalidate() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    @discardableResult
    static func setBrightness(_ percent: Int, for widget: Widget) -> Bool {
        defer { invalidate() }
        guard case .device(let display) = snapshot(for: widget).resolution, display.hasVolume else { return false }
        return DisplayHardware.setBrightness(percent, display.id)
    }
}
