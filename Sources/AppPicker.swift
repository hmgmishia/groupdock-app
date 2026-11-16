import AppKit
import SwiftUI

/// /Applications などを走査してアプリを集める。
enum AppLibrary {
    private static let roots = [
        "/Applications",
        "/System/Applications",
        "/Applications/Utilities",
        "/System/Applications/Utilities",
        NSHomeDirectory() + "/Applications",
    ]

    /// フォルダ名（親フォルダ）ごとのアプリ。フォルダで分けて見せるために使う。
    static func scan() -> [(folder: String, apps: [AppRef])] {
        var byFolder: [String: [AppRef]] = [:]
        var seen = Set<String>()

        for root in roots {
            let url = URL(fileURLWithPath: root)
            let children = (try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            for child in children {
                // 深さ 2 まで（"Blackmagic RAW/xxx.app" のような入れ子を拾う）
                if child.pathExtension == "app" {
                    let path = child.resolvingSymlinksInPath().path
                    guard seen.insert(path).inserted else { continue }
                    byFolder[(root as NSString).lastPathComponent, default: []].append(AppRef(path: path))
                } else if (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    let inner = (try? FileManager.default.contentsOfDirectory(
                        at: child,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]
                    )) ?? []
                    for app in inner where app.pathExtension == "app" {
                        let path = app.resolvingSymlinksInPath().path
                        guard seen.insert(path).inserted else { continue }
                        byFolder[child.lastPathComponent, default: []].append(AppRef(path: path))
                    }
                }
            }
        }

        return byFolder
            .map { (folder: $0.key, apps: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.folder < $1.folder }
    }
}

/// アプリを検索して、グループに追加する画面。
struct AppPickerView: View {
    @ObservedObject var store: Store
    /// 追加先のグループ（nil なら新規作成）。
    @State private var target: Group.ID?
    @State private var newGroupName = "新しいグループ"
    @State private var query = ""
    @State private var selected: Set<String> = []
    @State private var sections: [(folder: String, apps: [AppRef])] = []
    @State private var hovered: String?
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("アプリを追加")
                .font(.headline)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("名前で検索", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))

            Picker("追加先", selection: $target) {
                Text("新しいグループ").tag(Group.ID?.none)
                ForEach(store.groups) { group in
                    Text(group.name).tag(Group.ID?.some(group.id))
                }
            }
            .frame(maxWidth: 300)

            if target == nil {
                TextField("新しいグループ名", text: $newGroupName)
                    .textFieldStyle(.roundedBorder)
            }

            List {
                ForEach(filtered, id: \.folder) { section in
                    Section {
                        ForEach(section.apps) { ref in
                            row(ref)
                        }
                    } header: {
                        HStack(spacing: 8) {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            Text(section.folder)
                            Spacer()
                            Button("このフォルダをすべて追加") {
                                selected.formUnion(section.apps.map(\.path))
                            }
                            .font(.caption)
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 280)

            HStack {
                Text("\(selected.count) 個を選択")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("キャンセル") { onClose() }
                Button("追加") { addSelected() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 520, height: 520)
        .onAppear {
            if sections.isEmpty { sections = AppLibrary.scan() }
            target = store.expanded ?? store.groups.first?.id
        }
    }

    private var filtered: [(folder: String, apps: [AppRef])] {
        guard !query.isEmpty else { return sections }
        return sections.compactMap { section in
            let apps = section.apps.filter { $0.name.localizedCaseInsensitiveContains(query) }
            return apps.isEmpty ? nil : (folder: section.folder, apps: apps)
        }
    }

    private func row(_ ref: AppRef) -> some View {
        let isOn = selected.contains(ref.path)
        let isHovered = hovered == ref.path
        return Button {
            if isOn { selected.remove(ref.path) } else { selected.insert(ref.path) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? Color.accentColor : .secondary)
                Image(nsImage: ref.icon)
                    .resizable()
                    .frame(width: 18, height: 18)
                Text(ref.name)
                Spacer()
                if isHovered {
                    Text(ref.path)
                        .font(.system(size: Typo.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.accentColor.opacity(0.18) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hovered = ref.path } else if hovered == ref.path { hovered = nil }
        }
    }

    private func addSelected() {
        let paths = selected.sorted()
        if let id = target, let index = store.groups.firstIndex(where: { $0.id == id }) {
            // グループへ入れる：残す＝オンで、グループの末尾へ。
            for path in paths where !store.groups[index].apps.contains(where: { $0.path == path }) {
                store.groups[index].apps.append(AppRef(path: path, keepWhenQuit: true))
            }
        } else {
            // 既定はアプリ一覧の末尾（残す＝オン）。グループを作るのは「新しいグループ」を選んだときだけ。
            store.addToStrip(paths: paths)
        }
        onClose()
    }
}

/// ピッカーの窓。
final class AppPickerWindowController {
    private let panel: NSPanel
    private let store: Store

    init(store: Store) {
        self.store = store
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "アプリを追加"
        panel.isFloatingPanel = true
        panel.level = .floating
    }

    func show() {
        // 開くたびに作り直す（検索語や選択が残らないように）。
        panel.contentView = NSHostingView(
            rootView: AppPickerView(store: store, onClose: { [weak panel] in panel?.close() })
        )
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
}
