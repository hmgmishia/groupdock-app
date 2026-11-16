import AppKit
import SwiftUI

/// 画面端に浮かぶ帯。枠は `StripLayout`（状態から計算）で決まり、ここは置くだけ。
/// 描画結果を状態へ書き戻さないので、レイアウト中に状態が変わることがない。
struct DockView: View {
    @ObservedObject var store: Store
    let openSettings: () -> Void
    let openPicker: () -> Void
    let openWidgetSettings: (UUID) -> Void

    private var size: CGFloat { store.effectiveIconSize }

    var body: some View {
        let layout = store.stripLayout()
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 18)
                .fill(.ultraThinMaterial)
                .shadow(radius: 8, y: 2)
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.primary.opacity(0.10)))
                .frame(
                    width: max(0, layout.size.width - StripLayout.shadowMargin * 2),
                    height: max(0, layout.size.height - StripLayout.shadowMargin * 2))
                .offset(x: StripLayout.shadowMargin, y: StripLayout.shadowMargin)
            ForEach(layout.placed) { item in
                tile(item.entry)
                    .frame(width: item.frame.width, height: item.frame.height)
                    .offset(x: item.frame.minX, y: item.frame.minY)
                    .transition(Motion.insert)
            }
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
        // 枠が変わったら（並び替え・道を空ける・大きさの変更）、Apple 標準のスプリングで滑らかに動かす。
        .animation(Motion.spring, value: layout)
        // ドラッグ中はウィンドウを空け分だけ広く固定する。中身は中央に置き、広がっても位置が飛ばない。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func tile(_ entry: StripEntry) -> some View {
        switch entry.kind {
        case .widget(let id):
            if let index = store.prefs.widgets.firstIndex(where: { $0.id == id }) {
                WidgetTile(
                    store: store,
                    widget: $store.prefs.widgets[index],
                    size: size,
                    text: store.widgetText[id],
                    onRemove: { store.prefs.widgets.removeAll { $0.id == id } },
                    onSettings: { openWidgetSettings(id) }
                )
            }
        case .pinned(let ref):
            StripAppTile(store: store, ref: ref, size: size, pinned: true)
        case .kept(let ref):
            StripAppTile(store: store, ref: ref, size: size, pinned: false)
        case .group(let id):
            if let index = store.groups.firstIndex(where: { $0.id == id }) {
                GroupTile(store: store, group: $store.groups[index], size: size, drop: store.dropState)
            }
        case .running(let ref):
            RunningTile(store: store, ref: ref, size: size, badge: store.badges[ref.path])
        case .history:
            historyMenu
        case .trash:
            iconButton(symbol: "trash", label: "ゴミ箱", help: "ゴミ箱を開く") { TrashActions.open() }
                .contextMenu {
                    ForEach(TrashMenuSpec.items(isEmpty: TrashActions.isEmpty), id: \.title) { item in
                        Button(item.title) {
                            switch item.action {
                            case .open: TrashActions.open()
                            case .empty: TrashActions.confirmAndEmpty(on: store.nowPlayingQueue)
                            }
                        }
                        .disabled(!item.enabled)
                    }
                }
        case .settings:
            iconButton(symbol: "gearshape.fill", label: "設定", help: "設定", action: openSettings)
        case .pager(let section, let page, let count):
            pagerButton(section: section, page: page, count: count)
        case .separator:
            // 枠は余白つき（右クリックを当てやすい）。線は中央に 1pt だけ描く。
            let vertical = store.prefs.position != "bottom"
            Color.clear.overlay(
                Rectangle().fill(Color.primary.opacity(0.15))
                    .frame(width: vertical ? nil : StripLayout.separatorThickness,
                           height: vertical ? StripLayout.separatorThickness : nil))
        }
    }

    /// ページ送り（ページ切り替えの方式）。◀ ▶ で前後に送り、真ん中に「いまのページ / ページ数」を出す。
    /// 端は反対側へ戻る。ウィジェットとアプリは別々のページ送りで、どちらの区画かは色（ウィジェットは青、アプリは灰）で分かる。
    private func pagerButton(section: StripSection, page: Int, count: Int) -> some View {
        let vertical = store.prefs.position != "bottom"
        let tint: Color = section == .widgets ? .accentColor : .secondary
        let name = section == .widgets ? "ウィジェット" : "アプリ"
        func arrow(_ symbol: String, _ delta: Int, _ help: String) -> some View {
            Button { store.setPage(section, StripPaging.turned(page: page, count: count, by: delta)) } label: {
                Image(systemName: symbol).font(.system(size: Typo.caption, weight: .bold)).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help)
        }
        let label = Text("\(page + 1)/\(count)").font(.system(size: Typo.caption, weight: .semibold)).monospacedDigit()
        return SwiftUI.Group {
            if vertical {
                VStack(spacing: 0) {
                    arrow("chevron.up", -1, "\(name)：前のページ")
                    label
                    arrow("chevron.down", 1, "\(name)：次のページ")
                }
            } else {
                HStack(spacing: 0) {
                    arrow("chevron.left", -1, "\(name)：前のページ")
                    label
                    arrow("chevron.right", 1, "\(name)：次のページ")
                }
            }
        }
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 6).fill(tint.opacity(0.12)))
    }

    /// 最近起動したアプリ。グループと同じ、アイコンのポップアップで選ぶ。
    private var historyMenu: some View {
        HistoryButton(store: store, size: size, face: buttonFace(symbol: "clock.arrow.circlepath", label: "履歴"))
    }

    /// 履歴・ゴミ箱・設定のボタン。アプリのタイルと同じ寸法（画像の一辺・余白・名前の幅）にし、同じ選択枠を出す。
    private func buttonFace(symbol: String, label: String) -> some View {
        StripButtonFace(symbol: symbol, label: label, size: size, showNames: store.prefs.showNames)
    }

    private func iconButton(
        symbol: String,
        label: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) { buttonFace(symbol: symbol, label: label) }
            .buttonStyle(.plain)
            .help(help)
    }
}

