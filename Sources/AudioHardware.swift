import CoreAudio
import Foundation

/// CoreAudio の公開 API だけで、音声デバイスの一覧・既定・音量・ミュートを読み書きする。
/// private framework は使わない。通信しない。呼び出しは裏のスレッドから行う。
enum AudioHardware {
    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    private static func scope(_ direction: AudioDirection) -> AudioObjectPropertyScope {
        direction == .output ? kAudioDevicePropertyScopeOutput : kAudioDevicePropertyScopeInput
    }

    // MARK: - 一覧と既定

    /// 向きに合うデバイスの一覧（その向きのチャンネルを持つものだけ）。
    static func devices(_ direction: AudioDirection) -> [AudioDeviceInfo] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.compactMap { id in
            guard channelCount(id, direction) > 0, let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) else { return nil }
            let name = stringProperty(id, kAudioObjectPropertyName) ?? uid
            return AudioDeviceInfo(id: id, uid: uid, name: name, hasVolume: hasVolume(id, direction))
        }
    }

    /// システムの既定のデバイスの UID。
    static func defaultUID(_ direction: AudioDirection) -> String? {
        var addr = address(direction == .output ? kAudioHardwarePropertyDefaultOutputDevice
                                                : kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return stringProperty(id, kAudioDevicePropertyDeviceUID)
    }

    /// 既定のデバイスを切り替える。成功したら true。
    @discardableResult
    static func setDefault(_ device: AudioDeviceInfo, _ direction: AudioDirection) -> Bool {
        var addr = address(direction == .output ? kAudioHardwarePropertyDefaultOutputDevice
                                                : kAudioHardwarePropertyDefaultInputDevice)
        var id = device.id
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                          UInt32(MemoryLayout<AudioDeviceID>.size), &id) == noErr
    }

    // MARK: - 音量とミュート

    /// 音量（0〜100）。持たない・読めないときは nil。メインの要素が無いデバイスは、左右の平均。
    static func volume(_ device: AudioDeviceInfo, _ direction: AudioDirection) -> Int? {
        let scope = scope(direction)
        if let value = float(device.id, kAudioDevicePropertyVolumeScalar, scope, kAudioObjectPropertyElementMain) {
            return Int((value * 100).rounded())
        }
        let sides = [1, 2].compactMap { float(device.id, kAudioDevicePropertyVolumeScalar, scope, AudioObjectPropertyElement($0)) }
        guard !sides.isEmpty else { return nil }
        return Int((sides.reduce(0, +) / Float32(sides.count) * 100).rounded())
    }

    @discardableResult
    static func setVolume(_ percent: Int, _ device: AudioDeviceInfo, _ direction: AudioDirection) -> Bool {
        let value = Float32(min(100, max(0, percent))) / 100
        let scope = scope(direction)
        if setFloat(device.id, kAudioDevicePropertyVolumeScalar, scope, kAudioObjectPropertyElementMain, value) { return true }
        // メインの要素が無いデバイスは、左右それぞれに書く。
        let results = [1, 2].map { setFloat(device.id, kAudioDevicePropertyVolumeScalar, scope, AudioObjectPropertyElement($0), value) }
        return results.contains(true)
    }

    static func isMuted(_ device: AudioDeviceInfo, _ direction: AudioDirection) -> Bool? {
        var addr = address(kAudioDevicePropertyMute, scope: scope(direction))
        guard AudioObjectHasProperty(device.id, &addr) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device.id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    @discardableResult
    static func setMuted(_ muted: Bool, _ device: AudioDeviceInfo, _ direction: AudioDirection) -> Bool {
        var addr = address(kAudioDevicePropertyMute, scope: scope(direction))
        guard AudioObjectHasProperty(device.id, &addr) else { return false }
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(device.id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    // MARK: - 下請け

    private static func hasVolume(_ id: AudioDeviceID, _ direction: AudioDirection) -> Bool {
        let scope = scope(direction)
        for element in [kAudioObjectPropertyElementMain, 1, 2] {
            var addr = address(kAudioDevicePropertyVolumeScalar, scope: scope, element: element)
            if AudioObjectHasProperty(id, &addr) { return true }
        }
        return false
    }

    private static func channelCount(_ id: AudioDeviceID, _ direction: AudioDirection) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: scope(direction))
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func float(
        _ id: AudioDeviceID, _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope, _ element: AudioObjectPropertyElement
    ) -> Float32? {
        var addr = address(selector, scope: scope, element: element)
        guard AudioObjectHasProperty(id, &addr) else { return nil }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func setFloat(
        _ id: AudioDeviceID, _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope, _ element: AudioObjectPropertyElement, _ value: Float32
    ) -> Bool {
        var addr = address(selector, scope: scope, element: element)
        var settable = DarwinBoolean(false)
        guard AudioObjectHasProperty(id, &addr),
              AudioObjectIsPropertySettable(id, &addr, &settable) == noErr, settable.boolValue else { return false }
        var v = value
        return AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr
    }
}
