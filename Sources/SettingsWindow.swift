import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 設定の項目（左の一覧）。
enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case appearance
    case apps
    case widgets

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "一般"
        case .appearance: return "見た目"
        case .apps: return "アプリ"
        case .widgets: return "ウィジェット"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintpalette"
        case .apps: return "square.grid.2x2"
        case .widgets: return "square.stack"
        }
    }
}

/// アプリの設定。左で項目を選び、右にその項目だけを出す。
struct SettingsView: View {
    @ObservedObject var store: Store
    let onClose: () -> Void
    let openPicker: () -> Void
    let openGallery: () -> Void
    @State private var section: SettingsSection = .general
    @State private var loginEnabled = LoginItem.isEnabled
    @State private var loginNote: String?

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: Binding(
                get: { section },
                set: { section = $0 ?? .general }
            )) { item in
                Label(item.title, systemImage: item.symbol).tag(item)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 150, ideal: 160, max: 200)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        detail
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                HStack {
                    Spacer()
                    Button("閉じる") { onClose() }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(12)
            }
        }
        .frame(minWidth: 620, minHeight: 460)
        .onAppear {
            loginEnabled = LoginItem.isEnabled
            loginNote = LoginItem.stateText
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch section {
        case .general: generalSection
        case .appearance: appearanceSection
        case .apps: appsSection
        case .widgets: widgetsSection
        }
    }

    // MARK: - 一般

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("一般").font(.headline)
            Toggle("Mac 起動時に自動で起動する", isOn: $loginEnabled)
                .onChange(of: loginEnabled) { _, wanted in
                    if let error = LoginItem.set(wanted) {
                        loginNote = "変更できませんでした: \(error)"
                        loginEnabled = LoginItem.isEnabled
                    } else {
                        loginNote = LoginItem.stateText
                    }
                }
            if let loginNote {
                Text(loginNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("二重起動はしません（すでに動いているときは、そのウィンドウを出します）。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(AppVersion.current)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Toggle("使っていないときは自動で隠す", isOn: $store.prefs.autoHide)
            Toggle("macOS の Dock を隠す", isOn: $store.prefs.hideSystemDock)
            HStack {
                Button("GroupDock を再起動") { SelfRestart.run(store: store) }
                Text("設定の反映やアクセシビリティの許可を変えたときに使います。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("起動中のアプリは「残さない」区分に出て、終了で消えます。設定の「アプリを追加」で足したアプリは「バーに残す」区分に入り、終了しても残ります。グループは「バーに残す」アプリの区画にだけ作れます。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 見た目

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("見た目").font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("置く位置").font(.subheadline)
                Picker("置く位置", selection: $store.prefs.position) {
                    Text("下").tag("bottom")
                    Text("左").tag("left")
                    Text("右").tag("right")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                positionPreview
                Text(store.prefs.position == "bottom"
                     ? "画面の下中央に横並びで出ます。上端のつまみで大きさを変えられます。"
                     : "画面の端に縦並びで出ます。大きさは下のスライダーで変えられます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("すべてのディスプレイに表示", isOn: $store.prefs.allDisplays)
                    .help("接続しているすべての画面に同じ帯を出します（標準はメイン画面だけ）")
                Text(store.prefs.allDisplays
                     ? "いま \(NSScreen.screens.count) 台の画面すべてに出しています。"
                     : "メイン画面にだけ出しています。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("アイコンの大きさ")
                Slider(value: $store.prefs.iconSize, in: 36...88, step: 1)
                Text("\(Int(store.prefs.iconSize)) pt")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("収まらないとき").font(.subheadline)
                Picker("収まらないとき", selection: $store.prefs.overflow) {
                    Text("縮める").tag("shrink")
                    Text("ページを切り替える").tag("pages")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(store.prefs.overflow == "pages"
                     ? "大きさを保ち、ウィジェットとアプリを別々のページに分けます。帯の矢印を押すと次のページです。ページを送っても帯の大きさは変わりません。"
                     : "標準 Dock と同じく、画面に収まるまでアイコンを縮めます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if store.prefs.overflow == "pages" {
                    Stepper(value: $store.prefs.stripLines, in: 1...6) {
                        Text("縦に並べる数：\(store.prefs.stripLines)")
                    }
                    Text(store.prefs.position == "bottom"
                         ? "帯を何段に並べるかを決めます（標準 1）。ページに関係なく一定です。"
                         : "帯を何列に並べるかを決めます（標準 1）。ページに関係なく一定です。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if store.prefs.overflow != "pages", store.effectiveIconSize < CGFloat(store.prefs.iconSize) - 0.5 {
                    Text("いま画面に収めるため \(Int(store.effectiveIconSize)) pt に縮めています（スライダーの値を変えても、収まる大きさが上限です）。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            HStack {
                Text("アイコンの間隔（グループの中も同じ）")
                Slider(value: $store.prefs.gap, in: 0...24, step: 1)
                Text("\(Int(store.prefs.gap)) pt")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
            Toggle("アイコンの下に名前を出す", isOn: $store.prefs.showNames)
        }
    }

    /// 選んだ位置を小さな枠で示す（どこに出るか分かるように）。
    private var positionPreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.06))
                .frame(width: 120, height: 72)
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.accentColor)
                .frame(
                    width: store.prefs.position == "bottom" ? 60 : 6,
                    height: store.prefs.position == "bottom" ? 6 : 42
                )
                .offset(
                    x: store.prefs.position == "bottom" ? 0 : (store.prefs.position == "left" ? -55 : 55),
                    y: store.prefs.position == "bottom" ? 30 : 0
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - アプリ

    private var appsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("アプリ").font(.headline)
            HStack(spacing: 10) {
                Button("アプリを追加…") { openPicker() }
                Button("Dock のアプリを取り込む") {
                    store.importDockApps(into: store.expanded ?? store.groups.first?.id)
                }
            }
            Text("Finder と アプリ（Apps）は固定で、外したり移動したりできません。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("帯のアイコンの右クリックで「バーから外す」「グループから外す」が選べます。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }


    // MARK: - ウィジェット

    private var widgetsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("ウィジェット").font(.headline)
                Spacer()
                Button("ギャラリー…") { openGallery() }
                Menu("追加") {
                    ForEach(WidgetKind.allCases.filter { $0 != .custom }) { kind in
                        Button(kind.title) { store.prefs.widgets.append(Widget(kind: kind)) }
                    }
                    if !WidgetLibrary.definitions.isEmpty {
                        Divider()
                        ForEach(WidgetLibrary.definitions) { def in
                            Button("ライブラリ: \(def.title)") {
                                store.prefs.widgets.append(Widget(definition: def))
                            }
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .frame(width: 70)
            }
            Text("追加したウィジェットの見た目・更新頻度・項目は、帯のウィジェットを右クリック →「設定…」で変えられます。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !WidgetLibrary.definitions.isEmpty {
                Text("ライブラリから: " + WidgetLibrary.definitions.map(\.title).joined(separator: "、"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if store.prefs.widgets.isEmpty {
                Text("まだウィジェットがありません")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("いま置いてあるもの: " + store.prefs.widgets.map(\.kind.title).joined(separator: "、"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// 設定の窓。
final class SettingsWindowController {
    private let panel: NSPanel
    private let store: Store

    init(
        store: Store,
        openPicker: @escaping () -> Void = {},
        openGallery: @escaping () -> Void = {}
    ) {
        self.store = store
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "GroupDock の設定"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(
            rootView: SettingsView(
                store: store,
                onClose: { [weak panel] in panel?.close() },
                openPicker: openPicker,
                openGallery: openGallery
            )
        )
        panel.center()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        centerOnActiveScreen()
        panel.makeKeyAndOrderFront(nil)
    }

    /// マウスのある画面の中央に出す（別ディスプレイに出て行かないように）。
    private func centerOnActiveScreen() {
        guard let screen = ScreenPick.active() else { return }
        let area = screen.visibleFrame
        let size = panel.frame.size
        let frame = NSRect(
            x: area.midX - size.width / 2,
            y: area.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        panel.setFrame(ScreenPick.clamp(frame, in: screen), display: false)
    }
}
