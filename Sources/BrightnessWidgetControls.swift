import AppKit
import SwiftUI

/// 明るさのポップアップ：ディスプレイの選択（複数ディスプレイ対応）、固定、明るさ。
/// ディスプレイには「システムの既定を切り替える」手段が無いので、選んだらそのディスプレイに固定する。
/// 固定したディスプレイが消えても、指す先（UID）は変えない。使えない表示になるだけで、別のディスプレイを代わりにしない。
struct BrightnessWidgetControls: View {
    @Binding var widget: Widget

    @State private var snapshot: DisplayReader.Snapshot?
    @State private var level: Double = 0
    @State private var editing = false

    private var target: AudioTarget { widget.audioTarget }
    private var pinned: Bool { if case .pinned = target { return true } else { return false } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            deviceRow
            if let snapshot {
                switch snapshot.resolution {
                case .device(let display):
                    if display.hasVolume { brightnessRow } else {
                        Text("このディスプレイは明るさを変えられません").font(.caption).foregroundStyle(.secondary)
                    }
                case .unavailable(_, let name):
                    Text(PopupLayout.unavailableNote(name: name))
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                case .noDevice:
                    Text("ディスプレイがありません").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !DisplayHardware.isAvailable {
                Text("この macOS では明るさを\n扱えません。").font(.caption).foregroundStyle(.orange)
            }
            Text(PopupLayout.pinnedNote(pinned: pinned, subject: "ディスプレイ"))
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: PopupLayout.width)
        .onAppear { reload() }
        // ポップアップを開いている間は、ディスプレイの抜き差しと明るさを 2 秒ごとに読み直す（閉じれば止まる）。
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in if !editing { reload() } }
    }

    private var deviceRow: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(choices, id: \.uid) { choice in
                    Button {
                        if let next = DisplayChoice.select(uid: choice.uid, name: choice.name, available: choice.available) {
                            widget.setAudioTarget(next)
                            DisplayReader.invalidate()
                            reload()
                        }
                    } label: {
                        Text(choice.available ? choice.name : "\(choice.name)（接続されていません）")
                    }
                    .disabled(!choice.available)
                }
            } label: {
                Text(currentLabel).lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer(minLength: 4)
            Button {
                guard let snapshot else { return }
                widget.setAudioTarget(AudioDevices.togglingPin(resolution: snapshot.resolution, target: target))
                DisplayReader.invalidate()
                reload()
            } label: {
                Image(systemName: pinned ? "pin.fill" : "pin")
                    .foregroundStyle(pinned ? Color.accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            .disabled(!pinned && !canPin)
            .help(pinned ? "固定を外す（メインのディスプレイに従う）" : "いまのディスプレイに固定する")
        }
    }

    private var choices: [(uid: String, name: String, available: Bool)] {
        AudioDevices.choices(devices: snapshot?.displays ?? [], target: target)
    }

    private var currentLabel: String {
        guard let snapshot else { return "読み込み中…" }
        return AudioDevices.label(for: snapshot.resolution)
    }

    private var canPin: Bool {
        guard let snapshot, case .device = snapshot.resolution else { return false }
        return true
    }

    private var brightnessRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "sun.min.fill").font(.caption)
            Slider(value: $level, in: 0...100, step: 1) { isEditing in
                editing = isEditing
                // つまみを離したときに確定する（動かしている間は書き込みを連発しない）。
                if !isEditing {
                    let value = Int(level)
                    let current = widget
                    DispatchQueue.global(qos: .userInitiated).async {
                        DisplayReader.setBrightness(value, for: current)
                        let next = DisplayReader.snapshot(for: current)
                        DispatchQueue.main.async { apply(next) }
                    }
                }
            }
            Image(systemName: "sun.max.fill").font(.caption)
            Text("\(Int(level))%").monospacedDigit().frame(width: 40, alignment: .trailing)
        }
    }

    private func reload() {
        let current = widget
        DispatchQueue.global(qos: .userInitiated).async {
            let next = DisplayReader.snapshot(for: current)
            DispatchQueue.main.async { apply(next) }
        }
    }

    private func apply(_ next: DisplayReader.Snapshot) {
        if snapshot != next { snapshot = next }
        if !editing, let value = next.brightness { level = Double(value) }
        // 固定したディスプレイの名前が変わっていたら、表示用の名前だけ更新する（UID は変えない）。
        if case .pinned(let uid, let name) = target, case .device(let display) = next.resolution,
           display.uid == uid, display.name != name {
            widget.setAudioTarget(.pinned(uid: uid, name: display.name))
        }
    }
}
