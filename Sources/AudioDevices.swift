import Foundation

/// 音声デバイスの向き。出力（スピーカー・ヘッドホン）か入力（マイク）。
enum AudioDirection: String, Codable {
    case output, input
}

/// 音声デバイス 1 つ。`uid` は抜き差しや再起動をまたいで同じ（固定に使う）。`id` は今の接続だけの番号。
struct AudioDeviceInfo: Equatable, Identifiable {
    var id: UInt32
    var uid: String
    var name: String
    /// 音量を持つか（持たないデバイスは、音量を灰色にする）。
    var hasVolume: Bool = true
}

/// ウィジェットが指すデバイス。固定したら UID を覚える。
/// 固定したデバイスが無くなっても、指す先（UID）は変えない。使えない状態になるだけ（別のデバイスに付け替えない）。
enum AudioTarget: Equatable {
    /// システムの既定に従う（固定していない）。
    case followDefault
    /// 固定したデバイスを指す。UID と、最後に見えたときの名前（消えていても表示に使う）。
    case pinned(uid: String, name: String)
}

/// 解決の結果。
enum AudioResolution: Equatable {
    /// 使えるデバイス。
    case device(AudioDeviceInfo)
    /// 固定したデバイスが今は無い（指す先は変わらない）。名前は最後に見えたときのもの。
    case unavailable(uid: String, name: String)
    /// 既定のデバイスが無い（デバイスが 1 つも無い、など）。
    case noDevice
}

enum AudioDevices {
    /// UID の比較（CoreAudio の UID は、Bluetooth 機器のアドレスの大文字小文字が揺れることがあるので、区別しない）。
    static func sameUID(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) == .orderedSame }

    /// 指す先を解決する（純粋関数）。
    /// - 固定していなければ、システムの既定のデバイス。
    /// - 固定していれば、その UID のデバイス。見つからなければ「使えない」（別のデバイスを代わりにしない）。
    static func resolve(_ target: AudioTarget, devices: [AudioDeviceInfo], defaultUID: String?) -> AudioResolution {
        switch target {
        case .followDefault:
            guard let defaultUID, let device = devices.first(where: { sameUID($0.uid, defaultUID) }) else { return .noDevice }
            return .device(device)
        case .pinned(let uid, let name):
            if let device = devices.first(where: { sameUID($0.uid, uid) }) { return .device(device) }
            return .unavailable(uid: uid, name: name)
        }
    }

    /// 候補（いま接続されていない機器）を指して固定する。つないでいなくても、指す先（UID）を決める。
    /// つないだら、`AudioPinning` が固定先を既定へ戻す。
    static func pinCandidate(uid: String, name: String) -> AudioTarget { .pinned(uid: uid, name: name) }

    /// 固定する。いま解決できているデバイスの UID と名前を覚える。使えない・無いときは固定しない（nil）。
    static func pin(_ resolution: AudioResolution) -> AudioTarget? {
        guard case .device(let device) = resolution else { return nil }
        return .pinned(uid: device.uid, name: device.name)
    }

    /// 固定を使う側の保存形式（`Widget` に持たせる）。UID が空なら固定なし。
    static func target(pinnedUID: String?, pinnedName: String?) -> AudioTarget {
        guard let uid = pinnedUID, !uid.isEmpty else { return .followDefault }
        return .pinned(uid: uid, name: pinnedName ?? uid)
    }

    /// 画面に出す名前。使えないときは、その旨を足す（名前は変えない）。
    static func label(for resolution: AudioResolution) -> String {
        switch resolution {
        case .device(let device): return device.name
        case .unavailable(_, let name): return "\(name)（接続されていません）"
        case .noDevice: return "デバイスがありません"
        }
    }

    /// 切り替え先を選んだときの結果（純粋関数）。使えない項目は選べない（nil）。
    /// - 固定していなければ、システムの既定を切り替える（固定はしない）。
    /// - 固定していれば、固定先をそのデバイスに付け替え、システムの既定もそのデバイスへ切り替える。
    static func select(uid: String, name: String, available: Bool, target: AudioTarget)
        -> (target: AudioTarget, setDefaultUID: String?)? {
        guard available else { return nil }
        switch target {
        case .followDefault: return (.followDefault, uid)
        case .pinned: return (.pinned(uid: uid, name: name), uid)
        }
    }

    /// 固定の入り切り（純粋関数）。固定中なら外す。固定していなければ、いま使えるデバイスに固定する。
    /// 使えるデバイスが無ければ、固定できない（そのまま）。
    static func togglingPin(resolution: AudioResolution, target: AudioTarget) -> AudioTarget {
        if case .pinned = target { return .followDefault }
        return pin(resolution) ?? .followDefault
    }

    /// 切り替え先に出す並び。名前順。いまつないでいない候補（覚えた機器・ペアリング済み）と、固定していて今は無いデバイスも、
    /// 末尾に「使えない」として残す（指す先が見える）。同じ機器は 1 つだけ。
    static func choices(
        devices: [AudioDeviceInfo], target: AudioTarget, extra: [KnownAudioDevice] = []
    ) -> [(uid: String, name: String, available: Bool)] {
        var list = devices.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { (uid: $0.uid, name: $0.name, available: true) }
        func listed(_ uid: String) -> Bool { list.contains { sameUID($0.uid, uid) } }
        for candidate in extra where !listed(candidate.uid) {
            list.append((uid: candidate.uid, name: candidate.name, available: false))
        }
        if case .pinned(let uid, let name) = target, !listed(uid) {
            list.append((uid: uid, name: name, available: false))
        }
        return list
    }
}

