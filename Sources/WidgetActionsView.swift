import AppKit
import SwiftUI

/// ウィジェットのポップアップに出す、その場で変えられる操作。種類ごとに出し分ける。
/// 読み込み（`ps`・osascript）は裏のスレッドで行い、描画を止めない。
struct WidgetActionsView: View {
    let kind: WidgetKind

    @State private var volume: Double = 0
    @State private var muted = false
    @State private var volumeLoaded = false
    @State private var lowPower = false
    @State private var processes: [TopProcess] = []
    @State private var processesLoaded = false

    var body: some View {
        switch kind {
        case .volume: volumeControls
        case .battery: batteryControls
        case .cpu, .trend: processControls(by: .cpu)
        case .memory: processControls(by: .memory)
        default: EmptyView()
        }
    }

    // MARK: - 音量

    private var volumeControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    muted.toggle()
                    SystemControls.setMuted(muted)
                } label: {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 18)
                }
                .buttonStyle(.plain)
                .help(muted ? "ミュートを解除" : "ミュート")
                Slider(value: $volume, in: 0...100, step: 1) { editing in
                    // つまみを離したときに確定する（動かしている間は osascript を連発しない）。
                    if !editing { SystemControls.setVolume(Int(volume)) }
                }
                Text("\(Int(volume))%").monospacedDigit().frame(width: 40, alignment: .trailing)
            }
            .disabled(!volumeLoaded)
        }
        .onAppear {
            DispatchQueue.global(qos: .userInitiated).async {
                let current = SystemControls.volume()
                DispatchQueue.main.async {
                    if let current { volume = Double(current.level); muted = current.muted }
                    volumeLoaded = current != nil
                }
            }
        }
    }

    // MARK: - バッテリー

    private var batteryControls: some View {
        Toggle("低電力モード", isOn: Binding(
            get: { lowPower },
            set: { newValue in
                lowPower = newValue
                // 管理者の認証ダイアログが出る。キャンセルされたら表示を戻す。
                DispatchQueue.global(qos: .userInitiated).async {
                    let ok = SystemControls.setLowPower(newValue)
                    DispatchQueue.main.async { if !ok { lowPower = SystemControls.lowPowerEnabled() } }
                }
            }
        ))
        .toggleStyle(.switch)
        .onAppear { lowPower = SystemControls.lowPowerEnabled() }
    }

    // MARK: - 上位プロセス

    private func processControls(by metric: ProcessList.Metric) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(metric == .cpu ? "CPU を使っている上位 3 つ" : "メモリを使っている上位 3 つ")
                .fixedSize()
                .font(.caption)
                .foregroundStyle(.secondary)
            if !processesLoaded {
                Text("読み込み中…").font(.caption).foregroundStyle(.secondary)
            } else if processes.isEmpty {
                Text("対象のプロセスがありません").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(processes) { process in
                ProcessRow(
                    process: process, metric: metric,
                    onTerminate: { confirm(process, force: false, metric: metric) },
                    onForce: { confirm(process, force: true, metric: metric) })
            }
        }
        .onAppear { reload(metric) }
        // ポップアップを開いている間は、% と順位を 1 秒ごとに読み直す（閉じれば止まる）。
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in reload(metric) }
    }

    private func reload(_ metric: ProcessList.Metric) {
        DispatchQueue.global(qos: .userInitiated).async {
            let top = ProcessList.top(ProcessList.read(), by: metric)
            DispatchQueue.main.async {
                processes = top
                processesLoaded = true
            }
        }
    }

    /// 止めるのは取り返しがつかないので、必ず確認してから送る（次のループで出す）。
    private func confirm(_ process: TopProcess, force: Bool, metric: ProcessList.Metric) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "「\(process.name)」を\(force ? "強制終了" : "終了")しますか？"
            alert.informativeText = force
                ? "保存していない内容は失われます（pid \(process.pid)）。"
                : "終了を依頼します（pid \(process.pid)）。応答しないときは強制終了を使います。"
            alert.alertStyle = force ? .critical : .warning
            alert.addButton(withTitle: force ? "強制終了" : "終了")
            alert.addButton(withTitle: "キャンセル")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            ProcessList.signal(process.pid, force: force)
            // 結果を反映するため、少し待って読み直す。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { reload(metric) }
        }
    }
}

/// 上位プロセスの 1 行。名前は切らず、行の幅は内容で決まる（ポップアップが合わせて広がる）。
struct ProcessRow: View {
    let process: TopProcess
    let metric: ProcessList.Metric
    let onTerminate: () -> Void
    let onForce: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(process.name).lineLimit(1).fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 12)
            Text(metric == .cpu
                 ? String(format: "%.0f%%", process.cpu)
                 : String(format: "%.0f MB", process.memoryMB))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
            Button("終了", action: onTerminate)
            Button("強制", action: onForce)
        }
        .font(.caption)
    }
}
