import AppKit

/// 右クリックメニューを出す。
/// アプリ定義のメニューを標準 Dock から読んだ直後は、OS から「メニューを閉じる」合図が 1 回届き、
/// 出したメニューが選ばずに一瞬で閉じる（実測：前面のアプリで 6 回中 6 回）。
/// その場合だけ出し直す（実測：出し直すと 18 回中 18 回、消えずに残った）。
enum MenuPresenter {
    /// これより短く閉じ、何も選ばれていなければ「勝手に閉じた」とみなす。
    static let minimumOpenTime: TimeInterval = 0.25
    static let maximumAttempts = 3

    /// 出し直すかの判定（純粋関数）。
    static func shouldRetry(openFor seconds: TimeInterval, chose: Bool, attempt: Int) -> Bool {
        !chose && seconds < minimumOpenTime && attempt < maximumAttempts
    }

    static func popUp(_ menu: NSMenu, at point: NSPoint, in view: NSView) {
        var chose = false
        let observer = NotificationCenter.default.addObserver(
            forName: NSMenu.didSendActionNotification, object: nil, queue: nil
        ) { _ in chose = true }
        defer { NotificationCenter.default.removeObserver(observer) }
        var attempt = 0
        while true {
            attempt += 1
            let start = Date()
            menu.popUp(positioning: nil, at: point, in: view)
            if !shouldRetry(openFor: Date().timeIntervalSince(start), chose: chose, attempt: attempt) { break }
        }
    }
}

extension Notification.Name {
    /// ポップアップ（ウィジェットの詳細・インスタンス選択・履歴）をすべて閉じる合図。
    static let groupDockDismissPopovers = Notification.Name("GroupDockDismissPopovers")
}

/// クリックしたとき、開いているポップアップを閉じるか（純粋関数）。
/// ポップアップの中のクリックでは閉じない。それ以外（他のアプリ・帯の別の所・他の窓）では閉じる。
enum PopoverDismissal {
    static func shouldDismiss(clickedWindowClass: String?) -> Bool {
        guard let name = clickedWindowClass else { return true }     // 他のアプリ
        return !name.contains("Popover")
    }
}

/// 開いているグループの吹き出しを、帯の別の所のクリックで閉じるか（純粋関数）。
/// 同じ要素（吹き出しの中・開いているグループのタイル）では閉じない。別の要素（ウィジェット・ボタン・仕切り線・空き）では閉じる。
/// アプリのタイルは、帯からグループへドラッグして入れる起点なので、押した瞬間には閉じず、ドラッグせずに離したとき閉じる。
enum GroupDismissal {
    /// 押した瞬間に閉じるか。`target` は押した所のタイル id（何も無ければ nil）。
    static func closesOnMouseDown(target: String?, expanded: UUID) -> Bool {
        guard let target else { return true }                        // 帯の空き
        if target == "group:\(expanded.uuidString)" { return false }  // 開いているグループ自身（タイルが開閉する）
        if target.hasPrefix("group:") { return false }               // 別のグループは、そのタイルが切り替える
        if target.hasPrefix("app:") { return false }                 // ドラッグの起点。離したときに決める
        return true                                                  // ウィジェット・ボタン・仕切り線
    }

    /// ドラッグせずに離したとき（クリック）に閉じるか。アプリのタイルを押して起動したあと。
    static func closesOnClick(target: String) -> Bool { target.hasPrefix("app:") }
}

/// 帯の右クリックメニュー（仕切り線・空き）の項目。設定画面を開かずに、よく変える設定を切り替える。
/// 項目の中身は純粋関数で決め、押したときの処理だけを `DockWindowController` が付ける。
enum StripMenuSpec {
    enum Action: Equatable {
        case addWidget
        case toggleAutoHide
        case place(String)         // "bottom" / "left" / "right"
    }

    struct Item: Equatable {
        let title: String
        let checked: Bool
        let action: Action
    }

    static let places: [(id: String, title: String)] = [("bottom", "下"), ("left", "左"), ("right", "右")]

    static func addItem() -> Item { Item(title: "ウィジェットを追加…", checked: false, action: .addWidget) }

    static func autoHideItem(autoHide: Bool) -> Item {
        Item(title: "使っていないときは自動で隠す", checked: autoHide, action: .toggleAutoHide)
    }

    /// 「表示する場所」の選択肢。いまの位置にチェックが付く。
    static func placeItems(position: String) -> [Item] {
        places.map { Item(title: $0.title, checked: $0.id == position, action: .place($0.id)) }
    }

    /// 押されたときの設定の変化（純粋関数）。
    static func apply(_ action: Action, autoHide: Bool, position: String) -> (autoHide: Bool, position: String) {
        switch action {
        case .addWidget: return (autoHide, position)
        case .toggleAutoHide: return (!autoHide, position)
        case .place(let id): return (autoHide, places.contains { $0.id == id } ? id : position)
        }
    }
}

/// ゴミ箱の右クリックメニューの項目。項目の中身は純粋関数で決め、押したときの処理だけ `DockView` が付ける。
/// 空にするのは壊す操作なので、確認を挟む。中身が無いときは押せない。
enum TrashMenuSpec {
    enum Action: Equatable { case open, empty }

    struct Item: Equatable {
        let title: String
        let action: Action
        let enabled: Bool
    }

    static func items(isEmpty: Bool) -> [Item] {
        [Item(title: "ゴミ箱を開く", action: .open, enabled: true),
         Item(title: "ゴミ箱を空にする…", action: .empty, enabled: !isEmpty)]
    }

    static func needsConfirmation(_ action: Action) -> Bool { action == .empty }

    static func confirmationMessage(count: Int) -> String {
        "ゴミ箱の \(count) 個の項目を、完全に削除します。この操作は取り消せません。"
    }

    /// Finder に尋ねた件数。失敗したとき・数字でないときは nil（0 件として扱わない＝黙って何も起きなくならない）。
    static func count(text: String?, failed: Bool) -> Int? {
        guard !failed, let text else { return nil }
        return Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