/// 帯のボタンの見た目。アプリのタイル（`StripAppTile`）と同じ寸法・同じ選択枠にそろえる。
struct StripButtonFace: View {
    let symbol: String
    let label: String
    let size: CGFloat
    let showNames: Bool
    @State private var hovering = false

    var body: some View {
        let side = StripLayout.imageSide(size)
        VStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: side * 0.42))
                .frame(width: side, height: side)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.08)))
            if showNames { TileName(text: label, width: StripLayout.nameWidth(size), fontSize: 9) }
        }
        .padding(StripLayout.defaultTilePadding)
        .background(RoundedRectangle(cornerRadius: 10).fill(hovering ? Color.accentColor.opacity(0.20) : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// 起動中を示す緑丸（アイコンの下）。
struct RunningDot: View {
    var body: some View {
        Circle().fill(Color.green)
            .frame(width: 5, height: 5)
    }
}

/// アイコンの下の名前。設定で出す（基本は出さない）。
struct TileName: View {
    let text: String
    let width: CGFloat
    let fontSize: CGFloat

    var body: some View {
        Text(text)
            .font(.system(size: fontSize))
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(width: width)
    }
}

/// 標準 Dock と同じ、アイコン右上の赤い未読バッジ。
struct BadgeView: View {
    let text: String
    let size: CGFloat

    var body: some View {
        Text(text)
            .font(.system(size: max(8, size * 0.22), weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, size * 0.12)
            .frame(minWidth: size * BadgeMetrics.heightRatio, minHeight: size * BadgeMetrics.heightRatio)
            .background(Capsule().fill(Color.red))
            .offset(x: size * 0.26, y: -size * BadgeMetrics.liftRatio)
    }
}

/// 帯に置くウィジェット。数値系はリング、時計・日付は文字で出す。
struct WidgetTile: View {
    @ObservedObject var store: Store
    @Binding var widget: Widget
    let size: CGFloat
    let text: WidgetText?
    let onRemove: () -> Void
    let onSettings: () -> Void
    @State private var showDetail = false
    @State private var hovering = false

    private var fraction: Double? { text?.fraction }

    private var tint: Color { widget.tintColor }

    private var vertical: Bool { store.prefs.position != "bottom" }
    /// タイルの大きさ（帯の向き・見え方・内容から決まる）。
    private var tileSize: CGSize { widget.tileSize(icon: size, vertical: vertical) }
    private var width: CGFloat { tileSize.width }

    private var history: [Double] { store.widgetHistory[widget.id] ?? [] }

    var body: some View {
        VStack(spacing: 3) {
            if widget.kind == .nowPlaying {
                NowPlayingFace(
                    state: store.nowPlaying,
                    layout: widget.playerLook(vertical: vertical),
                    size: size,
                    tint: widget.tintColor,
                    vertical: vertical,
                    control: { store.playback($0) },
                    seek: { store.seekPlayback(to: $0) }
                )
                .frame(width: tileSize.width, height: tileSize.height)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.primary.opacity(hovering ? 0.18 : 0.10))
                )
            } else {
                // 見え方（リング・文字・横長の文字／バー／グラフ）は共通部品で描く。幅は内容から決まる。
                WidgetFaceView(
                    face: widget.look(vertical: vertical), big: big, fraction: fraction, symbol: widget.symbol,
                    tint: tint, size: size, history: history)
                    .frame(width: tileSize.width, height: tileSize.height)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.primary.opacity(hovering ? 0.18 : 0.10))
                    )
            }
            if widget.showLabel, store.prefs.showNames {
                Text(label)
                    .font(.system(size: Typo.label))
                    .lineLimit(1)
                    .frame(width: width + 2)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { showDetail = true }
        .onReceive(NotificationCenter.default.publisher(for: .groupDockDismissPopovers)) { _ in showDetail = false }
        .popover(isPresented: $showDetail, arrowEdge: store.popoverEdge) {
            VStack(alignment: .leading, spacing: 8) {
                Label(widget.kind.title, systemImage: widget.kind.symbol).font(.headline)
                if widget.kind == .nowPlaying {
                    NowPlayingPopup(state: store.nowPlaying, store: store)
                } else if widget.kind == .clipboard {
                    ClipboardPopup(clipboard: store.clipboard, onClose: { showDetail = false })
                } else if widget.kind == .volume || widget.kind == .microphone {
                    Text(text?.detail ?? widget.kind.title).font(.callout)
                    AudioWidgetControls(widget: $widget)
                } else if widget.kind == .brightness {
                    Text(text?.detail ?? widget.kind.title).font(.callout)
                    BrightnessWidgetControls(widget: $widget)
                } else {
                    Text(text?.detail ?? widget.kind.title).font(.callout)
                    WidgetActionsView(kind: widget.kind)
                }
                if let destination = widget.kind.destination {
                    Button(destination.title) {
                        showDetail = false
                        widget.kind.openDestination()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                HStack {
                    Button("設定…") {
                        showDetail = false
                        onSettings()
                    }
                    Spacer()
                    Button("外す") { onRemove() }
                }
                .font(.caption)
            }
            .padding(12)
            .frame(minWidth: 200)
            .fixedSize(horizontal: true, vertical: true)
        }
        .contextMenu {
            Button("設定…") { onSettings() }
            Divider()
            Button("詳細を表示") { showDetail = true }
            Divider()
            Button("このウィジェットを外す") { onRemove() }
        }
    }

    private var label: String {
        if widget.kind == .custom { return widget.title }
        switch widget.kind {
        case .clock, .date:
            if let id = widget.timeZoneID, let zone = TimeZone(identifier: id) {
                return zone.identifier.split(separator: "/").last.map(String.init) ?? zone.identifier
            }
            return widget.kind.title
        default:
            return text?.small ?? widget.kind.title
        }
    }

    private var big: String { text?.big ?? "—" }
}

/// グループに入っていない実行中のアプリ。クリックで前面に出す。
struct RunningTile: View {
    @ObservedObject var store: Store
    let ref: AppRef
    let size: CGFloat
    let badge: String?
    @State private var hovering = false
    @State private var picking = false

    private var multiple: Bool { store.hasMultipleInstances(ref.path) }

    var body: some View {
        VStack(spacing: 3) {
            Image(nsImage: ref.icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: StripLayout.imageSide(size), height: StripLayout.imageSide(size))
                .overlay(alignment: .top) {
                    if let badge { BadgeView(text: badge, size: size) }
                }
            StatusDots(running: true, multiple: multiple)
            if store.prefs.showNames { TileName(text: ref.name, width: StripLayout.nameWidth(size), fontSize: 9) }
        }
        .padding(.vertical, StripLayout.defaultTilePadding)
        .padding(.horizontal, StripLayout.defaultTilePadding)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(hovering ? Color.accentColor.opacity(0.20) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            if multiple { picking = true } else { Launcher.open(ref) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .groupDockDismissPopovers)) { _ in picking = false }
        .popover(isPresented: $picking, arrowEdge: store.popoverEdge) {
            InstancePicker(store: store, ref: ref, size: size, onPick: { picking = false })
        }
        .contextMenu {
            Button("前面に出す") { Launcher.open(ref) }
            Button("Finder で開く") { Launcher.revealInFinder(ref) }
            if multiple { Button("インスタンスを選ぶ…") { picking = true } }
            if store.isKept(ref.path) {
                Button("バーから外す") { store.removeEverywhere(ref.path) }
            } else {
                Button("バーに残す") { store.keepOnStrip(ref.path) }
            }
            Divider()
            Button("再起動") { Launcher.restart(ref) }
            if store.hungPaths.contains(ref.path) {
                Button("強制終了") { Launcher.forceQuit(ref) }
            } else {
                Button("終了") { Launcher.quit(ref) }
            }
        }
    }
}

/// 1 グループ = 中身のアイコンを重ねたフォルダタイル。押すと吹き出しで中身を出す。
struct GroupTile: View {
    @ObservedObject var store: Store
    @Binding var group: Group
    let size: CGFloat
    @ObservedObject var drop: DropState
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 3) {
            face
                .frame(width: StripLayout.imageSide(size), height: StripLayout.imageSide(size))
                .overlay(alignment: .top) {
                    if let badge = groupBadge { BadgeView(text: badge, size: size) }
                }
            if hasRunning { RunningDot() } else { Color.clear.frame(width: 5, height: 5) }
            if store.prefs.showNames {
                EditableGroupName(name: $group.name, font: .system(size: Typo.label),
                                  width: StripLayout.nameWidth(size), alignment: .center)
            }
        }
        .padding(.vertical, StripLayout.defaultTilePadding)
        .padding(.horizontal, StripLayout.defaultTilePadding)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(highlight)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            // SwiftUI の更新中に開閉の状態を書くと固まるので、次のループで切り替える。
            DispatchQueue.main.async {
                store.expanded = store.expanded == group.id ? nil : group.id
            }
        }
        .dropDestination(for: String.self) { items, _ in
            store.moveInto(group.id, appIDs: items)
        }
        .contextMenu {
            Button("中身を開く") { store.expanded = group.id }
            Button("グループの設定…") {
                NotificationCenter.default.post(name: .groupDockOpenGroupSettings, object: group.id)
            }
            Button("このグループを起動") { Launcher.openAll(group.apps, group: group.name) }
            Button("このグループを終了") { Launcher.quitAll(group.apps, group: group.name) }
            Divider()
            Button("グループを削除", role: .destructive) { store.remove(group) }
        }
    }

    private var highlight: Color {
        if drop.targetID == "group:\(group.id.uuidString)" {
            return Color.accentColor.opacity(0.35)
        }
        return hovering ? Color.accentColor.opacity(0.20) : Color.clear
    }

    private var face: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.08))
            if group.apps.isEmpty {
                Image(systemName: "folder")
                    .font(.system(size: StripLayout.imageSide(size) * 0.42))
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(.fixed(StripLayout.imageSide(size) / 3), spacing: 3),
                        GridItem(.fixed(StripLayout.imageSide(size) / 3), spacing: 3),
                    ],
                    spacing: 3
                ) {
                    ForEach(Array(group.apps.prefix(4))) { ref in
                        Image(nsImage: ref.icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: StripLayout.imageSide(size) / 3, height: StripLayout.imageSide(size) / 3)
                    }
                }
            }
        }
    }

    private var groupBadge: String? {
        var total = 0
        var hasAny = false
        for ref in group.apps {
            guard let badge = store.badges[ref.path] else { continue }
            hasAny = true
            if let number = Int(badge) { total += number }
        }
        guard hasAny else { return nil }
        return total > 0 ? "\(total)" : "•"
    }

    private var hasRunning: Bool {
        group.apps.contains { ref in
            guard let id = ref.bundleID else { return false }
            return store.runningBundleIDs.contains(id)
        }
    }
}

