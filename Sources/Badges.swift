import AppKit
import ApplicationServices

/// 標準 Dock のアイコンに出ている未読バッジ（例 "54"）を、Dock のアクセシビリティから読む。
/// 他アプリのバッジ数を取る公開 API は無いので、Dock が公開している値をそのまま使う。
enum BadgeReader {
    /// アプリのパス → バッジの文字列。
    static func read() -> [String: String] {
        guard let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock").first else { return [:] }

        let dockApp = AXUIElementCreateApplication(dock.processIdentifier)
        var result: [String: String] = [:]

        for list in children(dockApp) where attribute(list, kAXRoleAttribute) as? String == "AXList" {
            for item in children(list) {
                guard attribute(item, kAXSubroleAttribute) as? String == "AXApplicationDockItem" else { continue }
                // 未読バッジは AXStatusLabel に入っている（定数は公開されていない）。
                let badge = attribute(item, "AXStatusLabel") as? String ?? ""
                guard !badge.isEmpty,
                      let url = attribute(item, kAXURLAttribute) as? URL else { continue }
                result[url.resolvingSymlinksInPath().path] = badge
            }
        }
        return result
    }

    private static func attribute(_ element: AXUIElement, _ key: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }
}
