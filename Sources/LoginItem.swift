import AppKit
import Foundation
import ServiceManagement

/// 二重起動を防ぐ。ロックファイルを掴めなければ、既に起動しているとみなす。
enum SingleInstance {
    private static var lockFD: Int32 = -1

    /// すでに起動中なら true（呼び出し側は終了する）。
    static func anotherIsRunning() -> Bool {
        let directory = Store.fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("instance.lock").path

        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return false }        // ロックできなければ二重起動は防がない

        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return true
        }
        lockFD = fd                                  // プロセスが生きている間は掴んだまま
        return false
    }

    /// 既に起動している GroupDock を前面に出す（見つからなければ何もしない）。
    static func activateExisting() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard let app = others.first else { return }
        app.activate(options: [])
        NSLog("GroupDock: すでに起動しています (pid \(app.processIdentifier))")
    }
}

/// Mac のログイン時に自動で起動する設定（macOS 13 以降のログイン項目）。
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// 切り替える。失敗したら理由を返す。
    @discardableResult
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            NSLog("GroupDock: login item \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)")
            return error.localizedDescription
        }
    }

    /// 初回起動時に一度だけオンにする（既定でオン）。
    static func enableByDefaultOnce() {
        let key = "GroupDockLoginItemConfigured"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        // まだ登録されていなければ、既定として登録する。
        if SMAppService.mainApp.status != .enabled {
            set(true)
        }
        UserDefaults.standard.set(true, forKey: key)
    }

    /// コマンドラインから切り替える（`--login-item on|off|status`）。
    static func handleArgumentIfPresent() -> Bool {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--login-item"), args.count > index + 1 else { return false }
        switch args[index + 1] {
        case "on":
            if let error = set(true) { print("login item: \(error)") } else { print("login item: on") }
        case "off":
            if let error = set(false) { print("login item: \(error)") } else { print("login item: off") }
        default:
            print("login item: \(stateText)")
        }
        return true
    }

    /// 状態の説明（システム設定で許可待ちのことがある）。
    static var stateText: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "オン"
        case .requiresApproval: return "システム設定 › 一般 › ログイン項目 で許可が必要"
        case .notRegistered: return "オフ"
        case .notFound: return "未登録（アプリを /Applications に置くと確実です）"
        @unknown default: return "不明"
        }
    }
}
