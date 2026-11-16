import AppKit
import Combine
import SwiftUI

/// 帯や設定を置く画面。マウスのある画面（無ければメニューバーの画面）。
enum ScreenPick {
    static func active() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        if let hit = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) { return hit }
        return NSScreen.screens.first ?? NSScreen.main
    }

    /// 枠が画面からはみ出さないように収める。
    static func clamp(_ rect: NSRect, in screen: NSScreen) -> NSRect {
        let area = screen.visibleFrame
        var result = rect
        result.size.width = min(result.width, area.width)
        result.size.height = min(result.height, area.height)
        result.origin.x = min(max(result.minX, area.minX), area.maxX - result.width)
        result.origin.y = min(max(result.minY, area.minY), area.maxY - result.height)
        return result
    }
}

/// ホバー中のタイルの上に出す名前の札（標準 Dock と同じ）。マウスは素通しする。
final class HoverLabel {
    /// 履歴・インスタンス選択のポップアップで使う札（帯の札とは別）。
    static let popup = HoverLabel()

    /// ポップアップのタイルに入った・出たときに呼ぶ。カーソルの真上に 1 行で出す（改行は空白にする）。
    static func popupHover(_ inside: Bool, text: String) {
        if inside {
            let mouse = NSEvent.mouseLocation
            popup.show(text.replacingOccurrences(of: "\n", with: "　"),
                       above: NSRect(x: mouse.x, y: mouse.y + 12, width: 0, height: 0), position: "bottom")
        } else {
            popup.hide()
        }
    }

    private let panel: NSPanel
    private let field = NSTextField(labelWithString: "")
    private var current: String?

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let box = NSVisualEffectView()
        box.material = .toolTip
        box.state = .active
        box.wantsLayer = true
        box.layer?.cornerRadius = 6
        field.font = .systemFont(ofSize: 12, weight: .medium)
        // 名前は 1 行で、途切れさせない（中略も改行もしない）。
        field.lineBreakMode = .byClipping
        field.maximumNumberOfLines = 1
        box.addSubview(field)
        panel.contentView = box
    }

    /// `tile` は画面座標の枠。帯の位置に合わせて上（下置き）か横（左右置き）に出す。
    func show(_ text: String, above tile: NSRect, position: String) {
        if current != text {
            current = text
            field.stringValue = text
        }
        let screen = NSScreen.screens.first { $0.frame.intersects(tile) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 4000, height: 4000)
        // 名前の長さどおりの 1 行。改行しない。
        let natural = field.intrinsicContentSize
        let width = ceil(natural.width) + 16
        let height = ceil(natural.height) + 8
        field.frame = NSRect(x: 8, y: 4, width: ceil(natural.width), height: ceil(natural.height))
        let frame = HoverPlacement.frame(
            size: NSSize(width: width, height: height), tile: tile, position: position, screen: area)
        panel.setFrame(frame, display: true)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    var isVisible: Bool { panel.isVisible }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        current = nil
    }
}

/// 枠なしでもクリックで key になれるパネル。
final class DockPanel: NSPanel {
    /// 右クリックされた位置（ウィンドウ座標）からメニューを作る。
    var rightClickMenu: ((NSPoint) -> NSMenu?)?
    /// その位置が自前のメニューの対象か（軽い判定。対象でなければ SwiftUI のメニューに任せる）。
    var rightClickTarget: ((NSPoint) -> Bool)?
    private var pendingRightClick: NSPoint?
    /// ホイール（true を返したら処理済み）。
    var scrollHandler: ((NSEvent) -> Bool)?
    /// 左ボタンのドラッグ＆ドロップ（true を返すと SwiftUI へ渡さない）。
    var leftMouseHandler: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// 押されたらアプリを前面にしてキーにする。
    /// これをしないと SwiftUI のボタンや右クリックメニューが反応しない。
    /// `hidesOnDeactivate = false` にしてあるので、前面化しても帯は消えない。
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            if !NSApp.isActive {
                NSApp.activate(ignoringOtherApps: true)
            }
            makeKey()
        }
        if event.type == .scrollWheel, let handler = scrollHandler, handler(event) { return }
        // アイコンのドラッグ＆ドロップは、SwiftUI に頼らずここで処理する。
        if event.type == .leftMouseDown || event.type == .leftMouseDragged || event.type == .leftMouseUp,
           let handler = leftMouseHandler, handler(event) {
            return
        }
        // 右クリックは SwiftUI のメニューに頼らず、ここで確実に出す。
        // メニューを作るのに時間が掛かる（アプリ定義のメニューを読む）ので、押したときではなく離したときに出す。
        // 押したときに出すと、待つ間に離した操作で「押して離した＝選ばずに閉じる」になり、すぐ消える。
        if event.type == .rightMouseDown, let view = contentView {
            let point = view.convert(event.locationInWindow, from: nil)
            if rightClickTarget?(point) == true {
                pendingRightClick = point
                return
            }
        }
        if event.type == .rightMouseUp, let point = pendingRightClick, let view = contentView {
            pendingRightClick = nil
            if let menu = rightClickMenu?(point) {
                MenuPresenter.popUp(menu, at: point, in: view)
            }
            return
        }
        super.sendEvent(event)
    }
}

