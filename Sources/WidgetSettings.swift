import AppKit
import SwiftUI

/// 再生中の表示パターンの選択肢。各選択肢を、帯と同じ部品（色つき）で描いて並べる。
struct NowPlayingLayoutPicker: View {
    @ObservedObject var store: Store
    @Binding var widget: Widget
    /// 左右に置くときの表示パターンを選ぶ（下置きとは別に保存する）。
    var vertical = false

    var body: some View {
        let icon: CGFloat = 46
        let columns = vertical ? [GridItem(.adaptive(minimum: 96), spacing: 8)] : [GridItem(.flexible())]
        let cardHeight = vertical ? PlayerLayout.full.height(icon: icon) + 4 : icon + 4
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(PlayerLayout.allCases) { layout in
                let selected = widget.playerLook(vertical: vertical) == layout
                let tile = layout.size(icon: icon, vertical: vertical)
                Button {
                    if vertical { widget.sidePlayerLayout = layout } else { widget.playerLayout = layout }
                } label: {
                    VStack(spacing: 6) {
                        NowPlayingFace(
                            state: store.nowPlaying, layout: layout, size: icon, tint: widget.tintColor,
                            vertical: vertical, control: { _ in }, seek: { _ in })
                            .frame(width: tile.width, height: tile.height)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.10)))
                            .allowsHitTesting(false)
                            .frame(height: cardHeight)
                        Text(layout.title).font(.caption).multilineTextAlignment(.center)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 2 : 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// 設定の右側に常時出すプレビュー。画像ではなく、帯のタイルと同じ描画部品（`WidgetFaceView` など）で、
/// いまの設定（見え方・色・大きさ・名前・グラフの点数）からその場で作る。変更はすぐ映る。
struct WidgetLivePreview: View {
    @ObservedObject var store: Store
    let widget: Widget

    var body: some View {
        // 大きすぎると枠に入らないので、プレビューは 52pt までで描く。
        let icon = min(CGFloat(store.prefs.iconSize), 52)
        let sideNow = store.prefs.position != "bottom"
        ScrollView {
            VStack(spacing: 12) {
                Text("プレビュー").font(.subheadline).bold()
                section("下に置くとき", vertical: false, icon: icon, current: !sideNow)
                section("左右に置くとき", vertical: true, icon: icon, current: sideNow)
                Text("色・見え方を変えると、ここがすぐ変わります（アイコン \(Int(icon)) pt で表示）。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(16)
        }
    }

    private func section(_ title: String, vertical: Bool, icon: CGFloat, current: Bool) -> some View {
        let size = widget.tileSize(icon: icon, vertical: vertical)
        return VStack(spacing: 6) {
            Text(current ? "\(title)（いまの配置）" : title)
                .font(.caption)
                .foregroundStyle(current ? Color.primary : Color.secondary)
            VStack(spacing: 6) {
                tile(icon: icon, vertical: vertical, size: size)
                if widget.showLabel {
                    Text(widget.title).font(.system(size: Typo.label)).lineLimit(1)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.06)))
            Text("幅 \(Int(size.width)) × 高さ \(Int(size.height)) pt")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func tile(icon: CGFloat, vertical: Bool, size: CGSize) -> some View {
        let text = store.widgetText[widget.id]
        let history = store.widgetHistory[widget.id] ?? []
        if widget.kind == .nowPlaying {
            NowPlayingFace(
                state: store.nowPlaying, layout: widget.playerLook(vertical: vertical), size: icon,
                tint: widget.tintColor, vertical: vertical, control: { _ in }, seek: { _ in })
                .frame(width: size.width, height: size.height)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.10)))
        } else {
            WidgetFaceView(
                face: widget.look(vertical: vertical),
                // 値がまだ無いときは、文字とバーが同じ見本（62%）になるようにそろえる。
                big: text?.big ?? (widget.kind.isNumeric ? "62%" : widget.sampleText),
                fraction: text?.fraction ?? (widget.kind.isNumeric ? 0.62 : nil),
                symbol: widget.symbol, tint: widget.tintColor, size: icon,
                history: history.count > 1 ? history : WidgetFacePicker.demoHistory)
                .frame(width: size.width, height: size.height)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.10)))
        }
    }
}

/// 1 つのウィジェットの設定。帯のウィジェットを右クリック →「設定…」で開く。
struct WidgetSettingsView: View {
    @ObservedObject var store: Store
    let widgetID: UUID
    var onClose: () -> Void

    private var index: Int? {
        store.prefs.widgets.firstIndex { $0.id == widgetID }
    }

    var body: some View {
        if let index {
            content(widget: $store.prefs.widgets[index])
        } else {
            Text("このウィジェットは外されています")
                .padding(20)
                .frame(width: 380)
                .onAppear(perform: onClose)
        }
    }

