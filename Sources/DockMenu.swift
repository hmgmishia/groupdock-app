import AppKit
import ApplicationServices

/// アプリ自身が定義した Dock のメニュー（新規ウィンドウ・最近使った項目など）を、標準 Dock の AX から読んで実行する。
/// 読むときだけ標準 Dock のメニューを開き、読み終えたらすぐ閉じる。private API は使わない。
enum DockMenu {
    struct Entry: Equatable {
        let title: String
        let isSeparator: Bool
        let isEnabled: Bool
        let isChecked: Bool
        let children: [Entry]
    }

    /// 項目を子メニューごと読む。標準 Dock にそのアプリが無ければ空。
    static func read(path: String) -> [Entry] {
        guard let item = dockItem(path: path), let menu = open(item) else { return [] }
        defer { _ = AXUIElementPerformAction(menu, "AXCancel" as CFString) }
        return entries(of: menu)
    }

    /// 題名の並び（子メニューなら親から順）で項目を押す。メニューを開き直して押す。
    @discardableResult
    static func perform(path: String, titles: [String]) -> Bool {
        guard let item = dockItem(path: path), let menu = open(item) else { return false }
        var current = menu
        for (index, title) in titles.enumerated() {
            guard let target = children(current).first(where: {
                role($0) == "AXMenuItem" && attribute($0, kAXTitleAttribute) as? String == title
            }) else { break }
            if index == titles.count - 1 {
                return AXUIElementPerformAction(target, kAXPressAction as CFString) == .success
            }
            guard let sub = children(target).first(where: { role($0) == "AXMenu" }) else { break }
            current = sub
        }
        _ = AXUIElementPerformAction(menu, "AXCancel" as CFString)
        return false
    }

    /// AppKit のメニュー項目にする（押されたら `run` に題名の並びを渡す）。
    static func menuItems(_ entries: [Entry], parents: [String] = [], run: @escaping ([String]) -> Void) -> [NSMenuItem] {
        entries.map { entry in
            if entry.isSeparator { return .separator() }
            let item = ClosureMenuItem(title: entry.title) { run(parents + [entry.title]) }
            item.isEnabled = entry.isEnabled
            item.state = entry.isChecked ? .on : .off
            if !entry.children.isEmpty {
                let sub = NSMenu()
                sub.autoenablesItems = false
                menuItems(entry.children, parents: parents + [entry.title], run: run).forEach(sub.addItem)
                item.submenu = sub
                item.action = nil
            }
            return item
        }
    }

    // MARK: - AX の補助

    private static func open(_ item: AXUIElement) -> AXUIElement? {
        guard AXUIElementPerformAction(item, "AXShowMenu" as CFString) == .success else { return nil }
        // メニューが出るまで待つ（実測 40ms 前後。最大 0.4 秒）。
        for _ in 0..<40 {
            if let menu = children(item).first(where: { role($0) == "AXMenu" }) { return menu }
            usleep(10_000)
        }
        return nil
    }

    private static func entries(of menu: AXUIElement) -> [Entry] {
        children(menu).compactMap { element in
            guard role(element) == "AXMenuItem" else { return nil }
            let title = attribute(element, kAXTitleAttribute) as? String ?? ""
            let enabled = attribute(element, kAXEnabledAttribute) as? Bool ?? true
            let mark = attribute(element, "AXMenuItemMarkChar") as? String ?? ""
            let sub = children(element).first(where: { role($0) == "AXMenu" }).map(entries(of:)) ?? []
            return Entry(title: title, isSeparator: title.isEmpty, isEnabled: enabled, isChecked: !mark.isEmpty, children: sub)
        }
    }

    private static func dockItem(path: String) -> AXUIElement? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let root = AXUIElementCreateApplication(dock.processIdentifier)
        for list in children(root) where role(list) == "AXList" {
            for item in children(list) {
                guard let url = attribute(item, kAXURLAttribute) as? URL else { continue }
                if url.resolvingSymlinksInPath().path == path { return item }
            }
        }
        return nil
    }

    private static func role(_ element: AXUIElement) -> String { attribute(element, kAXRoleAttribute) as? String ?? "" }

    private static func attribute(_ element: AXUIElement, _ key: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }
}

/// 押されたら閉じ込めた処理を呼ぶメニュー項目。
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler() }
}