/// 吹き出しの中身。枠は `BubbleLayout`（件数とアイコンの大きさから計算）で決まり、ここは置くだけ。
struct GroupBubbleView: View {
    @ObservedObject var store: Store
    @Binding var group: Group
    let size: CGFloat
    @ObservedObject var drop: DropState

    var body: some View {
        let layout = store.bubbleLayout(for: group, opening: store.bubbleOpening(groupID: group.id))
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThickMaterial)
                .shadow(radius: 10, y: 3)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.12)))
            header
                .frame(width: layout.contentWidth, height: BubbleLayout.headerHeight)
                .offset(x: layout.padding, y: layout.padding)
            // アイコンの並び。上限を超えたらスクロール（見える範囲で切り取る）。
            let scroll = layout.clampScroll(drop.bubbleScroll)
            ZStack(alignment: .topLeading) {
                ForEach(Array(group.apps.enumerated()), id: \.element.id) { index, ref in
                    if index < layout.tiles.count {
                        AppTile(store: store, ref: ref, size: size) {
                            guard !ref.isPinned else { return }
                            group.apps.removeAll { $0.id == ref.id }
                        }
                        .frame(width: layout.tiles[index].width, height: layout.tiles[index].height)
                        .offset(x: layout.tiles[index].minX,
                                y: layout.tiles[index].minY - layout.gridTop + layout.badgeInset - scroll)
                        .transition(Motion.insert)
                    }
                }
                Button { store.addAppsTo(group.id) } label: {
                    Image(systemName: "plus")
                        .font(.system(size: Typo.symbol))
                        .frame(width: StripLayout.imageSide(size), height: StripLayout.imageSide(size))
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.07)))
                }
                .buttonStyle(.plain)
                .help("アプリを追加")
                .frame(width: layout.plus.width, height: layout.plus.height, alignment: .top)
                .offset(x: layout.plus.minX, y: layout.plus.minY - layout.gridTop + layout.badgeInset - scroll)
            }
            // 切り取る範囲は、バッジのはみ出し分だけ上から始める（最上段の未読バッジが見切れない）。
            .frame(width: layout.size.width, height: layout.viewportHeight + layout.badgeInset, alignment: .topLeading)
            .clipped()
            .offset(y: layout.gridTop - layout.badgeInset)
            if layout.maxScroll > 0 {
                // スクロールできることが分かるよう、右端に位置の目印を出す。
                let track = layout.viewportHeight
                let knob = max(16, track * track / (track + layout.maxScroll))
                Capsule()
                    .fill(Color.primary.opacity(0.25))
                    .frame(width: 3, height: knob)
                    .offset(
                        x: layout.size.width - max(4, layout.padding / 2) - 3,
                        y: layout.gridTop + (track - knob) * scroll / layout.maxScroll)
            }
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
        .animation(Motion.spring, value: layout)
    }

    private var header: some View {
        HStack(spacing: 8) {
            EditableGroupName(name: $group.name, font: .headline)
            Spacer()
            Button { Launcher.openAll(group.apps, group: group.name) } label: { Image(systemName: "play.fill") }
                .help("すべて起動")
            Button { Launcher.quitAll(group.apps, group: group.name) } label: { Image(systemName: "stop.fill") }
                .help("すべて終了")
            Button { DispatchQueue.main.async { store.expanded = nil } } label: { Image(systemName: "xmark") }
                .help("閉じる")
        }
        .buttonStyle(.plain)
        .font(.caption)
    }
}

