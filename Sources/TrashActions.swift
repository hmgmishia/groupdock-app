import AppKit
import Foundation

/// ゴミ箱の操作。開く・空にする。空にするのは壊す操作なので、件数を示して確認してから、Finder に頼む。
/// Finder への Apple Events（`NSAppleEventsUsageDescription`）を使う。ファイルを直接は消さない。
/// AppleScript は 1 本の直列キュー（`Store.nowPlayingQueue`）でだけ実行する（`AppleScriptRunner` の約束）。
enum TrashActions {
    private static let url = URL(fileURLWithPath: NSHomeDirectory() + "/.Trash", isDirectory: true)

    /// 中身が無いか。読めないとき（権限が無い等）は、空ではないとして扱う（押せなくしない）。
    static var isEmpty: Bool {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return false }
        return items.filter { $0 != ".DS_Store" }.isEmpty
    }

    static func open() { NSWorkspace.shared.open(url) }

    /// 件数を Finder に尋ね、確認ダイアログを出し、了承されたら空にする。失敗は、必ずダイアログで知らせる。
    static func confirmAndEmpty(on queue: DispatchQueue) {
        queue.async {
            let result = AppleScriptRunner.run("tell application \"Finder\" to return (count of items of trash) as text")
            let count = TrashMenuSpec.count(text: result.text, failed: result.failed)
            DispatchQueue.main.async {
                guard let count else {
                    notify("Finder に問い合わせられませんでした", "システム設定 › プライバシーとセキュリティ › オートメーションで、GroupDock が Finder を操作することを許可してください。")
                    return
                }
                guard count > 0 else { return }
                let alert = NSAlert()
                alert.messageText = "ゴミ箱を空にしますか？"
                alert.informativeText = TrashMenuSpec.confirmationMessage(count: count)
                alert.alertStyle = .warning
                alert.addButton(withTitle: "空にする")
                alert.addButton(withTitle: "キャンセル")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                queue.async {
                    let emptied = AppleScriptRunner.run("tell application \"Finder\" to empty trash")
                    if emptied.failed {
                        DispatchQueue.main.async { notify("ゴミ箱を空にできませんでした", "Finder が応答しないか、一部の項目が使用中です。") }
                    }
                }
            }
        }
    }

    private static func notify(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.runModal()
    }
}
