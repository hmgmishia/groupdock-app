import AppKit
import SwiftUI

/// 複数のインスタンスが動いていることを示す青丸（アイコンの下、緑丸の右）。
struct MultiDot: View {
    var body: some View {
        Circle().fill(Color.blue).frame(width: 5, height: 5)
    }
}

/// アイコンの下の印。起動中は緑、2 つ以上なら青も並べる。
struct StatusDots: View {
    let running: Bool
    let multiple: Bool

    var body: some View {
        HStack(spacing: 3) {
            if running { RunningDot() }
            if multiple { MultiDot() }
        }
        .frame(height: 5)
    }
}

/// インスタンスを選ぶポップアップ。グループと同じ、アイコンの並びで出す。
struct InstancePicker: View {
    @ObservedObject var store: Store
    let ref: AppRef
    let size: CGFloat
    let onPick: () -> Void
    @State private var instances: [AppInstance] = []
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(ref.name) のインスタンス・ウィンドウ").font(.headline)
            if !loaded {
                Text("読み込み中…").font(.caption).foregroundStyle(.secondary)
            } else if instances.isEmpty {
                Text("起動していません").font(.caption).foregroundStyle(.secondary)
            } else {
                IconGrid(items: instances, size: size, showNames: store.prefs.showNames, gap: CGFloat(store.prefs.gap),
                         vertical: store.prefs.position != "bottom") { instance in
                    InstanceTile(
                        ref: ref, instance: instance, size: size, showName: store.prefs.showNames,
                        padding: StripLayout.defaultTilePadding,
                        onPick: onPick, onChanged: reload)
                }
            }
        }
        .padding(12)
        .fixedSize()
        .onAppear(perform: reload)
    }

    private func reload() {
        let id = ref.bundleID
        DispatchQueue.global(qos: .userInitiated).async {
            let list = id.map { AppInstances.read(bundleID: $0) } ?? []
            DispatchQueue.main.async {
                instances = list
                loaded = true
            }
        }
    }
}

/// 1 つのインスタンス。押すと前面へ。hover と右クリックで pid と引数が分かる。
struct InstanceTile: View {
    let ref: AppRef
    let instance: AppInstance
    let size: CGFloat
    let showName: Bool
    let padding: CGFloat
    let onPick: () -> Void
    let onChanged: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 3) {
            Image(nsImage: ref.icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: StripLayout.imageSide(size), height: StripLayout.imageSide(size))
            RunningDot()
            // 名前は設定で出す。出すときは区別のため、ウィンドウ名・引数・pid のどれかを出す。
            if showName { TileName(text: label, width: StripLayout.nameWidth(size), fontSize: 9) }
        }
        .padding(.vertical, padding)
        .padding(.horizontal, padding)
        .background(RoundedRectangle(cornerRadius: 10).fill(hovering ? Color.accentColor.opacity(0.20) : .clear))
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            HoverLabel.popupHover(inside, text: AppInstances.info(instance, name: ref.name))
        }
        .onDisappear { HoverLabel.popup.hide() }
        .onTapGesture {
            HoverLabel.popup.hide()
            AppInstances.raise(instance)
            onPick()
        }
        .contextMenu {
            Text(AppInstances.info(instance, name: ref.name))
            Divider()
            Button("前面に出す") {
                AppInstances.raise(instance)
                onPick()
            }
            Button("Finder で開く") { Launcher.revealInFinder(ref) }
            if !instance.arguments.isEmpty {
                Button("引数をコピー") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(instance.arguments, forType: .string)
                }
            }
            Divider()
            Button("このインスタンスを終了") {
                NSRunningApplication(processIdentifier: instance.pid)?.terminate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { onChanged() }
            }
        }
    }

    private var label: String {
        if instance.window != nil { return instance.windowTitle.isEmpty ? "ウィンドウ \((instance.window ?? 0) + 1)" : instance.windowTitle }
        return instance.arguments.isEmpty ? "pid \(instance.pid)" : instance.arguments
    }
}
