import AppKit
import SwiftUI

/// アイコンのドラッグ＆ドロップ（`DockWindowController` から分けた）。
/// SwiftUI の `.draggable` はこのパネルで効かないので、パネル側で当たり判定（`TileHitTest`）して処理する。
/// 状態（`drag`・`dragRects`）は `DockWindowController` が持つ（拡張は保持プロパティを持てないため）。
extension DockWindowController {
    /// パネル内の座標でのドラッグ処理（SwiftUI のドラッグはこのパネルでは効かないため）。
    func handleLeftMouse(_ event: NSEvent) -> Bool {
        // 画面座標で判定する（帯と吹き出しをまたいでも同じ規則になる）。
        let point = NSEvent.mouseLocation

        switch event.type {
        case .leftMouseDown:
            // サイズ変更のつまみの上は、タイルより優先する（アプリに引っ張られない）。
            if !container.handle.isHidden,
               panel.convertToScreen(container.handle.frame).contains(point) {
                drag = nil
                return false
            }
            guard let id = tileID(atScreenPoint: point),
                  id.hasPrefix("app:") || id.hasPrefix("group:") || id.hasPrefix("widget:") else {
                drag = nil
                return false
            }
            // 「残さない」区分（実行中だけのアプリ）は並べ替え・グループ化の対象にしない。
            if id.hasPrefix("app:"), !store.isInKeepZone(appID: String(id.dropFirst(4))) {
                drag = nil
                return false
            }
            // 音量・マイク・明るさのゲージは、掴む場所で分ける（修飾キーは使わない）。
            // 外周の帯と名前の所は並べ替え（D&D）、内側の面はスライド調整。
            gaugeSlide = nil
            gaugeSlideID = nil
            if id.hasPrefix("widget:"), let uuid = UUID(uuidString: String(id.dropFirst(7))),
               let widget = store.prefs.widgets.first(where: { $0.id == uuid }), GaugeWheel.adjustable(widget.kind),
               let tile = screenRects()[id] {
                let labelled = widget.showLabel && store.prefs.showNames
                if GaugeGrab.zone(at: point, tile: tile, labelled: labelled) == .slide {
                    drag = nil
                    gaugeSlide = GaugeSlide(start: point, tile: GaugeGrab.faceRect(tile: tile, labelled: labelled))
                    gaugeSlideStart = point
                    gaugeSlideID = uuid
                    return false        // クリック（詳細を開く）は、動かなければ SwiftUI に任せる
                }
            }
            // 再生中ウィジェットは、サムネの所だけで並べ替えを始める（つまみ・音量・ボタンの操作を奪わない）。
            if id.hasPrefix("widget:"), let uuid = UUID(uuidString: String(id.dropFirst(7))),
               let widget = store.prefs.widgets.first(where: { $0.id == uuid }), widget.kind == .nowPlaying,
               let tile = screenRects()[id],
               !NowPlayingGrab.allowsDrag(
                   at: point, tile: tile, layout: widget.playerLook(vertical: store.prefs.position != "bottom"),
                   icon: store.effectiveIconSize, vertical: store.prefs.position != "bottom") {
                drag = nil
                return false
            }
            drag = (id: id, start: point, image: nil)
            dragRects = screenRects()
            return false            // クリック（起動）は SwiftUI に任せる

        case .leftMouseDragged:
            // ゲージのスライド：3 点以上動いたら、動いた分を値に反映する（並べ替えは始めない）。
            if var slide = gaugeSlide, let id = gaugeSlideID {
                if !gaugeSliding {
                    guard GaugeSlide.isDrag(from: gaugeSlideStart, to: point) else { return true }
                    gaugeSliding = true
                    slide = GaugeSlide(start: gaugeSlideStart, tile: GaugeGrab.faceRect(
                        tile: screenRects()["widget:\(id.uuidString)"] ?? .zero, labelled: false))
                }
                let percent = slide.move(to: point)
                gaugeSlide = slide
                if percent != 0 { slideGauge(id, percent: percent) }
                return true
            }
            guard var state = drag else { return false }
            let distance = hypot(point.x - state.start.x, point.y - state.start.y)
            if state.image == nil, distance < 5 { return true }   // まだドラッグとは言えない
            if state.image == nil {
                state.image = makeDragImage(for: state.id)
                store.dragging = true
            }
            drag = state
            moveDragImage(to: NSEvent.mouseLocation)
            let insertion = insertionPoint(for: state.id, at: point)
            store.insertion = insertion
            // 挿入するときは重ねる（グループ化）の強調を出さない。
            store.dropTargetID = insertion != nil ? nil
                : TileHitTest.id(atScreenPoint: point, rects: dragRects).flatMap { $0 == state.id ? nil : $0 }
            return true

        case .leftMouseUp:
            // ゲージのスライドを終える。動いていれば処理済み（クリック＝詳細を開くを出さない）。動いていなければクリックに任せる。
            if gaugeSlide != nil {
                let didSlide = gaugeSliding
                gaugeSlide = nil
                gaugeSlideID = nil
                gaugeSliding = false
                return didSlide
            }
            guard let state = drag else { return false }
            state.image?.orderOut(nil)
            drag = nil
            let target = TileHitTest.id(atScreenPoint: point, rects: dragRects)
            let insertion = insertionPoint(for: state.id, at: point)
            store.insertion = nil
            store.dragging = false
            store.dropTargetID = nil
            // 動いていなければクリック扱い（SwiftUI に任せる）。
            if hypot(point.x - state.start.x, point.y - state.start.y) < 5 {
                // 帯のアプリを押して起動したときは、開いているグループを閉じる（吹き出しの中のクリックは閉じない）。
                if store.expanded != nil, GroupDismissal.closesOnClick(target: state.id),
                   !(bubble.isShown && bubble.frame.contains(point)) {
                    closeExpandedGroup()
                }
                return false
            }
            // 挿入・並べ替えは Apple 標準のスプリングで動かす（周りのアイコンが道を空ける）。
            withAnimation(Motion.spring) {
                if state.id.hasPrefix("widget:") {
                    // ウィジェットはウィジェットの並びの中だけで入れ替える。
                    if let insertion,
                       let from = UUID(uuidString: String(state.id.dropFirst(7))),
                       let to = UUID(uuidString: String(insertion.id.dropFirst(7))) {
                        store.reorderWidget(from, before: to, after: insertion.after)
                    }
                } else if let insertion {
                    store.reorder(
                        appID: String(state.id.dropFirst(4)),
                        before: String(insertion.id.dropFirst(4)), after: insertion.after)
                } else {
                    drop(state.id, onto: target, at: point)
                }
            }
            return true

        default:
            return false
        }
    }

