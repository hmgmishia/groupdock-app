import AppKit

/// macOS の Dock を隠す / 元に戻す。
enum SystemDock {
    private static let domain = "com.apple.dock"
    private static let backupKey = "GroupDockSavedDockAutohide"
    private static let backupDelayKey = "GroupDockSavedDockDelay"

    private static func read(_ key: String) -> String? {
        let out = Process()
        out.launchPath = "/usr/bin/defaults"
        out.arguments = ["read", domain, key]
        let pipe = Pipe()
        out.standardOutput = pipe
        try? out.run()
        out.waitUntilExit()
        guard out.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty ?? true) ? nil : text
    }

    /// defaults に書く。数値は -float、真偽は -bool と、型を明示する。
    /// 以前は数値を -string で書いていたため、Dock が読めず標準 Dock が出てきていた。
    private static func write(_ key: String, float value: Double) {
        run(["/usr/bin/defaults", "write", domain, key, "-float", String(value)])
    }

    private static func write(_ key: String, bool value: Bool) {
        run(["/usr/bin/defaults", "write", domain, key, "-bool", value ? "true" : "false"])
    }

    private static func delete(_ key: String) {
        run(["/usr/bin/defaults", "delete", domain, key])
    }

    private static func run(_ args: [String]) {
        let task = Process()
        task.launchPath = args[0]
        task.arguments = Array(args.dropFirst())
        try? task.run()
        task.waitUntilExit()
    }

    private static func restartDock() {
        run(["/usr/bin/killall", "Dock"])
    }

    /// 隠す：自動で隠す＋待ち時間を十分長く＋アニメーション無し。
    /// 元の値は控えておき、戻すときに使う。
    static func hide() {
        if let current = read("autohide") {
            UserDefaults.standard.set(current, forKey: backupKey)
        }
        if let delay = read("autohide-delay") {
            UserDefaults.standard.set(delay, forKey: backupDelayKey)
        }
        write("autohide", bool: true)
        write("autohide-delay", float: 1000)
        write("autohide-time-modifier", float: 0)
        restartDock()
    }

    /// 戻す：控えておいた値に戻す（控えが無ければ自動で隠さない・標準の待ち時間）。
    static func restore() {
        let saved = UserDefaults.standard.string(forKey: backupKey) ?? "false"
        write("autohide", bool: saved == "true" || saved == "1")

        if let delay = UserDefaults.standard.string(forKey: backupDelayKey) {
            write("autohide-delay", float: Double(delay) ?? 0.5)
        } else {
            delete("autohide-delay")
        }
        delete("autohide-time-modifier")

        UserDefaults.standard.removeObject(forKey: backupKey)
        UserDefaults.standard.removeObject(forKey: backupDelayKey)
        restartDock()
    }

    /// 終了時用：標準 Dock を必ず見える状態に戻す。
    /// 元の設定が「自動で隠す」だった場合でも、GroupDock を消した直後は Dock を出しておく。
    static func showDock() {
        write("autohide", bool: false)
        delete("autohide-delay")
        delete("autohide-time-modifier")
        UserDefaults.standard.removeObject(forKey: backupKey)
        UserDefaults.standard.removeObject(forKey: backupDelayKey)
        restartDock()
    }

    static func apply(hiding: Bool) {
        if hiding { hide() } else { restore() }
    }

    /// 今の状態（隠せているか）を確かめるための値。
    static func currentDelay() -> String? { read("autohide-delay") }
}