/// 見たことのある機器（いまはつないでいなくても、固定の候補に出す）。
struct KnownAudioDevice: Equatable, Codable {
    var uid: String
    var name: String
    var direction: AudioDirection
}

/// つないでいない機器（AirPods など）を、固定の候補に出す（純粋関数）。
/// 候補は 2 つ：GroupDock が見たことのある機器（許可は要らない）と、Bluetooth のペアリング済みの機器（許可があれば）。
enum AudioKnown {
    /// 見た機器を覚える。足す・名前を更新するだけで、いま無い機器は消さない（つなぎ直したときに、同じ機器だと分かる）。
    static func remembering(known: [KnownAudioDevice], devices: [AudioDeviceInfo], direction: AudioDirection) -> [KnownAudioDevice] {
        var list = known
        for device in devices {
            if let index = list.firstIndex(where: { $0.direction == direction && AudioDevices.sameUID($0.uid, device.uid) }) {
                if list[index].name != device.name { list[index].name = device.name }
            } else {
                list.append(KnownAudioDevice(uid: device.uid, name: device.name, direction: direction))
            }
        }
        return list
    }

    /// Bluetooth 機器の CoreAudio の UID（「アドレス:向き」。アドレスは大文字のダッシュ区切り）。
    static func bluetoothUID(address: String, direction: AudioDirection) -> String {
        address.uppercased().replacingOccurrences(of: ":", with: "-") + ":" + direction.rawValue
    }

    /// いま接続されていない候補。覚えた機器と、ペアリング済みの機器（向きごとの UID に直す）。同じ機器は 1 つにまとめる。
    static func candidates(
        known: [KnownAudioDevice], paired: [(address: String, name: String)],
        devices: [AudioDeviceInfo], direction: AudioDirection
    ) -> [KnownAudioDevice] {
        var list: [KnownAudioDevice] = []
        func add(_ candidate: KnownAudioDevice) {
            guard !devices.contains(where: { AudioDevices.sameUID($0.uid, candidate.uid) }),
                  !list.contains(where: { AudioDevices.sameUID($0.uid, candidate.uid) }) else { return }
            list.append(candidate)
        }
        for item in known where item.direction == direction { add(item) }
        for item in paired {
            let uid = bluetoothUID(address: item.address, direction: direction)
            let name = item.name.isEmpty ? item.address.uppercased().replacingOccurrences(of: ":", with: "-") : item.name
            add(KnownAudioDevice(uid: uid, name: name, direction: direction))
        }
        return list
    }
}

/// 固定は、システムの既定まで固定する（macOS が AirPods の接続などで既定を切り替えても、固定先へ戻す）。
enum AudioPinning {
    /// 既定にすべきデバイスの UID（純粋関数）。戻す必要が無ければ nil。
    /// - 固定が複数あるときは、最初の固定に従う（異なる固定が互いに戻し合って、止まらなくなるのを防ぐ）。
    /// - 固定先が今は接続されていなければ、別のデバイスを既定にしない（使えない状態のまま。つなぎ直したら戻す）。
    /// - すでに固定先が既定なら nil（戻したあとの変化通知で、また戻す処理が走り続けない）。
    static func desiredDefault(targets: [AudioTarget], devices: [AudioDeviceInfo], defaultUID: String?) -> String? {
        for target in targets {
            guard case .pinned(let uid, _) = target else { continue }
            // 固定の UID と大文字小文字だけ違う機器も、同じ機器とみなす。返すのは、見つかった機器自身の UID。
            guard let device = devices.first(where: { AudioDevices.sameUID($0.uid, uid) }) else { return nil }
            guard let defaultUID, AudioDevices.sameUID(device.uid, defaultUID) else { return device.uid }
            return nil
        }
        return nil
    }

    /// 向きごとの判定（純粋関数）。固定は向き（出力・入力）ごとに別。`direction` の固定だけを見て、他の向きの固定に引きずられない。
    /// 例：出力はスピーカー固定、入力はマイク固定のとき、入力の判定でスピーカーの固定を先頭にして、マイクの固定を見落とさない。
    static func desiredDefault(
        pins: [(direction: AudioDirection, target: AudioTarget)], direction: AudioDirection,
        devices: [AudioDeviceInfo], defaultUID: String?
    ) -> String? {
        desiredDefault(targets: pins.filter { $0.direction == direction }.map(\.target), devices: devices, defaultUID: defaultUID)
    }
}

/// ウィジェットに出す文字・割合（純粋関数）。読み出しは裏のスレッドで行い、ここでは整形だけをする。
enum AudioDisplay {
    struct Reading: Equatable {
        var big: String
        var detail: String
        var fraction: Double?
    }

    static func reading(resolution: AudioResolution, volume: Int?, muted: Bool?, direction: AudioDirection) -> Reading {
        let word = direction == .output ? "出力音量" : "入力音量"
        let label = AudioDevices.label(for: resolution)
        guard case .device = resolution else { return Reading(big: "—", detail: label, fraction: nil) }
        guard let volume else { return Reading(big: "—", detail: "\(label)：音量を変えられないデバイスです", fraction: nil) }
        if muted == true { return Reading(big: "消音", detail: "\(label)：\(word) \(volume)%（ミュート中）", fraction: 0) }
        return Reading(big: "\(volume)%", detail: "\(label)：\(word) \(volume)%", fraction: Double(volume) / 100)
    }
}
