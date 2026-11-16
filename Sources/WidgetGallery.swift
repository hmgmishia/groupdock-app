import AppKit
import SwiftUI

/// 追加できるウィジェットの一覧。組み込み＋外部ライブラリ（JSON）の両方を出す。
struct WidgetGallery: View {
    @ObservedObject var store: Store
    var onClose: () -> Void
    @State private var broken: [String] = []

    private let columns = [GridItem(.adaptive(minimum: 132), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("ウィジェットを追加").font(.headline)
                Spacer()
                Button("閉じる") { onClose() }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("組み込み").font(.subheadline).bold()
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(WidgetKind.allCases.filter { $0 != .custom }) { kind in
                            builtinCard(kind)
                        }
                    }

                    HStack(spacing: 8) {
                        Text("ライブラリ").font(.subheadline).bold()
                        Spacer()
                        Button("フォルダを開く") {
                            NSWorkspace.shared.open(WidgetLibrary.directory)
                        }
                        Button("取り込む…") {
                            let panel = NSOpenPanel()
                            panel.allowsMultipleSelection = false
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = true
                            panel.allowedContentTypes = [.json]
                            panel.directoryURL = URL(fileURLWithPath: "/Applications")
                            panel.message = "ウィジェット（.json または .groupwidget）を取り込みます"
                            guard panel.runModal() == .OK, let url = panel.url else { return }
                            // 取り込む前に、何を実行するウィジェットかを必ず見せる
                            // （外部コマンドは自分の権限で動くため）。
                            guard confirmImport(url) else { return }
                            let error = store.importWidget(at: url)
                            DispatchQueue.main.async {
                                broken = error.map { ["取り込めませんでした: \($0)"] } ?? []
                            }
                        }
                        Button("ひな形を書き出す") {
                            _ = WidgetLibrary.writeSample()
                            let result = WidgetLibrary.reload()
                            DispatchQueue.main.async { broken = result }
                        }
                        Button("設定付きのひな形") {
                            _ = WidgetLibrary.writeTemplate()
                            let result = WidgetLibrary.reload()
                            DispatchQueue.main.async { broken = result }
                        }
                        Button("再読み込み") {
                            let result = WidgetLibrary.reload()
                            DispatchQueue.main.async { broken = result }
                        }
                    }
                    .font(.caption)

                    if !broken.isEmpty {
                        Text("読めなかったファイル: \(broken.joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    if WidgetLibrary.definitions.isEmpty {
                        Text("\(WidgetLibrary.directory.path) に .json を置くと、アプリを更新せずに足せます。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    } else {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                            ForEach(WidgetLibrary.definitions) { def in
                                libraryCard(def)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(16)
        .frame(minWidth: 460)
        .onAppear {
            // ビューの更新中に状態を書き換えない（AttributeGraph が落ちる）。
            DispatchQueue.main.async {
                broken = WidgetLibrary.reload()
            }
        }
    }

    private func builtinCard(_ kind: WidgetKind) -> some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.08))
                preview(kind)
            }
            .frame(height: 64)