/// 上端のつまみ。ここだけでアイコンの大きさを変える。
final class GrabHandleView: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onDragEnd: (() -> Void)?
    /// 帯の位置（bottom / left / right）。つまみの形・カーソル・引く向きが変わる。
    var position = "bottom" {
        didSet {
            guard oldValue != position else { return }
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    private var start: NSPoint?
    private var cursor: NSCursor { GrabHandle.isHorizontalDrag(position: position) ? .resizeLeftRight : .resizeUpDown }
    private var hovering = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    override var isOpaque: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        cursor.push()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        NSCursor.pop()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let rect: NSRect
        let radius: CGFloat
        switch position {
        case "left", "right":
            // 縦長のつまみ。内側の縁に沿わせる。
            let width: CGFloat = hovering ? bounds.width - 2 : 4
            let height: CGFloat = hovering ? bounds.height : 64
            let x = position == "left" ? bounds.maxX - width - 2 : bounds.minX + 2
            rect = NSRect(x: x, y: bounds.midY - height / 2, width: width, height: height)
            radius = width / 2
        default:
            let height: CGFloat = hovering ? bounds.height - 2 : 4
            let width: CGFloat = hovering ? bounds.width : 64
            rect = NSRect(x: bounds.midX - width / 2, y: bounds.maxY - height - 2, width: width, height: height)
            radius = height / 2
        }
        let color = hovering
            ? NSColor.controlAccentColor.withAlphaComponent(0.55)
            : NSColor.secondaryLabelColor.withAlphaComponent(0.35)
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }

    override func mouseDown(with event: NSEvent) {
        start = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let now = NSEvent.mouseLocation
        onDrag?(GrabHandle.growth(dx: now.x - start.x, dy: now.y - start.y, position: position))
    }

    override func mouseUp(with event: NSEvent) {
        start = nil
        onDragEnd?()
    }
}

/// 帯の中身（SwiftUI）と、その上に載せるつまみ。
final class DockContainerView: NSView {
    let handle = GrabHandleView()
    let hosting: NSView

    init(hosting: NSView) {
        self.hosting = hosting
        super.init(frame: .zero)
        addSubview(hosting)
        addSubview(handle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        hosting.frame = bounds
        handle.frame = GrabHandle.frame(in: bounds, position: handle.position)
    }
}

/// グループの中身を出す吹き出し。
final class GroupBubbleController {
    private let store: Store
    private let panel: DockPanel
    private var cancellables = Set<AnyCancellable>()

    init(store: Store) {
        self.store = store
        panel = DockPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        // 全画面アプリの画面にも出す。
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    }

    /// 吹き出しの大きさ（件数とアイコンの大きさから計算する。描画結果は読まない）。
    static func size(for store: Store, groupID: UUID) -> NSSize {
        guard let group = store.groups.first(where: { $0.id == groupID }) else { return .zero }
        // ドラッグ中は 1 つ分の空きを確保して、大きさを固定する（行が増えても途中で飛ばない）。
        let size = store.bubbleLayout(for: group, opening: store.bubbleOpening(groupID: groupID)).size
        return NSSize(width: size.width, height: size.height)
    }

