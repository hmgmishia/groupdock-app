import AppKit
import SwiftUI

/// 1 つのグループの設定。グループのタイルを右クリック →「グループの設定…」で開く。
/// 名前・アプリの並び順・アプリの追加と外す・起動と終了・削除を、このグループだけで変える。
struct GroupSettingsView: View {
    @ObservedObject var store: Store
    let groupID: UUID
    var onClose: () -> Void

    private var index: Int? { store.groups.firstIndex { $0.id == groupID } }

    var body: some View {
        if let index {
            content(group: $store.groups[index])
        } else {
            Text("このグループは削除されています")
                .padding(20)
                .frame(width: 380)
                .onAppear(perform: onClose)
        }
    }

    private func content(group: Binding<Group>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("名前").frame(width: 40, alignment: .leading)
                TextField("グループ名", text: group.name)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Text("アプリ（\(group.wrappedValue.apps.count) 個）").font(.subheadline).bold()
                Spacer()
                Button("名前順に並べる") { group.wrappedValue.apps = GroupOrder.byName(group.wrappedValue.apps) }
                    .disabled(group.wrappedValue.apps.count < 2)
                Button("アプリを追加…") { store.addAppsTo(groupID) }
            }
            .font(.caption)

            if group.wrappedValue.apps.isEmpty {
                Text("アプリがありません。「アプリを追加…」か、帯のアイコンをこのグループに重ねて入れます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // 上下のボタンで並べ替える。帯の吹き出しでのドラッグと同じ並びが変わる。
                List {
                    ForEach(Array(group.wrappedValue.apps.enumerated()), id: \.element.id) { position, ref in
                        row(ref, position: position, group: group)
                    }
                    .onMove { from, to in group.wrappedValue.apps.move(fromOffsets: from, toOffset: to) }
                }
                .frame(minHeight: 160, maxHeight: 320)
            }

            Divider()
            HStack {
                Button("すべて起動") { Launcher.openAll(group.wrappedValue.apps, group: group.wrappedValue.name) }
                Button("すべて終了") { Launcher.quitAll(group.wrappedValue.apps, group: group.wrappedValue.name) }
                Spacer()
                Button("グループを削除", role: .destructive) {
                    store.remove(group.wrappedValue)
                    onClose()
                }
            }
            .font(.caption)
        }
        .padding(16)
        .frame(width: 440)
    }

    private func row(_ ref: AppRef, position: Int, group: Binding<Group>) -> some View {
        let count = group.wrappedValue.apps.count
        return HStack(spacing: 8) {
            Image(nsImage: ref.icon).resizable().frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(ref.name).lineLimit(1)
                if !ref.arguments.isEmpty {
                    Text("引数: \(ref.arguments)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Button { group.wrappedValue.apps = GroupOrder.move(group.wrappedValue.apps, index: position, by: -1) } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(position == 0)
            .help("前へ")
            Button { group.wrappedValue.apps = GroupOrder.move(group.wrappedValue.apps, index: position, by: 1) } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(position == count - 1)
            .help("後ろへ")
            Button { group.wrappedValue.apps.removeAll { $0.id == ref.id } } label: {
                Image(systemName: "minus.circle")
            }
            .disabled(ref.isPinned)
            .help("グループから外す")
        }
        .buttonStyle(.borderless)
    }
}

/// グループの設定の窓。ウィンドウの閉じるボタンで閉じる。
final class GroupSettingsWindowController {
    private let store: Store
    private var panel: NSPanel?

    init(store: Store) {
        self.store = store
    }

    func show(groupID: UUID) {
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(
            rootView: GroupSettingsView(store: store, groupID: groupID, onClose: { [weak panel] in panel?.close() })
        )
        let name = store.groups.first { $0.id == groupID }?.name ?? ""
        panel.title = name.isEmpty ? "グループの設定" : "「\(name)」の設定"
        if let screen = ScreenPick.active() {
            let area = screen.visibleFrame
            let size = panel.frame.size
            panel.setFrame(ScreenPick.clamp(NSRect(
                x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                width: size.width, height: size.height), in: screen), display: false)
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 480),
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