            Text(kind.title).font(.caption)
            Button("追加") {
                var widget = Widget(kind: kind)
                widget.face = kind.defaultFace
                store.prefs.widgets.append(widget)
            }
            .font(.caption)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }

    private func libraryCard(_ def: WidgetDefinition) -> some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.08))
                VStack(spacing: 2) {
                    Image(systemName: def.symbol)
                    Text(def.title).font(.system(size: Typo.label))
                }
            }
            .frame(height: 64)

            Text(def.id)
                .font(.system(size: Typo.tiny))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Button("追加") {
                store.prefs.widgets.append(Widget(definition: def))
            }
            .font(.caption)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }

    /// 取り込む前に、定義の内容（実行するコマンド）を確認させる。
    private func confirmImport(_ url: URL) -> Bool {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        let manifest = isDirectory ? url.appendingPathComponent("manifest.json") : url
        guard let data = try? Data(contentsOf: manifest),
              let definition = try? JSONDecoder().decode(WidgetDefinition.self, from: data) else {
            let alert = NSAlert()
            alert.messageText = "このウィジェットは読み込めません"
            alert.informativeText = "manifest.json / JSON の形式を確認してください。"
            alert.runModal()
            return false
        }

        let alert = NSAlert()
        alert.messageText = "「\(definition.title)」を取り込みますか？"
        var lines = ["ID: \(definition.id)"]
        if let command = definition.command {
            lines.append("実行するコマンド:\n\(command)")
        } else {
            lines.append("コマンド: なし（表示のみ）")
        }
        lines.append("")
        lines.append("ウィジェットのコマンドは、このアプリと同じ権限であなたの Mac 上で実行されます。")
        lines.append("心当たりのない提供元のものは取り込まないでください。")
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "取り込む")
        alert.addButton(withTitle: "やめる")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// 見本。ここで OS に問い合わせると、レイアウト中に状態が変わって落ちるので
    /// 静的な絵だけを出す（実際の値は追加後に帯で見える）。
    @ViewBuilder
    private func preview(_ kind: WidgetKind) -> some View {
        switch kind {
        case .trend:
            HStack(spacing: 1) {
                ForEach(Array([30.0, 45, 38, 62, 55, 70, 48, 66, 52, 74].enumerated()), id: \.offset) { item in
                    Capsule()
                        .fill(Color.accentColor.opacity(0.8))
                        .frame(width: 3, height: CGFloat(item.element) * 0.5)
                }
            }
            .frame(height: 44)
        case .battery, .memory, .cpu, .disk:
            // 数値系はリングの見本。
            ZStack {
                Circle().stroke(Color.primary.opacity(0.15), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: 0.62)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: kind.symbol)
                    .font(.system(size: Typo.symbolSmall))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 44, height: 44)
        case .clock, .date:
            VStack(spacing: 2) {
                Image(systemName: kind.symbol).font(.system(size: Typo.glyph))
                Text(kind == .clock ? "12:34" : "1/1(月)")
                    .font(.system(size: Typo.label, weight: .semibold))
                    .monospacedDigit()
            }
        case .brightness:
            // 明るさの見本：太陽と、明るさを示す棒。
            VStack(spacing: 3) {
                Image(systemName: kind.symbol).font(.system(size: Typo.glyph))
                Capsule().fill(Color.yellow.opacity(0.8)).frame(width: 30, height: 4)
            }
        case .microphone:
            // マイクの見本：マイクと、入力の強さを示す棒。
            VStack(spacing: 3) {
                Image(systemName: kind.symbol).font(.system(size: Typo.glyph))
                Capsule().fill(Color.accentColor.opacity(0.7)).frame(width: 30, height: 4)
            }
        case .clipboard:
            // 履歴の見本：クリップボードと、積み重なった行。
            VStack(spacing: 3) {
                Image(systemName: kind.symbol).font(.system(size: Typo.glyph))
                VStack(spacing: 2) {
                    ForEach([30.0, 22, 26], id: \.self) { width in
                        Capsule().fill(Color.primary.opacity(0.25)).frame(width: width, height: 3)
                    }
                }
            }
        case .calendar, .nowPlaying, .volume, .custom:
            VStack(spacing: 3) {
                Image(systemName: kind.symbol).font(.system(size: Typo.glyphLarge))
                Text(kind.title).font(.system(size: Typo.label))
            }
        }
    }

}

/// ギャラリーの窓（設定のシートではなく独立した窓にした）。
final class WidgetGalleryWindowController {
    private let store: Store
    private var panel: NSPanel?

    init(store: Store) {
        self.store = store
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(
            rootView: WidgetGallery(store: store, onClose: { [weak panel] in panel?.close() })
        )
        if let screen = ScreenPick.active() {
            let area = screen.visibleFrame
            let size = NSSize(width: 500, height: 480)
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
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "ウィジェットを追加"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        return panel
    }
}
