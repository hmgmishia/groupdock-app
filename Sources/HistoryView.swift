import AppKit
import SwiftUI

/// 履歴ボタン。押すと、グループの吹き出しと同じ「アイコンの並び」のポップアップで選ぶ（普通のリストは使わない）。
struct HistoryButton<Face: View>: View {
    @ObservedObject var store: Store
    let size: CGFloat
    let face: Face
    @State private var showing = false

    var body: some View {
        face
            .onTapGesture { showing = true }
            .onReceive(NotificationCenter.default.publisher(for: .groupDockDismissPopovers)) { _ in showing = false }
            .popover(isPresented: $showing, arrowEdge: store.popoverEdge) {
                HistoryGrid(store: store, size: size, onPick: { showing = false })
            }
    }
}

/// アイコンの格子（履歴・インスタンス選択で共通）。枠は `GridMetrics` が決め、ここは置くだけ。
struct IconGrid<Item: Identifiable, Content: View>: View {
    let items: [Item]
    let size: CGFloat
    let showNames: Bool
    let gap: CGFloat
    /// 左右に置くとき（縦長の格子）。
    var vertical = false
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        let grid = GridMetrics.make(count: items.count, iconSize: size, showNames: showNames, gap: gap, vertical: vertical)
        ZStack(alignment: .topLeading) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                content(item)
                    .frame(width: grid.tiles[index].width, height: grid.tiles[index].height)
                    .offset(x: grid.tiles[index].minX, y: grid.tiles[index].minY)
            }
        }
        .frame(width: grid.size.width, height: grid.size.height, alignment: .topLeading)
    }
}

/// 履歴のポップアップの中身。同じアプリは 1 つ、引数違いは別のアイコン。
struct HistoryGrid: View {
    @ObservedObject var store: Store
    let size: CGFloat
    let onPick: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("最近起動したアプリ").font(.headline)
            if store.history.isEmpty {
                Text("履歴はありません").font(.caption).foregroundStyle(.secondary)
            } else {
                IconGrid(items: store.history, size: size, showNames: store.prefs.showNames, gap: CGFloat(store.prefs.gap),
                         vertical: store.prefs.position != "bottom") { ref in
                    HistoryTile(store: store, ref: ref, size: size, onPick: onPick)
                }
            }
        }
        .padding(12)
        .fixedSize()
    }
}

/// 履歴の 1 アイコン。押すと起動。hover と右クリックで、パス・引数・起動中かが分かる。
struct HistoryTile: View {
    @ObservedObject var store: Store
    let ref: AppRef
    let size: CGFloat
    let onPick: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 3) {
            Image(nsImage: ref.icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: StripLayout.imageSide(size), height: StripLayout.imageSide(size))
                .overlay(alignment: .topTrailing) {
                    // 引数つきは、通常の起動と見分けるための印。
                    if !ref.arguments.isEmpty {
                        Image(systemName: "text.append")
                            .font(.system(size: 9, weight: .bold))
                            .padding(2)
                            .background(Circle().fill(Color.accentColor))
                            .foregroundStyle(.white)
                            .offset(x: 4, y: -4)
                    }
                }
            StatusDots(
                running: ref.bundleID.map { store.runningBundleIDs.contains($0) } ?? false,
                multiple: store.hasMultipleInstances(ref.path))
            if store.prefs.showNames { TileName(text: ref.name, width: StripLayout.nameWidth(size), fontSize: 9) }
        }
        .padding(.vertical, StripLayout.defaultTilePadding)
        .padding(.horizontal, StripLayout.defaultTilePadding)
        .background(RoundedRectangle(cornerRadius: 10).fill(hovering ? Color.accentColor.opacity(0.20) : .clear))
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            HoverLabel.popupHover(inside, text: HistoryInfo.text(ref))
        }
        .onDisappear { HoverLabel.popup.hide() }
        .onTapGesture {
            HoverLabel.popup.hide()
            Launcher.open(ref)
            onPick()
        }
        .contextMenu {
            Text(HistoryInfo.text(ref))
            Divider()
            Button("起動") { Launcher.open(ref); onPick() }
            Button("Finder で開く") { Launcher.revealInFinder(ref) }
            Button("パスをコピー") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(ref.path, forType: .string)
            }
            if !ref.arguments.isEmpty {
                Button("引数をコピー") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ref.arguments, forType: .string)
                }
            }
            Divider()
            Button("履歴から消す") { store.removeHistory(id: ref.id) }
        }
    }
}