    /// 吹き出しを置く画面（帯と同じ画面）。
    private func targetScreenForBubble() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        if let hit = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) { return hit }
        return NSScreen.main ?? NSScreen.screens.first
    }

    var isShown: Bool { panel.isVisible }
    /// 吹き出しの窓（ドラッグの絵を写すのに使う）。
    var window: NSWindow { panel }
    /// 吹き出しの枠（カーソルが上にあるかの判定に使う）。
    var frame: NSRect { panel.frame }
    /// 吹き出し内のドラッグも同じ処理に流す。
    var leftMouseHandler: ((NSEvent) -> Bool)? {
        get { panel.leftMouseHandler }
        set { panel.leftMouseHandler = newValue }
    }
    /// 吹き出しの中の右クリックも、帯と同じメニューにする。
    var rightClickMenu: ((NSPoint) -> NSMenu?)? {
        get { panel.rightClickMenu }
        set { panel.rightClickMenu = newValue }
    }
    var rightClickTarget: ((NSPoint) -> Bool)? {
        get { panel.rightClickTarget }
        set { panel.rightClickTarget = newValue }
    }
    var scrollHandler: ((NSEvent) -> Bool)? {
        get { panel.scrollHandler }
        set { panel.scrollHandler = newValue }
    }

    func show(groupID: UUID, anchor: NSRect, vertical: Bool, tile: NSRect? = nil) {
        guard let index = store.groups.firstIndex(where: { $0.id == groupID }) else { return }
        let root = GroupBubbleView(
            store: store,
            group: Binding(
                get: { self.store.groups.first(where: { $0.id == groupID }) ?? Group(name: "") },
                set: { self.store.groups[index] = $0 }
            ),
            size: store.effectiveIconSize,
            drop: store.dropState
        )
        // 中身は作り直さず、差し替えだけにする（毎回作ると重いうえ、
        // fittingSize の同期レイアウトで固まることがあった）。
        detaching = false
        if let hosting = panel.contentView as? NSHostingView<GroupBubbleView> {
            hosting.rootView = root
        } else {
            let hosting = NSHostingView(rootView: root)
            hosting.sizingOptions = []
            panel.contentView = hosting
            panel.acceptsMouseMovedEvents = true
        }

        // 大きさは中身の数から決める（fittingSize は使わない）。
        let size = Self.size(for: store, groupID: groupID)
        let width = size.width
        let height = size.height

        // 帯の外側に出す（下なら上、左右なら内側）。位置の計算は BubblePlacement に任せる。
        let origin = BubblePlacement.origin(
            anchor: anchor,
            size: NSSize(width: width, height: height),
            position: store.prefs.position,
            tile: tile
        )
        let frame = NSRect(origin: origin, size: NSSize(width: width, height: height))
        let screen = targetScreenForBubble() ?? NSScreen.main
        let target = screen.map { ScreenPick.clamp(frame, in: $0) } ?? frame
        if panel.isVisible, panel.frame.size != target.size {
            // 開いたまま件数・余白が変わったら、大きさを滑らかに合わせる（中身は SwiftUI 側で補間）。
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
                context.allowsImplicitAnimation = true
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    private var detaching = false

    func hide() {
        panel.orderOut(nil)
    }

    /// 帯との結び付き（子ウィンドウにすると表示されなくなるので、関係だけ持つ）。
    /// 帯が隠れるときは呼び出し側が detach() で閉じる。
    func attach(to parent: NSWindow) {
        _ = parent
    }

    /// 吹き出しを閉じる。SwiftUI の更新中に呼ばれることがあるので、
    /// 実際の後片付けは次のループで 1 回だけ行う（同期で消すと固まる／落ちる）。
    func detach() {
        guard !detaching else { return }
        detaching = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // 先に SwiftUI のグラフを外す（閉じたあとに状態を publish させない）。
            self.panel.contentView = nil
            self.panel.orderOut(nil)
            self.detaching = false
        }
    }
}

/// 画面端に浮かぶ帯。設定で下・左・右に置け、グループは吹き出しで開く。
/// メニュー項目が実行する処理を包む。
final class MenuAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
}

final class DockWindowController: NSObject {
    // メニューの組み立て（DockMenus.swift）から使うものは、private を付けない。
    let store: Store
    /// この帯を出す画面（nil ならメイン画面）。
    private let screen: NSScreen?
    let panel: DockPanel
    let container: DockContainerView
    let bubble: GroupBubbleController
    private var cancellables = Set<AnyCancellable>()
    private var mouseTimer: Timer?
    private let hoverLabel = HoverLabel()
    /// マウスの動きを拾う仕掛け（名前の札をタイマーを待たずに更新する）。
    private var moveMonitors: [Any] = []
    let openGallery: () -> Void
    /// ゲージのホイール調整：量の溜まり（ウィジェットごと）、書き込み中のウィジェット、読み書きを順に行う直列キュー。
    private var gaugeAdjusters: [UUID: GaugeAdjuster] = [:]
    private var gaugeWriting: Set<UUID> = []
    private let gaugeQueue = DispatchQueue(label: "GroupDock.gauge", qos: .userInitiated)
    private var autoHidden = false {
        // 隠れている間は、見えないウィジェットと再生の更新を止める。
        didSet { store.stripHidden = autoHidden }
    }
    private var sizeAtDragStart: Double?
    /// 最後に反映した時刻（イベントの間引きに使う）。
    private var lastResizeApply = Date.distantPast
    /// アイコンのドラッグ状態（掴んでいるタイルの id と開始位置・ドラッグ中の絵）。
    var drag: (id: String, start: NSPoint, image: NSWindow?)?
    /// ドラッグ中の当たり判定用の矩形（押した時に 1 回だけ作り、イベントごとには作り直さない）。
    var dragRects: [String: NSRect] = [:]
    /// ゲージ上のスライド（ドラッグ）の状態。並べ替えのドラッグ（`drag`）とは別。
    var gaugeSlide: GaugeSlide?
    var gaugeSlideID: UUID?
    var gaugeSlideStart: CGPoint = .zero
    /// 3 点以上動いて、スライドになったか（動かなければクリック）。
    var gaugeSliding = false