    /// 左に設定、右に常時プレビュー。プレビューは帯と同じ描画部品で、いまの設定からその場で作る。
    private func content(widget: Binding<Widget>) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView { form(widget: widget).padding(16) }
                .frame(width: 470)
            Divider()
            WidgetLivePreview(store: store, widget: widget.wrappedValue)
                .frame(width: 300)
        }
        .frame(width: 771, height: 640)
    }

    func form(widget: Binding<Widget>) -> some View {
        let kind = widget.wrappedValue.kind
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: kind.symbol)
                Text("\(kind.title)の設定").font(.headline)
                Spacer()
            }

            GroupBox("見た目") {
                VStack(alignment: .leading, spacing: 8) {
                    if !widget.wrappedValue.kind.availableFaces.isEmpty {
                        Text("下に置くときの見え方").font(.subheadline)
                        facePicker(widget, vertical: false)
                        Text("左右に置くときの見え方").font(.subheadline)
                        facePicker(widget, vertical: true)
                    }
                    Picker("色", selection: widget.tint) {
                        ForEach(Widget.tints, id: \.id) { tint in
                            Text(tint.name).tag(tint.id)
                        }
                    }
                    if widget.wrappedValue.resolvedFace == .wideChart {
                        HStack {
                            Text("グラフの点数")
                            Slider(
                                value: Binding(
                                    get: { Double(widget.wrappedValue.historyLength) },
                                    set: { widget.wrappedValue.historyLength = Int($0) }
                                ),
                                in: 10...120,
                                step: 10
                            )
                            Text("\(widget.wrappedValue.historyLength)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 34, alignment: .trailing)
                        }
                    }
                    Toggle("名前を出す", isOn: widget.showLabel)
                        .toggleStyle(.checkbox)
                }
                .padding(6)
            }

            // 再生中：見た目（表示パターン）を、色つきのプレビューから選ぶ。再生中のものを自動で見る。
            if kind == .nowPlaying {
                GroupBox("再生中の見た目") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("下に置くとき").font(.subheadline)
                        NowPlayingLayoutPicker(store: store, widget: widget, vertical: false)
                        Text("左右に置くとき").font(.subheadline)
                        NowPlayingLayoutPicker(store: store, widget: widget, vertical: true)
                        Text("再生中のものを自動で表示します。ブラウザの再生（YouTube など）は、ブラウザ側で Apple Events からの JavaScript を許可すると読み書きできます。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(6)
                }
            }

            // 更新頻度は、変える意味のある種類（CPU・メモリ・推移・ライブラリ）だけに出す。
            if widget.wrappedValue.hasRefreshSetting {
                GroupBox("更新") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("更新頻度")
                            Slider(value: widget.refreshInterval, in: 0.5...60, step: 0.5)
                            Text(String(format: "%g 秒", widget.wrappedValue.effectiveInterval))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 56, alignment: .trailing)
                        }
                        if widget.wrappedValue.kind == .custom {
                            Text("ライブラリは OS への問い合わせが重いので、最低 10 秒あけます")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(6)
                }
            }

            // 種類ごとの項目（時計・日付だけが持つ）。
            if !widget.wrappedValue.settings.isEmpty {
                GroupBox("このウィジェットの項目") {
                    VStack(alignment: .leading, spacing: 8) {
                        if widget.wrappedValue.settings.contains(.seconds) {
                            Toggle("秒まで表示", isOn: widget.showSeconds)
                                .toggleStyle(.checkbox)
                        }
                        if widget.wrappedValue.settings.contains(.use24Hour) {
                            Toggle("24 時間表示", isOn: widget.use24Hour)
                                .toggleStyle(.checkbox)
                        }
                        if widget.wrappedValue.settings.contains(.showTime) {
                            Toggle("日付に時刻も表示", isOn: widget.showTime)
                                .toggleStyle(.checkbox)
                        }
                        if widget.wrappedValue.settings.contains(.dateStyle) {
                            Picker("日付の書き方", selection: widget.dateStyle) {
                                Text("M/d(曜)").tag(0)
                                Text("M月d日(曜)").tag(1)
                                Text("yyyy/M/d(曜)").tag(2)
                            }
                        }
                        if widget.wrappedValue.settings.contains(.timeZone) {
                            Picker("地域", selection: widget.timeZoneID) {
                                ForEach(Widget.timeZones, id: \.name) { zone in
                                    Text(zone.name).tag(zone.id)
                                }
                            }
                        }
                    }
                    .padding(6)
                }
            }

            // 外部ライブラリのウィジェットは、定義が持つ項目を自由に編集できる。
            if widget.wrappedValue.kind == .custom,
               let definition = WidgetLibrary.definition(id: widget.wrappedValue.libraryID) {
                GroupBox("このウィジェットの項目") {
                    VStack(alignment: .leading, spacing: 8) {
                        if definition.parameters.isEmpty {
                            Text("この定義には設定項目がありません")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(definition.parameters) { parameter in
                                parameterEditor(parameter, widget: widget)
                            }
                        }
                    }
                    .padding(6)
                }
            }

            // 外部ウィジェットは、何を実行するかを見せて、ここで許可する（ウィジェットごと）。
            if widget.wrappedValue.kind == .custom,
               let definition = WidgetLibrary.definition(id: widget.wrappedValue.libraryID) {
                permissionBox(definition)
            }

            HStack {
                Button("このウィジェットを外す", role: .destructive) {
                    store.prefs.widgets.removeAll { $0.id == widgetID }
                    onClose()
                }
                Spacer()
            }
        }
    }
}

