import Foundation

/// 音量・マイクのウィジェットが、固定したデバイスの値を読む。
/// CoreAudio の呼び出しは軽いが、デバイスが多いと数 ms かかるので、短い間（既定 1.5 秒）だけキャッシュする。
/// 呼び出しは、ウィジェットの文を作る裏のスレッドと、ポップアップを開いたときの裏のスレッドから行う。
enum AudioReader {
    private static let lock = NSLock()
    private static var cache: [String: (reading: AudioDisplay.Reading, at: Date)] = [:]
    private static let ttl: TimeInterval = 1.5

    /// 今の表示値。固定したデバイスがあればそれ、無ければシステムの既定のデバイス。
    static func reading(for widget: Widget) -> AudioDisplay.Reading {
        let direction = widget.audioDirection
        let key = "\(direction.rawValue)|\(widget.pinnedDeviceUID ?? "")"
        lock.lock()
        if let hit = cache[key], Date().timeIntervalSince(hit.at) < ttl { lock.unlock(); return hit.reading }
        lock.unlock()

        let devices = AudioHardware.devices(direction)
        let resolution = AudioDevices.resolve(widget.audioTarget, devices: devices, defaultUID: AudioHardware.defaultUID(direction))
        var volume: Int?
        var muted: Bool?
        if case .device(let device) = resolution, device.hasVolume {
            volume = AudioHardware.volume(device, direction)
            muted = AudioHardware.isMuted(device, direction)
        }
        let reading = AudioDisplay.reading(resolution: resolution, volume: volume, muted: muted, direction: direction)
        lock.lock()
        cache[key] = (reading, Date())
        lock.unlock()
        return reading
    }

    /// 操作したあとに、すぐ読み直せるよう、キャッシュを捨てる。
    static func invalidate() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    /// ポップアップに出す、いまの状態（裏のスレッドで呼ぶ）。
    struct Snapshot: Equatable {
        var devices: [AudioDeviceInfo]
        var resolution: AudioResolution
        var volume: Int?
        var muted: Bool?
        /// いまつないでいない候補（覚えた機器・ペアリング済み）。固定の候補に出す。
        var extra: [KnownAudioDevice] = []
    }

    // MARK: - 見た機器を覚える（許可は要らない。UserDefaults に JSON で保存）

    private static let knownKey = "GroupDockKnownAudioDevices"

    static func knownDevices() -> [KnownAudioDevice] {
        lock.lock(); defer { lock.unlock() }
        guard let data = UserDefaults.standard.data(forKey: knownKey),
              let list = try? JSONDecoder().decode([KnownAudioDevice].self, from: data) else { return [] }
        return list
    }

    /// いま見えている機器を覚える。変わったときだけ書く（毎回は書かない）。
    static func remember(_ devices: [AudioDeviceInfo], direction: AudioDirection) {
        let before = knownDevices()
        let after = AudioKnown.remembering(known: before, devices: devices, direction: direction)
        guard after != before, let data = try? JSONEncoder().encode(after) else { return }
        lock.lock(); defer { lock.unlock() }
        UserDefaults.standard.set(data, forKey: knownKey)
    }

    static func snapshot(for widget: Widget) -> Snapshot {
        let direction = widget.audioDirection
        let devices = AudioHardware.devices(direction)
        remember(devices, direction: direction)
        let resolution = AudioDevices.resolve(widget.audioTarget, devices: devices, defaultUID: AudioHardware.defaultUID(direction))
        var volume: Int?
        var muted: Bool?
        if case .device(let device) = resolution, device.hasVolume {
            volume = AudioHardware.volume(device, direction)
            muted = AudioHardware.isMuted(device, direction)
        }
        let extra = AudioKnown.candidates(
            known: knownDevices(), paired: BluetoothPaired.devices(), devices: devices, direction: direction)
        return Snapshot(devices: devices, resolution: resolution, volume: volume, muted: muted, extra: extra)
    }

    /// 解決したデバイスの音量を書く（使えないときは何もしない）。成功したら true。
    @discardableResult
    static func setVolume(_ percent: Int, for widget: Widget) -> Bool {
        defer { invalidate() }
        guard case .device(let device) = snapshot(for: widget).resolution else { return false }
        return AudioHardware.setVolume(percent, device, widget.audioDirection)
    }

    @discardableResult
    static func setMuted(_ muted: Bool, for widget: Widget) -> Bool {
        defer { invalidate() }
        guard case .device(let device) = snapshot(for: widget).resolution else { return false }
        return AudioHardware.setMuted(muted, device, widget.audioDirection)
    }

    /// システムの既定のデバイスを切り替える（固定していないときの切り替え）。
    @discardableResult
    static func setDefault(uid: String, for widget: Widget) -> Bool {
        defer { invalidate() }
        let direction = widget.audioDirection
        guard let device = AudioHardware.devices(direction).first(where: { AudioDevices.sameUID($0.uid, uid) }) else { return false }
        return AudioHardware.setDefault(device, direction)
    }
}
