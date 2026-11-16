import AppKit

/// アプリの右クリックから使う小さなダイアログ。
enum AppDialogs {
    /// 引数を入力させる。空欄なら引数なし。
    static func askArguments(current: String, title: String, completion: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = "\(title) の引数"
        alert.informativeText = "起動時に渡す引数を入力してください（例: -projectPath /Users/me/MyGame）。"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "キャンセル")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = current
        field.placeholderString = "引数なし"
        alert.accessoryView = field

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        completion(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 引数をそのまま見せる（閲覧用）。
    static func showArguments(_ ref: AppRef) {
        let alert = NSAlert()
        alert.messageText = "\(ref.name) の引数"
        let running = Launcher.commandLine(ref)
        var text = "設定されている引数: "
        text += ref.arguments.isEmpty ? "なし" : ref.arguments
        if let running { text += "\n\n起動中のコマンドライン:\n\(running)" }
        alert.informativeText = text
        alert.addButton(withTitle: "引数をコピー")
        alert.addButton(withTitle: "閉じる")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ref.arguments, forType: .string)
        }
    }

    /// 起動中のコマンドラインを表示する（引数を確認するため）。
    static func showCommandLine(_ ref: AppRef, command: String) {
        let alert = NSAlert()
        alert.messageText = "\(ref.name) はこの引数で起動しています"
        alert.informativeText = command
        alert.addButton(withTitle: "コピー")
        alert.addButton(withTitle: "閉じる")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
        }
    }
}
