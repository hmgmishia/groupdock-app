import CoreAudio
import Foundation

/// 固定したデバイスへ、システムの既定を戻し続ける。
/// macOS は、AirPods などをつなぐと既定の入力・出力を勝手に切り替える。固定は「ウィジェットが見る先」だけでなく、
/// システムの既定そのものを固定先に保つ（利用者の指摘：特にマイクが変わってしまう）。
/// - 固定が 1 つも無い間は何も見ない（リスナーを張らない）。
/// - 見るのは CoreAudio の公開 API の変更通知だけ（既定の出力・入力、デバイスの増減）。通信しない。
/// - 戻す判定は純粋関数 `AudioPinning.desiredDefault`（テストあり）。固定先が既定なら何もしないので、戻した変化で繰り返さない。
final class AudioPinEnforcer {
    private let queue = DispatchQueue(label: "GroupDock.audiopin", qos: .utility)
    private var pins: [(direction: AudioDirection, target: AudioTarget)] = []
    private var listeners: [(address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []

    /// ウィジェットの固定が変わったときに呼ぶ。音量・マイクの固定だけを見る。
    func update(widgets: [Widget]) {
        let next = widgets
            .filter { $0.kind == .volume || $0.kind == .microphone }
            .map { (direction: $0.audioDirection, target: $0.audioTarget) }
        queue.async { [self] in
            pins = next
            let anyPinned = next.contains { if case .pinned = $0.target { return true } else { return false } }
            if anyPinned { startListening() } else { stopListening() }
            enforce()
        }
    }

    /// 今の既定が固定先とずれていたら、固定先へ戻す。向き（出力・入力）ごとに、その向きの固定だけで判定する。
    private func enforce() {
        for direction in [AudioDirection.output, .input] {
            let devices = AudioHardware.devices(direction)
            guard let uid = AudioPinning.desiredDefault(
                pins: pins, direction: direction, devices: devices, defaultUID: AudioHardware.defaultUID(direction)),
                  let device = devices.first(where: { AudioDevices.sameUID($0.uid, uid) }) else { continue }
            AudioHardware.setDefault(device, direction)
            AudioReader.invalidate()
        }
    }

    private func startListening() {
        guard listeners.isEmpty else { return }
        for selector in [kAudioHardwarePropertyDefaultOutputDevice,
                         kAudioHardwarePropertyDefaultInputDevice,
                         kAudioHardwarePropertyDevices] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.enforce() }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block) == noErr {
                listeners.append((address, block))
            }
        }
    }

    private func stopListening() {
        for var item in listeners {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &item.address, queue, item.block)
        }
        listeners.removeAll()
    }
}