extension WidgetSettingsView {
    /// 見え方の選択肢（向きごと）。見本の値は帯と同じものを使う。
    func facePicker(_ widget: Binding<Widget>, vertical: Bool) -> some View {
        let w = widget.wrappedValue
        return WidgetFacePicker(
            widget: widget,
            big: store.widgetText[w.id]?.big ?? (w.kind.isNumeric ? "62%" : w.sampleText),
            fraction: store.widgetText[w.id]?.fraction ?? 0.62,
            tint: w.tintColor,
            history: store.widgetHistory[w.id] ?? [],
            vertical: vertical)
    }

    /// このウィジェットがすること（実行するコマンド・通信）を一覧にして、それぞれ許可する。
    @ViewBuilder
    func permissionBox(_ definition: WidgetDefinition) -> some View {
        let runs = store.prefs.approvedWidgets.contains(definition.id)
        let network = store.prefs.networkWidgets.contains(definition.id)
        GroupBox("このウィジェットがすること") {
            VStack(alignment: .leading, spacing: 8) {
                if let command = definition.command, !command.isEmpty {
                    Toggle(isOn: Binding(
                        get: { runs },
                        set: { on in on ? store.approveWidget(id: definition.id) : store.revokeWidget(id: definition.id) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("コマンドを実行する")
                            Text(command)
                                .font(.system(size: Typo.label, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.checkbox)
                    Toggle(isOn: Binding(
                        get: { network },
                        set: { store.setWidgetNetwork(id: definition.id, allowed: $0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("通信を使う")
                            Text(runs ? "オフのときは通信と書き込みを拒否して実行します" : "先に「コマンドを実行する」を許可してください")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(!runs)
                    Text("許可しないと、このウィジェットの値は「—」になります。許可できるのは、許可リストのプログラム（\(CommandGuard.allowed.keys.sorted().joined(separator: "、"))）だけです。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("このウィジェットはコマンドを実行しません。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(6)
        }
    }

    /// 定義のパラメータを、種類に応じた入力欄で編集する。
    @ViewBuilder
    func parameterEditor(_ parameter: WidgetParameter, widget: Binding<Widget>) -> some View {
        let value = Binding<String>(
            get: { widget.wrappedValue.values[parameter.id] ?? parameter.defaultValue },
            set: { widget.wrappedValue.values[parameter.id] = $0 }
        )
        switch parameter.kind {
        case "toggle":
            Toggle(parameter.label, isOn: Binding(
                get: { value.wrappedValue == "true" },
                set: { value.wrappedValue = $0 ? "true" : "false" }
            ))
            .toggleStyle(.checkbox)
        case "choice":
            Picker(parameter.label, selection: value) {
                ForEach(parameter.choices, id: \.self) { choice in
                    Text(choice).tag(choice)
                }
            }
        default:
            HStack {
                Text(parameter.label)
                TextField(parameter.defaultValue, text: value)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }
}

/// ウィジェット設定の窓（1 つを使い回す）。
final class WidgetSettingsWindowController {
    private let store: Store
    private var panel: NSPanel?

    init(store: Store) {
        self.store = store
    }

    func show(widgetID: UUID) {
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(
            rootView: WidgetSettingsView(store: store, widgetID: widgetID, onClose: { [weak panel] in
                panel?.close()
            })
        )
        panel.title = "ウィジェットの設定"
        if let screen = ScreenPick.active() {
            let area = screen.visibleFrame
            let size = panel.frame.size
            panel.setFrame(ScreenPick.clamp(NSRect(
                x: area.midX - size.width / 2,
                y: area.midY - size.height / 2,
                width: size.width,
                height: size.height
            ), in: screen), display: false)
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 771, height: 640),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        return panel
    }
}