    /// ドラッグ中にカーソルへ付いてくる絵。帯（か吹き出し）に描いているタイルをそのまま写す。
    private func makeDragImage(for id: String) -> NSWindow? {
        guard let rect = dragRects[id], let image = snapshot(screenRect: rect) else { return nil }
        let window = NSPanel(
            contentRect: NSRect(origin: .zero, size: rect.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false      // 動かすたびに影を計算し直すと重い
        window.ignoresMouseEvents = true
        // 帯・吹き出し（.floating）より前に出し、別のスペースやフルスクリーン上でも見えるようにする。
        window.level = .popUpMenu
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.85
        let imageView = NSImageView(frame: NSRect(origin: .zero, size: rect.size))
        imageView.image = image
        imageView.imageScaling = .scaleNone
        window.contentView = imageView
        window.orderFrontRegardless()
        return window
    }

    /// 画面上の枠にある自分の描画（帯か吹き出し）を写し取る。
    private func snapshot(screenRect rect: NSRect) -> NSImage? {
        let source: NSWindow = bubble.isShown && bubble.frame.contains(NSPoint(x: rect.midX, y: rect.midY))
            ? bubble.window : panel
        guard let view = source.contentView else { return nil }
        let local = view.convert(source.convertFromScreen(rect), from: nil)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: local) else { return nil }
        view.cacheDisplay(in: local, to: rep)
        let image = NSImage(size: rect.size)
        image.addRepresentation(rep)
        return image
    }

    private func moveDragImage(to mouse: NSPoint) {
        guard let window = drag?.image else { return }
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height / 2))
    }

    /// ドラッグ中のアプリを入れる位置。プレビューとドロップで同じ判定を使う（当たり判定は押した時の枠で固定）。
    private func insertionPoint(for draggedID: String, at point: NSPoint) -> DropState.Insertion? {
        // ウィジェットは、ウィジェットの前後にだけ入る（帯の上なら左右・上下で前後を決める）。
        if draggedID.hasPrefix("widget:") {
            let vertical = store.prefs.position != "bottom"
            let hit = TileHitTest.id(atScreenPoint: point, rects: dragRects)
            if let hit, hit.hasPrefix("widget:"), hit != draggedID, let rect = dragRects[hit] {
                let after = vertical ? point.y < rect.midY : point.x > rect.midX
                return DropState.Insertion(id: hit, after: after)
            }
            return TileHitTest.insertion(
                at: point, rects: dragRects, dragged: draggedID, vertical: vertical, prefix: "widget:"
            ).map { DropState.Insertion(id: $0.id, after: $0.after) }
        }
        guard draggedID.hasPrefix("app:") else { return nil }
        var found = TileHitTest.insertion(
            at: point, rects: dragRects, dragged: draggedID, vertical: store.prefs.position != "bottom")
        // 吹き出しの中は格子なので、左右で前後を決める。
        if let hit = found, let id = store.expanded,
           let group = store.groups.first(where: { $0.id == id }),
           group.apps.contains(where: { "app:\($0.id)" == hit.id }) {
            found = TileHitTest.insertion(at: point, rects: dragRects, dragged: draggedID, vertical: false)
        }
        return found.map { DropState.Insertion(id: $0.id, after: $0.after) }
    }

    /// ドロップしたときの処理（iPhone と同じ：重ねればフォルダ・グループへは入れ子・並べ替え）。
    private func drop(_ draggedID: String, onto targetID: String?, at point: NSPoint) {
        guard let targetID else {
            if draggedID.hasPrefix("app:") {
                let source = String(draggedID.dropFirst(4))
                // 何もない所へ落としたら「残す」並びの末尾へ。
                store.moveToEnd(appID: source)
            }
            return
        }
        if draggedID.hasPrefix("app:"), targetID.hasPrefix("app:") {
            let source = String(draggedID.dropFirst(4))
            let target = String(targetID.dropFirst(4))
            // 別々の場所なら新しいグループを作る（アイコンを重ねてフォルダ）。
            let sourceGroup = store.groupID(ofApp: source)
            let targetGroup = store.groupID(ofApp: target)
            if sourceGroup != nil, sourceGroup == targetGroup {
                store.reorder(appID: source, before: target)      // 同じグループ内は並べ替え
            } else if sourceGroup != nil, targetGroup == nil {
                store.reorder(appID: source, before: target)      // グループから出して並べ替え
            } else if let groupID = store.createGroup(from: source, with: target) {
                store.expanded = groupID                           // できたフォルダを開いて見せる
            }
            return
        }
        if draggedID.hasPrefix("app:"), targetID.hasPrefix("group:") {
            guard let uuid = UUID(uuidString: String(targetID.dropFirst(6))) else { return }
            store.move(appID: String(draggedID.dropFirst(4)), intoGroup: uuid)
            return
        }
        if draggedID.hasPrefix("group:"), targetID.hasPrefix("group:") {
            guard let from = UUID(uuidString: String(draggedID.dropFirst(6))),
                  let to = UUID(uuidString: String(targetID.dropFirst(6))) else { return }
            store.merge(groupID: from, into: to)
        }
    }
}