/// 動きの定義（Apple 標準のスプリング）。
enum Motion {
    static let spring = Animation.spring(response: 0.35, dampingFraction: 0.82)
    static let insert = AnyTransition.scale(scale: 0.6).combined(with: .opacity)
}

/// グループの中の 1 アプリ。
struct AppTile: View {
    @ObservedObject var store: Store
    let ref: AppRef
    let size: CGFloat
    let onRemove: () -> Void
    @State private var hovering = false
    @State private var picking = false

    /// 複数のインスタンス（プロセスかウィンドウ）が動いているか。帯のタイルと同じ判定。
    private var multiple: Bool { store.hasMultipleInstances(ref.path) }

    var body: some View {
        VStack(spacing: 3) {
            Image(nsImage: ref.icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: StripLayout.imageSide(size), height: StripLayout.imageSide(size))
                .overlay(alignment: .top) {
                    if let badge = store.badges[ref.path] {
                        BadgeView(text: badge, size: size)
                    }
                }
            StatusDots(running: running, multiple: multiple)
            if store.prefs.showNames { TileName(text: ref.name, width: StripLayout.nameWidth(size), fontSize: 9) }
        }
        .padding(.vertical, StripLayout.defaultTilePadding)
        .padding(.horizontal, StripLayout.defaultTilePadding)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(hovering ? Color.accentColor.opacity(0.20) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // 複数のインスタンスが動いていれば、選ぶポップアップを出す（帯と同じ）。
        .onTapGesture {
            if multiple { picking = true } else { Launcher.open(ref) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .groupDockDismissPopovers)) { _ in picking = false }
        .popover(isPresented: $picking, arrowEdge: store.popoverEdge) {
            InstancePicker(store: store, ref: ref, size: size, onPick: { picking = false })
        }
        .draggable(ref.id) {
            Image(nsImage: ref.icon).resizable().frame(width: 40, height: 40)
        }
        .contextMenu {
            if multiple { Button("インスタンスを選ぶ…") { picking = true } }
            Button("Finder で開く") { Launcher.revealInFinder(ref) }
            // パスと引数は、同じアプリを別プロジェクトで使うときに見たくなる。
            Button("パス: \(ref.path)（クリックでコピー）") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(ref.path, forType: .string)
            }
            Button(ref.arguments.isEmpty
                   ? "引数: なし"
                   : "引数: \(ref.arguments)（クリックでコピー）") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(ref.arguments, forType: .string)
            }
            // `ps` の起動は重いので、描画のたびには走らせず、押したときだけ行う。
            if running {
                Button("起動中のコマンドラインを見る…") {
                    if let command = Launcher.commandLine(ref) {
                        AppDialogs.showCommandLine(ref, command: command)
                    }
                }
            }
            Button("引数を指定して起動…") {
                AppDialogs.askArguments(current: ref.arguments, title: ref.name) { args in
                    Launcher.open(AppRef(path: ref.path, arguments: args, keepWhenQuit: ref.keepWhenQuit))
                }
            }
            Button("引数を変えて複製…") {
                AppDialogs.askArguments(current: ref.arguments, title: ref.name) { args in
                    store.duplicate(ref, arguments: args)
                }
            }
            if running { Button("再起動") { Launcher.restart(ref) } }
            Divider()
            if !ref.isPinned {
                Button("グループから外す") { onRemove() }
            }
        }
    }

    private var running: Bool {
        guard let id = ref.bundleID else { return false }
        return store.runningBundleIDs.contains(id)
    }
}

