import AppKit
import SwiftUI

/// 音量・マイクのポップアップ：デバイスの切り替え、固定、音量、ミュート。
/// 固定したデバイスが消えても、指す先（UID）は変えない。使えない表示になるだけで、別のデバイスを代わりにしない。
/// 読み書きは裏のスレッドで行い、描画を止めない。
struct AudioWidgetControls: View {
    @Binding var widget: Widget

    @State private var snapshot: AudioReader.Snapshot?
    @State private var volume: Double = 0
    @State private var editing = false

    private var direction: AudioDirection { widget.audioDirection }
    private var target: AudioTarget { widget.audioTarget }
    private var pinned: Bool { if case .pinned = target { return true } else { return false } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            deviceRow
            if let snapshot {
                switch snapshot.resolution {
                case .device(let device):
                    if device.hasVolume { volumeRow(snapshot) } else {
                        Text("このデバイスは音量を変えられません").font(.caption).foregroundStyle(.secondary)
                    }
                case .unavailable(_, let name):
                    Text(PopupLayout.unavailableNote(name: name))
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                case .noDevice:
                    Text("使えるデバイスがありません").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(PopupLayout.pinnedNote(pinned: pinned, subject: "デバイス"))
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: PopupLayout.width)
        .onAppear { reload() }
        // ポップアップを開いている間は、デバイスの抜き差しと音量を 2 秒ごとに読み直す（閉じれば止まる）。
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in if !editing { reload() } }
    }

    // MARK: - デバイス

    private var deviceRow: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(choices, id: \.uid) { choice in
                    Button {
                        select(choice)
                    } label: {
                        Text(choice.available ? choice.name : "\(choice.name)（接続されていません）")
                    }
                }
                if BluetoothPaired.canAsk {
                    Divider()
                    Button("ペアリング済みの機器も候補に出す…") {
                        BluetoothPaired.requestAccess()
                    }
                }
            } label: {
                Text(currentLabel).lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer(minLength: 4)
            Button { togglePin() } label: {
                Image(systemName: pinned ? "pin.fill" : "pin")
                    .foregroundStyle(pinned ? Color.accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            .disabled(!pinned && !canPin)
            .help(pinned ? "固定を外す（既定のデバイスに従う）" : "いまのデバイスに固定する")
        }
    }

    private var choices: [(uid: String, name: String, available: Bool)] {
        AudioDevices.choices(devices: snapshot?.devices ?? [], target: target, extra: snapshot?.extra ?? [])
    }

    private var currentLabel: String {
        guard let snapshot else { return "読み込み中…" }
        return AudioDevices.label(for: snapshot.resolution)
    }

    private var canPin: Bool {
        guard let snapshot, case .device = snapshot.resolution else { return false }
        return true
    }

    /// 項目を選んだとき。つないでいる機器は切り替える。つないでいない候補（覚えた機器・ペアリング済み）は、指す先だけ固定する
    /// （つないだら、固定先へ既定が戻る。`AudioPinEnforcer`）。
    private func select(_ choice: (uid: String, name: String, available: Bool)) {
        guard choice.available else {
            widget.setAudioTarget(AudioDevices.pinCandidate(uid: choice.uid, name: choice.name))
            AudioReader.invalidate()
            reload()
            return
        }
        guard let result = AudioDevices.select(uid: choice.uid, name: choice.name, available: choice.available, target: target)
        else { return }
        widget.setAudioTarget(result.target)
        guard let uid = result.setDefaultUID else { reload(); return }
        let current = widget          // メインのうちに値を取る（裏のスレッドから Binding を読まない）
        DispatchQueue.global(qos: .userInitiated).async {
            AudioReader.setDefault(uid: uid, for: current)
            reloadAfterChange(current)
        }
    }

    private func togglePin() {
        guard let snapshot else { return }
        widget.setAudioTarget(AudioDevices.togglingPin(resolution: snapshot.resolution, target: target))
        AudioReader.invalidate()
        reload()
    }

    // MARK: - 音量

    private func volumeRow(_ snapshot: AudioReader.Snapshot) -> some View {
        HStack(spacing: 8) {
            Button {
                let next = !(snapshot.muted ?? false)
                let current = widget
                DispatchQueue.global(qos: .userInitiated).async {
                    AudioReader.setMuted(next, for: current)
                    reloadAfterChange(current)
                }
            } label: {
                Image(systemName: icon(muted: snapshot.muted ?? false)).frame(width: 18)
            }
            .buttonStyle(.plain)
            .disabled(snapshot.muted == nil)
            .help((snapshot.muted ?? false) ? "ミュートを解除" : "ミュート")
            Slider(value: $volume, in: 0...100, step: 1) { isEditing in
                editing = isEditing
                // つまみを離したときに確定する（動かしている間は書き込みを連発しない）。
                if !isEditing {
                    let value = Int(volume)
                    let current = widget
                    DispatchQueue.global(qos: .userInitiated).async {
                        AudioReader.setVolume(value, for: current)
                        reloadAfterChange(current)
                    }
                }
            }
            Text("\(Int(volume))%").monospacedDigit().frame(width: 40, alignment: .trailing)
        }
    }

    private func icon(muted: Bool) -> String {
        switch (direction, muted) {
        case (.output, true): return "speaker.slash.fill"
        case (.output, false): return "speaker.wave.2.fill"
        case (.input, true): return "mic.slash.fill"
        case (.input, false): return "mic.fill"
        }
    }

    // MARK: - 読み直し

    private func reload() {
        let current = widget
        DispatchQueue.global(qos: .userInitiated).async {
            let next = AudioReader.snapshot(for: current)
            DispatchQueue.main.async { apply(next) }
        }
    }

    /// 裏のスレッドから呼ぶ。`current` は、メインのうちに取った値（Binding は裏のスレッドから読まない）。
    private func reloadAfterChange(_ current: Widget) {
        let next = AudioReader.snapshot(for: current)
        DispatchQueue.main.async { apply(next) }
    }

    private func apply(_ next: AudioReader.Snapshot) {
        if snapshot != next { snapshot = next }
        if !editing, let value = next.volume { volume = Double(value) }
        // 固定したデバイスの名前が変わっていたら、表示用の名前だけ更新する（UID は変えない）。
        if case .pinned(let uid, let name) = target, case .device(let device) = next.resolution,
           device.uid == uid, device.name != name {
            widget.setAudioTarget(.pinned(uid: uid, name: device.name))
        }
    }
}
