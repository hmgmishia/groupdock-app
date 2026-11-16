import AppKit

/// グループの中のアプリを開く・終了する。
enum Launcher {
    static func running(_ ref: AppRef) -> [NSRunningApplication] {
        guard let id = ref.bundleID else { return [] }
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
    }

    static func isRunning(_ ref: AppRef) -> Bool {
        !running(ref).isEmpty
    }

    /// 起動中なら前面に出す。止まっていれば開く。
    /// Finder は、既定では開いているウィンドウを前面に出し、ウィンドウが無いときだけ新しく開く。
    /// 設定「毎回新しいウィンドウを開く」は `FinderOpen.currentAction` が読む（どの経路から呼んでも同じ動き）。
    static func open(_ ref: AppRef) {
        // 引数つきの項目は、別プロジェクトを開くために毎回新しく起動する。
        let hasArguments = !ref.argumentList.isEmpty
        if !hasArguments, let app = running(ref).first {
            if ref.bundleID == "com.apple.finder" {
                let hasWindows = hasVisibleWindows(pid: app.processIdentifier)
                switch FinderOpen.currentAction(hasWindows: hasWindows) {
                case .activateOnly:
                    _ = app.activate(options: [.activateAllWindows])
                case .openNewWindow:
                    // ホームで新しいウィンドウを開く。
                    _ = app.activate(options: [])
                    NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
                }
                return
            }
            _ = app.activate(options: [.activateAllWindows])
            if hasVisibleWindows(pid: app.processIdentifier) { return }
        }
        // 本当に起動するときだけ、履歴に残す（前面に出すだけのときは残さない）。
        NotificationCenter.default.post(name: .groupDockLaunch, object: nil, userInfo: ["ref": ref])
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = ref.argumentList
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: ref.path),
            configuration: config
        ) { _, error in
            if let error {
                NSLog("GroupDock: cannot open \(ref.path): \(error.localizedDescription)")
            }
        }
    }

    /// 再起動：終了を頼み、終わるのを待ってから同じ引数で開き直す（最大 10 秒待つ）。
    static func restart(_ ref: AppRef) {
        let apps = running(ref)
        guard !apps.isEmpty else { open(ref); return }
        apps.forEach { $0.terminate() }
        DispatchQueue.global(qos: .userInitiated).async {
            for _ in 0..<50 {
                if apps.allSatisfy(\.isTerminated) { break }
                Thread.sleep(forTimeInterval: 0.2)
            }
            DispatchQueue.main.async { open(ref) }
        }
    }

    /// Finder でそのアプリの場所を開く（アプリ本体を選んだ状態で）。
    static func revealInFinder(_ ref: AppRef) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: ref.path)])
    }

    /// 起動中のプロセスのコマンドライン（引数を見るため）。
    static func commandLine(_ ref: AppRef) -> String? {
        guard let app = running(ref).first else { return nil }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-o", "command=", "-p", String(app.processIdentifier)]
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty ?? true) ? nil : text
    }

    /// そのプロセスが画面に出している普通のウィンドウを持っているか。
    private static func hasVisibleWindows(pid: pid_t) -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return list.contains { window in
            guard let owner = window[kCGWindowOwnerPID as String] as? pid_t, owner == pid else { return false }
            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            return layer == 0
        }
    }

    static func quit(_ ref: AppRef) {
        running(ref).forEach { $0.terminate() }
    }

    /// 強制終了（応答しないアプリ用。標準 Dock と同じ）。
    static func forceQuit(_ ref: AppRef) {
        running(ref).forEach { $0.forceTerminate() }
    }

    /// グループ全体の起動。必ず確認してから行う（勝手に実行しない）。
    static func openAll(_ apps: [AppRef], group: String) {
        confirm("「\(group)」の \(apps.count) 個をすべて起動しますか？", button: "起動") { apps.forEach { open($0) } }
    }

    /// グループ全体の終了。必ず確認してから行う。
    static func quitAll(_ apps: [AppRef], group: String) {
        confirm("「\(group)」の \(apps.count) 個をすべて終了しますか？", button: "終了") { apps.forEach(quit) }
    }

    /// 次のループで確認を出す（SwiftUI の更新中にモーダルを出すと固まるため）。
    private static func confirm(_ message: String, button: String, run: @escaping () -> Void) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = message
            alert.addButton(withTitle: button)
            alert.addButton(withTitle: "キャンセル")
            if alert.runModal() == .alertFirstButtonReturn { run() }
        }
    }
}

/// GroupDock 自身の再起動（設定・メニュー共通）。設定を書き出してから終了し、少し待って開き直す。
enum SelfRestart {
    static func run(store: Store) {
        store.flushPrefs()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // パスは引数（$0）で渡し、シェルの文字列に埋め込まない。
        task.arguments = ["-c", "sleep 1.2; open \"$0\"", Bundle.main.bundleURL.path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