    private static let peek: CGFloat = 6

    init(
        store: Store,
        screen: NSScreen? = nil,
        openSettings: @escaping () -> Void,
        openPicker: @escaping () -> Void,
        openWidgetSettings: @escaping (UUID) -> Void,
        openGallery: @escaping () -> Void = {}
    ) {
        self.openGallery = openGallery
        self.store = store
        self.screen = screen
        bubble = GroupBubbleController(store: store)

        panel = DockPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 106),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovable = false
        // 全画面アプリの画面にも出す。
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let root = DockView(
            store: store,
            openSettings: openSettings,
            openPicker: openPicker,
            openWidgetSettings: openWidgetSettings
        )
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        container = DockContainerView(hosting: hosting)
        panel.contentView = container
        super.init()

        container.handle.onDrag = { [weak self] translation in
            self?.applyResize(translation)
        }
        container.handle.onDragEnd = { [weak self] in
            self?.finishResize()
        }

        store.$prefs
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] prefs in
                guard let self else { return }
                if !prefs.autoHide { autoHidden = false }
                // つまみは帯の向きに合わせて内側の縁に出す（左右でも大きさを変えられる）。
                container.handle.position = prefs.position
                container.needsLayout = true
                layout(animated: sizeAtDragStart == nil)
                // 開いたまま位置や大きさが変わったら、吹き出しも付け直す。
                if let id = store.expanded, !autoHidden {
                    bubble.show(
                        groupID: id,
                        anchor: targetFrame(autoHidden: false) ?? panel.frame,
                        vertical: prefs.position != "bottom",
                        tile: groupTileFrame(id)
                    )
                }
            }
            .store(in: &cancellables)
        // 状態が変わったら、帯と吹き出しの大きさを計算し直す（枠は状態から計算するだけ）。
        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.relayout() }
            .store(in: &cancellables)
        // グループを開いたら吹き出しを出す。閉じたら消す。
        store.$expanded
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] id in
                guard let self else { return }
                // ここは SwiftUI の更新中に呼ばれることがある。次のループで処理する。
                DispatchQueue.main.async {
                    self.store.dropState.bubbleScroll = 0   // 開き直したら先頭から
                    let onThisScreen = self.targetScreen
                        .map { $0.frame.contains(NSEvent.mouseLocation) } ?? true
                    guard let id, !self.autoHidden, onThisScreen else {
                        self.bubble.detach()
                        return
                    }
                    self.bubble.attach(to: self.panel)
                    self.bubble.show(
                        groupID: id,
                        anchor: self.targetFrame(autoHidden: false) ?? self.panel.frame,
                        vertical: self.store.prefs.position != "bottom",
                        tile: self.groupTileFrame(id)
                    )
                }
            }
            .store(in: &cancellables)

        panel.rightClickMenu = { [weak self] point in self?.buildMenu(at: point) }
        panel.rightClickTarget = { [weak self] _ in self?.rightClickKind() != nil }
        panel.leftMouseHandler = { [weak self] event in self?.handleLeftMouse(event) ?? false }
        bubble.leftMouseHandler = { [weak self] event in self?.handleLeftMouse(event) ?? false }
        bubble.rightClickMenu = { [weak self] point in self?.buildMenu(at: point) }
        bubble.rightClickTarget = { [weak self] _ in self?.appUnderMouse() != nil }
        bubble.scrollHandler = { [weak self] event in self?.scrollBubble(event) ?? false }
        panel.scrollHandler = { [weak self] event in self?.scrollGauge(event) ?? false }

        layout()
        panel.orderFrontRegardless()



        restartMouseTimer(interval: 0.2)

        // 名前の札は、マウスが動いた瞬間に更新する（タイマーの 0.2〜0.5 秒を待たない）。
        // 帯と吹き出しの近くにいるときだけ処理するので、離れている間はほぼ何もしない。
        let onMove: () -> Void = { [weak self] in
            guard let self else { return }
            let mouse = NSEvent.mouseLocation
            let near = self.panel.frame.insetBy(dx: -8, dy: -8).contains(mouse)
                || (self.bubble.isShown && self.bubble.frame.insetBy(dx: -8, dy: -8).contains(mouse))
            if near || self.hoverLabelVisible { self.updateHoverLabel() }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { _ in onMove() }) {
            moveMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { event in onMove(); return event }) {
            moveMonitors.append(local)
        }
        panel.acceptsMouseMovedEvents = true

        // 帯の別の要素（ウィジェット・ボタン・仕切り線・空き）を押したら、開いているグループを閉じる。
        // 帯の中のクリックはこのアプリのイベントなので、下の全体の監視では届かない。
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            self?.closeGroupIfClickedElsewhere()
            return event
        }) {
            moveMonitors.append(local)
        }

        // 吹き出しの外をクリックしたら閉じる（中を操作している間は閉じない）。
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, store.expanded != nil else { return }
            let point = NSEvent.mouseLocation
            if panel.frame.contains(point) { return }
            if bubble.isShown, bubble.frame.contains(point) { return }
            DispatchQueue.main.async {
                self.bubble.detach()
                self.store.expanded = nil
            }
        }
    }

    /// 押した所が、開いているグループとは別の要素なら、グループを閉じる（吹き出しの中は閉じない）。
    private func closeGroupIfClickedElsewhere() {
        guard let expanded = store.expanded else { return }
        let point = NSEvent.mouseLocation
        if bubble.isShown, bubble.frame.contains(point) { return }
        guard panel.frame.contains(point) else { return }
        guard GroupDismissal.closesOnMouseDown(target: tileID(atScreenPoint: point), expanded: expanded) else { return }
        closeExpandedGroup()
    }

    func closeExpandedGroup() {
        DispatchQueue.main.async { [weak self] in
            self?.bubble.detach()
            self?.store.expanded = nil
        }
    }

    /// つまみを掴んだ直後：元の大きさを覚える（大きさは状態から即座に計算されるので見積りは要らない）。
    private func beginResizeIfNeeded() {
        guard sizeAtDragStart == nil else { return }
        sizeAtDragStart = store.prefs.iconSize
    }

    /// ドラッグ中：大きさを更新する（イベントは 120fps までに間引く）。
    private func applyResize(_ translation: CGFloat) {
        beginResizeIfNeeded()
        let now = Date()
        guard now.timeIntervalSince(lastResizeApply) > 0.008 else { return }
        lastResizeApply = now
        guard let start = sizeAtDragStart else { return }
        let next = min(88, max(36, start + Double(translation)))
        guard abs(next - store.prefs.iconSize) >= 0.5 else { return }
        store.prefs.iconSize = next
    }

    /// 掴み終わり：実測の値に落ち着かせる。
    private func finishResize() {
        sizeAtDragStart = nil
        layout()
    }

    var isVisible: Bool { panel.isVisible }

    /// 帯を片付ける（「全ディスプレイ」を切ったときなど）。
    func close() {
        bubble.detach()
        panel.orderOut(nil)
        mouseTimer?.invalidate()
        mouseTimer = nil
        moveMonitors.forEach(NSEvent.removeMonitor)
        moveMonitors.removeAll()
        hoverLabel.hide()
        cancellables.removeAll()
    }

    /// グループのタイルの画面上の枠（帯が表示位置にあるときの枠で計算する）。
    private func groupTileFrame(_ id: UUID) -> NSRect? {
        guard let window = targetFrame(autoHidden: false) else { return nil }
        let strip = store.stripLayout()
        guard let rect = strip.frames["group:\(id.uuidString)"] else { return nil }
        return TileHitTest.screenRect(rect, windowFrame: window, containerHeight: strip.size.height)
    }

    /// ゲージ（音量・マイク・明るさのウィジェット）の上のホイール：詳細を開かずに値を調整する。
    /// 対象の上でなければ false を返し、他の処理に任せる。
    /// 量はウィジェットごとに主スレッドで足し合わせ、読み書きは直列キュー 1 本で行う（並行すると、取りこぼしや順序の逆転が起きる）。
    private func scrollGauge(_ event: NSEvent) -> Bool {
        let mouse = NSEvent.mouseLocation
        guard let id = tileID(atScreenPoint: mouse), id.hasPrefix("widget:"),
              let uuid = UUID(uuidString: String(id.dropFirst(7))),
              let widget = store.prefs.widgets.first(where: { $0.id == uuid }),
              GaugeWheel.adjustable(widget.kind) else { return false }
        gaugeAdjusters[uuid, default: GaugeAdjuster()].add(
            deltaY: Double(event.scrollingDeltaY), precise: event.hasPreciseScrollingDeltas)
        guard !gaugeWriting.contains(uuid) else { return true }   // 書き込み中なら、終わったあとに溜まりを続けて使う
        flushGauge(widget)
        return true
    }

    /// 溜まった量を、直列キューで 1 回ずつ書く。書き終えたとき溜まりが有れば、続けて書く（量を落とさない）。
    private func flushGauge(_ widget: Widget, maxChange: Int = GaugeWheel.maxStep) {
        let id = widget.id
        gaugeWriting.insert(id)
        let pending = gaugeAdjusters[id] ?? GaugeAdjuster()
        gaugeAdjusters[id] = GaugeAdjuster()
        gaugeQueue.async { [weak self] in
            var adjuster = pending
            let current: Int? = widget.kind == .brightness
                ? DisplayReader.snapshot(for: widget).brightness
                : AudioReader.snapshot(for: widget).volume
            if let current, let next = adjuster.take(current: current, maxChange: maxChange) {
                if widget.kind == .brightness {
                    DisplayReader.setBrightness(next, for: widget)
                } else {
                    AudioReader.setVolume(next, for: widget)
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.gaugeWriting.remove(id)
                self.store.refreshWidgetsNow()
                if self.gaugeAdjusters[id]?.hasPending == true { self.flushGauge(widget, maxChange: maxChange) }
            }
        }
    }

    /// ゲージ上のスライド（ドラッグ）：動いた割合（%）を溜めて、直列キューで書く。ホイールと同じ経路。
    func slideGauge(_ id: UUID, percent: Double) {
        guard let widget = store.prefs.widgets.first(where: { $0.id == id }), GaugeWheel.adjustable(widget.kind) else { return }
        gaugeAdjusters[id, default: GaugeAdjuster()].addPercent(percent)
        guard !gaugeWriting.contains(id) else { return }
        flushGauge(widget, maxChange: 100)
    }

    /// 吹き出しのホイール：上限を超えるときだけスクロールする。
    private func scrollBubble(_ event: NSEvent) -> Bool {
        guard let layout = currentBubbleLayout(), layout.maxScroll > 0 else { return false }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
        let next = layout.clampScroll(store.dropState.bubbleScroll - delta)
        if next != store.dropState.bubbleScroll { store.dropState.bubbleScroll = next }
        return true
    }

    /// 開いているグループの枠（状態から計算）。
    private func currentBubbleLayout() -> BubbleLayout? {
        guard let id = store.expanded, let group = store.groups.first(where: { $0.id == id }) else { return nil }
        return store.bubbleLayout(for: group)
    }

    /// 帯と吹き出しのタイルの枠を、画面座標でまとめる。状態から計算した枠だけを使う。
    func screenRects() -> [String: NSRect] {
        var result: [String: NSRect] = [:]
        let strip = store.stripLayout()
        for (id, rect) in strip.frames {
            result[id] = TileHitTest.screenRect(rect, windowFrame: panel.frame, containerHeight: strip.size.height)
        }
        if bubble.isShown, let id = store.expanded,
           let group = store.groups.first(where: { $0.id == id }) {
            let layout = store.bubbleLayout(for: group)
            // スクロールした分だけずらし、見えていないタイルは当てない。
            let scroll = layout.clampScroll(store.dropState.bubbleScroll)
            for (index, ref) in group.apps.enumerated() where index < layout.tiles.count {
                let tile = layout.tiles[index]
                guard layout.isVisible(tile, scroll: scroll) else { continue }
                result["app:\(ref.id)"] = TileHitTest.screenRect(
                    tile.offsetBy(dx: 0, dy: -scroll), windowFrame: bubble.frame, containerHeight: layout.size.height)
            }
        }
        return result
    }

    /// 画面座標の点にあるタイル。
    func tileID(atScreenPoint point: NSPoint) -> String? {
        TileHitTest.id(atScreenPoint: point, rects: screenRects())
    }


    /// 右クリック位置にあるアプリのメニュー。帯と吹き出しのどちらでも、同じ計算済みの枠で当てる。
    /// （メニューの組み立ては `DockMenus.swift`）

    /// メニューなどからグループの吹き出しを開く。
    func openGroup(_ id: UUID) {
        if !panel.isVisible {
            layout()
            panel.orderFrontRegardless()
        }
        autoHidden = false
        layout(animated: true)
        store.expanded = id
    }

    /// 開いているグループを閉じる（メニュー・外側クリック・× の共通経路）。
    func closeGroup() {
        bubble.detach()
        store.expanded = nil
    }

    func toggle() {
        if panel.isVisible {
            panel.orderOut(nil)
            bubble.detach()
            store.expanded = nil
            autoHidden = false
        } else {
            layout()
            panel.orderFrontRegardless()
        }
    }

    /// この帯を置く画面。
    private var targetScreen: NSScreen? {
        screen ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// 帯の枠。SwiftUI の実寸をそのまま使う。
    private func targetFrame(autoHidden hidden: Bool) -> NSRect? {
        // 帯は決められた画面に固定する（マウス移動で別画面へ飛ばないように）。
        guard let screen = targetScreen else { return nil }
        let visible = screen.visibleFrame
        // 帯の大きさは状態から計算する（SwiftUI の実測は読まない）。
        let content = store.stripWindowSize()
        let width = min(content.width, visible.width - 8)
        let height = content.height

        let frame: NSRect
        switch store.prefs.position {
        case "left":
            frame = NSRect(x: visible.minX + 8, y: visible.midY - height / 2, width: width, height: height)
        case "right":
            frame = NSRect(x: visible.maxX - width - 8, y: visible.midY - height / 2, width: width, height: height)
        default:
            frame = NSRect(x: visible.midX - width / 2, y: visible.minY + 8, width: width, height: height)
        }
        // 隠れているときは端に寄せる。隠れる先に別のディスプレイがあれば、そちらへはみ出さず、端の細い帯だけにする。
        guard hidden else { return ScreenPick.clamp(frame, in: screen) }
        let others = NSScreen.screens.filter { $0 != screen }.map(\.frame)
        return HiddenPlacement.frame(
            shown: frame, position: store.prefs.position, visible: visible, screen: screen.frame, others: others, peek: Self.peek)
    }

    /// カーソルが帯・吹き出し・端の帯（隠れているときの掴み代）の上にあるか。
    private func overStrip(_ mouse: NSPoint) -> Bool {
        if panel.frame.contains(mouse) { return true }
        if bubble.isShown, bubble.frame.contains(mouse) { return true }
        // 帯が表示位置へ動いた直後は、下端ぴったりのカーソルが枠外になるので端も含める。
        guard let screen = targetScreen else { return false }
        let area = screen.visibleFrame
        let band: NSRect
        switch store.prefs.position {
        case "left":
            band = NSRect(x: area.minX, y: area.minY, width: Self.peek + 2, height: area.height)
        case "right":
            band = NSRect(x: area.maxX - Self.peek - 2, y: area.minY, width: Self.peek + 2, height: area.height)
        default:
            band = NSRect(x: area.minX, y: area.minY, width: area.width, height: Self.peek + 2)
        }
        return band.contains(mouse)
    }

    /// 状態が変わったときの再計算。帯の枠と、開いている吹き出しの大きさを合わせる。
    private func relayout() {
        layout()
        guard let id = store.expanded, bubble.isShown, !autoHidden else { return }
        let size = GroupBubbleController.size(for: store, groupID: id)
        guard abs(bubble.frame.width - size.width) > 0.5 || abs(bubble.frame.height - size.height) > 0.5 else { return }
        bubble.show(
            groupID: id,
            anchor: targetFrame(autoHidden: false) ?? panel.frame,
            vertical: store.prefs.position != "bottom",
            tile: groupTileFrame(id)
        )
    }

    private var isLayingOut = false
    private var layoutPending = false

    private func layout(animated: Bool = false) {
        // レイアウト中に再度呼ばれたら、いまの処理が終わってから 1 回だけ流す。
        guard !isLayingOut else {
            layoutPending = true
            return
        }
        isLayingOut = true
        defer {
            isLayingOut = false
            if layoutPending {
                layoutPending = false
                DispatchQueue.main.async { [weak self] in self?.layout() }
            }
        }
        guard let frame = targetFrame(autoHidden: autoHidden) else { return }
        // 同じ枠を何度も設定するとカクつくので、変わったときだけ動かす。
        let current = panel.frame
        let changed = abs(current.width - frame.width) > 0.5
            || abs(current.height - frame.height) > 0.5
            || abs(current.origin.x - frame.origin.x) > 0.5
            || abs(current.origin.y - frame.origin.y) > 0.5
        guard changed else { return }
        if animated {
            // 隠れる・出るときは実際に補間する（animator を使う）。
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.4
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
                context.allowsImplicitAnimation = true
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true, animate: false)
        }
        container.needsLayout = true
    }

    /// 帯と吹き出し以外の自分の画面（設定・ダイアログ・ポップアップ・メニュー）が出ているか。
    private var otherUIVisible: Bool {
        if NSApp.modalWindow != nil { return true }
        return NSApp.windows.contains { window in
            guard window.isVisible, window !== panel else { return false }
            if window.styleMask.contains(.titled) { return true }
            let name = String(describing: type(of: window))
            return name.contains("Popover") || name.contains("PopupMenu")
        }
    }

    /// カーソルの下のタイルの名前を札で出す。ドラッグ中・隠れている間・メニュー表示中は出さない。
    private var hoverLabelVisible: Bool { hoverLabel.isVisible }

    private func updateHoverLabel() {
        let mouse = NSEvent.mouseLocation
        guard panel.isVisible, !autoHidden, drag?.image == nil, NSEvent.pressedMouseButtons == 0,
              NSApp.modalWindow == nil,
              panel.frame.contains(mouse) || (bubble.isShown && bubble.frame.contains(mouse)) else {
            hoverLabel.hide()
            return
        }
        let rects = screenRects()
        guard let id = TileHitTest.id(atScreenPoint: mouse, rects: rects), let rect = rects[id],
              let name = store.hoverName(for: id) else {
            hoverLabel.hide()
            return
        }
        // 吹き出しの中は上に出す（帯の向きに関係なく）。
        let inBubble = bubble.isShown && bubble.frame.contains(mouse)
        hoverLabel.show(name, above: rect, position: inBubble ? "bottom" : store.prefs.position)
    }

    /// マウスが離れたら端へ引っ込め、端に寄ったら出す。隠すときは吹き出しも閉じる。
    /// ホバー・自動で隠す判定のタイマーを張り直す（間隔が変わるときだけ）。
    private func restartMouseTimer(interval: TimeInterval) {
        if let current = mouseTimer, abs(current.timeInterval - interval) < 0.001 { return }
        mouseTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.updateAutoHide()
            self.updateHoverLabel()
            // 帯から離れていて、自動で隠さない設定なら、判定を 0.5 秒に落とす。
            let mouse = NSEvent.mouseLocation
            let near = self.panel.frame.insetBy(dx: -40, dy: -40).contains(mouse)
                || (self.bubble.isShown && self.bubble.frame.insetBy(dx: -40, dy: -40).contains(mouse))
            self.restartMouseTimer(interval: PollPolicy.hoverInterval(autoHide: self.store.prefs.autoHide, mouseNear: near))
        }
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer
    }

    private func updateAutoHide() {
        // 帯が消えている・グループを閉じているのに吹き出しだけ残るのを防ぐ。
        if !panel.isVisible || store.expanded == nil || autoHidden {
            if bubble.isShown { bubble.detach() }
        }
        // グループを開いている間は、カーソルがどこにあっても隠さない・閉じない。
        // 閉じるのは「外側をクリック」「×」「もう一度タイルを押す」「メニューで非表示」のときだけ。
        if store.expanded != nil { return }

        guard store.prefs.autoHide, panel.isVisible else { return }
        guard NSEvent.pressedMouseButtons == 0 else { return }
        // 設定・ダイアログ・ウィジェットのポップアップ・メニューが出ている間は隠さない。
        if otherUIVisible { return }
        guard let screen = targetScreen,
              let shown = targetFrame(autoHidden: false) else { return }
        let visible = screen.visibleFrame
        let mouse = NSEvent.mouseLocation
        let position = store.prefs.position

        let nearEdge = EdgeReveal.nearEdge(
            mouse: mouse, position: position, visible: visible, screen: screen.frame, peek: Self.peek)

        if autoHidden {
            let alongEdge: Bool
            switch position {
            case "left", "right": alongEdge = mouse.y >= shown.minY && mouse.y <= shown.maxY
            default: alongEdge = mouse.x >= shown.minX && mouse.x <= shown.maxX
            }
            if nearEdge && alongEdge {
                autoHidden = false
                layout(animated: true)
            }
        } else if !overStrip(mouse), !nearEdge {
            autoHidden = true
            bubble.detach()
            store.expanded = nil          // 隠れるときは吹き出しも閉じる
            layout(animated: true)
        }
    }
}