/// アプリ一覧（Finder・アプリ・「Dock に残す」にしたアプリ）のタイル。
struct StripAppTile: View {
    @ObservedObject var store: Store
    let ref: AppRef
    let size: CGFloat
    /// 固定アプリ（Finder・Apps）は外せない。
    let pinned: Bool
    @State private var hovering = false
    @State private var picking = false

    private var multiple: Bool { store.hasMultipleInstances(ref.path) }

    var body: some View {
        VStack(spacing: 3) {
            Image(nsImage: ref.icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: StripLayout.imageSide(size), height: StripLayout.imageSide(size))
                .overlay(alignment: .top) {
                    if let badge = store.badges[ref.path] {
                        BadgeView(text: badge, size: size)
                    }
                }
            StatusDots(running: running, multiple: multiple)
            if store.prefs.showNames { TileName(text: ref.name, width: StripLayout.nameWidth(size), fontSize: 9) }
        }
        .padding(.vertical, StripLayout.defaultTilePadding)
        .padding(.horizontal, StripLayout.defaultTilePadding)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(hovering ? Color.accentColor.opacity(0.20) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // 複数のインスタンスが動いていれば、選ぶポップアップを出す。1 つなら今までどおり開く。
        .onTapGesture {
            if multiple { picking = true } else { Launcher.open(ref) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .groupDockDismissPopovers)) { _ in picking = false }
        .popover(isPresented: $picking, arrowEdge: store.popoverEdge) {
            InstancePicker(store: store, ref: ref, size: size, onPick: { picking = false })
        }
        .contextMenu {
            Button("開く") { Launcher.open(ref) }
            if multiple { Button("インスタンスを選ぶ…") { picking = true } }
            Button("Finder で開く") { Launcher.revealInFinder(ref) }
            Button("パスをコピー") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(ref.path, forType: .string)
            }
            Button(ref.arguments.isEmpty ? "引数: なし" : "引数: \(ref.arguments)") {
                AppDialogs.showArguments(ref)
            }
            if running { Button("再起動") { Launcher.restart(ref) } }
            Divider()
            if pinned {
                Text("（Finder とアプリは固定です）")
            } else {
                Button("バーから外す") { store.removeEverywhere(id: ref.id) }
            }
        }
        .help(ref.path)
    }

    private var running: Bool {
        guard let id = ref.bundleID else { return false }
        return store.runningBundleIDs.contains(id)
    }
}
