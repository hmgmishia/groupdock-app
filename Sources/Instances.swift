import AppKit
import ApplicationServices
import Foundation

/// アプリの 1 インスタンス（実行中のプロセス）。UI を含まない（テストできる）。
struct AppInstance: Identifiable, Equatable {
    let pid: Int32
    /// 起動時に渡された引数（無ければ空）。
    let arguments: String
    /// ウィンドウ単位のときの番号と題名（プロセス単位なら nil）。
    var window: Int? = nil
    var windowTitle: String = ""
    var id: String { window.map { "\(pid)-\($0)" } ?? "\(pid)" }
}

enum AppInstances {
    /// コマンドライン全体から、実行ファイルの後ろの引数だけを取り出す。
    static func arguments(fromCommandLine line: String, executablePath: String) -> String {
        guard !executablePath.isEmpty, let range = line.range(of: executablePath) else { return "" }
        return line[range.upperBound...].trimmingCharacters(in: .whitespaces)
    }

    /// `ps -o pid=,command=` の出力を読む。`executables` は pid → 実行ファイルのパス。
    static func parse(_ output: String, executables: [Int32: String]) -> [AppInstance] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let pid = Int32(parts[0]), let exe = executables[pid] else { return nil }
            return AppInstance(pid: pid, arguments: arguments(fromCommandLine: String(parts[1]), executablePath: exe))
        }
        .sorted { $0.pid < $1.pid }
    }

    /// パスごとの数。引数が違っても、同じアプリの別インスタンスとして数える。
    static func counts(paths: [String]) -> [String: Int] {
        var result: [String: Int] = [:]
        for path in paths { result[path, default: 0] += 1 }
        return result
    }

    /// 複数あるか（青丸・選ぶポップアップの条件）。
    static func isMultiple(_ count: Int) -> Bool { count >= 2 }

    /// hover と右クリックに出す説明。
    static func info(_ instance: AppInstance, name: String) -> String {
        var lines = [name]
        if instance.window != nil { lines.append("ウィンドウ: " + (instance.windowTitle.isEmpty ? "（題名なし）" : instance.windowTitle)) }
        lines.append("pid \(instance.pid)")
        lines.append(instance.arguments.isEmpty ? "引数: なし" : "引数: \(instance.arguments)")
        return lines.joined(separator: "\n")
    }

    /// プロセスをウィンドウ単位に広げる（純粋関数）。ウィンドウが 2 つ以上のプロセスだけ、ウィンドウごとに分ける。
    static func expand(_ processes: [AppInstance], windows: [Int32: [String]]) -> [AppInstance] {
        processes.flatMap { process -> [AppInstance] in
            let titles = windows[process.pid] ?? []
            guard titles.count >= 2 else { return [process] }
            return titles.enumerated().map { index, title in
                AppInstance(pid: process.pid, arguments: process.arguments, window: index, windowTitle: title)
            }
        }
    }

    /// 選べる数（プロセス数とウィンドウ数の多い方）。
    static func choiceCount(processes: Int, windows: Int) -> Int { max(processes, windows) }

    /// プロセスの普通のウィンドウの題名（AX）。最小化も含める。裏のスレッドで呼ぶ。
    static func windowTitles(pid: pid_t) -> [String] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement] else { return [] }
        return list.compactMap { window in
            var role: AnyObject?
            AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &role)
            guard (role as? String) == (kAXStandardWindowSubrole as String) else { return nil }
            var title: AnyObject?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
            return title as? String ?? ""
        }
    }

    /// そのウィンドウを前面に上げる（番号で引き直す）。
    static func raise(_ instance: AppInstance) {
        let app = NSRunningApplication(processIdentifier: instance.pid)
        guard let index = instance.window else {
            app?.activate(options: [.activateAllWindows])
            return
        }
        let element = AXUIElementCreateApplication(instance.pid)
        var value: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
           let list = value as? [AXUIElement] {
            let standard = list.filter { window in
                var role: AnyObject?
                AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &role)
                return (role as? String) == (kAXStandardWindowSubrole as String)
            }
            if index < standard.count {
                AXUIElementSetAttributeValue(standard[index], kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                AXUIElementPerformAction(standard[index], kAXRaiseAction as CFString)
            }
        }
        app?.activate()
    }

    /// 実行中のインスタンスを読む（`ps` を呼ぶので、裏のスレッドで使う）。
    static func read(bundleID: String) -> [AppInstance] {
        var executables: [Int32: String] = [:]
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) where !app.isTerminated {
            if let path = app.executableURL?.path { executables[app.processIdentifier] = path }
        }
        guard !executables.isEmpty else { return [] }
        let list = executables.keys.sorted().map(String.init).joined(separator: ",")
        let processes = Shell.run("/bin/ps", ["-o", "pid=,command=", "-p", list]).map { parse($0, executables: executables) }
            ?? executables.keys.sorted().map { AppInstance(pid: $0, arguments: "") }
        var windows: [Int32: [String]] = [:]
        for process in processes { windows[process.pid] = windowTitles(pid: process.pid) }
        return expand(processes, windows: windows)
    }
}

/// アプリが応答しているか。標準 Dock と同じく、応答しないアプリは「終了」を「強制終了」にする。
/// 判定はアクセシビリティ（公開 API）で問い合わせ、制限時間内に答えなければ応答なしとみなす。
enum AppResponsiveness {
    /// 問い合わせの結果から判定する（純粋関数）。答えが返らなかったときだけ応答なし。
    static func isHung(_ error: AXError) -> Bool { error == .cannotComplete }

    /// pid に問い合わせる。裏のスレッドで呼ぶ（最大 `timeout` 秒待つ）。
    static func isHung(pid: pid_t, timeout: Float = 0.5) -> Bool {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, timeout)
        var value: AnyObject?
        return isHung(AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value))
    }
}

/// 重い確認の間隔（純粋関数）。見た目に影響しない範囲で間引く。
enum PollPolicy {
    /// ホバー・自動で隠す判定の間隔。自動で隠す設定のとき、または帯（吹き出し）の近くにカーソルがあるときは 0.2 秒、
    /// 離れているときは 0.5 秒。
    static func hoverInterval(autoHide: Bool, mouseNear: Bool) -> TimeInterval {
        autoHide || mouseNear ? 0.2 : 0.5
    }

    /// ウィジェットの判定タイマーの間隔。秒まで出す時計・日付があるときだけ 0.25 秒（秒の境目で更新）、
    /// それ以外は 1 秒。ウィジェットが無ければ 5 秒（再生中の取得の判定だけ）。
    /// `hidden`: 帯が自動で隠れている間は更新しないので 5 秒（出たときは別途すぐ更新する）。
    static func widgetTimerInterval(_ widgets: [Widget], hidden: Bool = false) -> TimeInterval {
        if widgets.isEmpty || hidden { return 5 }
        let needsFast = widgets.contains { ($0.kind == .clock || $0.kind == .date) && $0.showSeconds }
        return needsFast ? 0.25 : 1
    }

    /// 再生中の取得（`perl` を起動する）。再生位置はアプリ側で進めるので、再生中でも頻繁には読まない。
    static func nowPlayingInterval(playing: Bool) -> TimeInterval { playing ? 3 : 6 }

    /// 3 秒ごとの巡回のうち、ウィンドウ数・応答の確認は 2 回に 1 回（6 秒）、アイコン更新の確認は 10 回に 1 回（30 秒）。
    /// 帯が見えている間は毎回（3 秒）、隠れている間は数えない（誰も見ないので）。
    static func checksResponsiveness(tick: Int, hidden: Bool = false) -> Bool { !hidden }
    static func checksIcons(tick: Int) -> Bool { tick % 10 == 0 }
}

/// 緑丸の判定に使う、動いているアプリの識別子（純粋関数）。通常のアプリでなくても、動いていれば数える。
enum RunningMatch {
    struct Entry { var id: String?; var terminated: Bool; var isSelf: Bool }

    static func bundleIDs(_ entries: [Entry]) -> Set<String> {
        Set(entries.compactMap { $0.terminated || $0.isSelf ? nil : $0.id })
    }
}

/// 起動してすぐ終わる一時的なアプリを、「実行中」の枠と履歴に出さないための判定（純粋関数）。
/// 動き続けて `settleTime` 秒たったものだけ「安定した」とみなす。
enum RunningSettle {
    static let settleTime: TimeInterval = 2

    /// `firstSeen`: パス → 最初に見た時刻。いまも動いているものだけ残し、新しいものに時刻を付ける。
    static func update(_ firstSeen: [String: Date], current: [String], now: Date) -> [String: Date] {
        var next: [String: Date] = [:]
        for path in current { next[path] = firstSeen[path] ?? now }
        return next
    }

    /// 安定したもの（現れた順を保つ）。
    static func settled(_ firstSeen: [String: Date], current: [String], now: Date) -> [String] {
        current.filter { path in
            guard let seen = firstSeen[path] else { return false }
            return now.timeIntervalSince(seen) >= settleTime
        }
    }

    /// まだ安定していないものがあるか（あれば、安定する頃にもう一度確認する）。
    static func hasPending(_ firstSeen: [String: Date], current: [String], now: Date) -> Bool {
        current.contains { (firstSeen[$0]).map { now.timeIntervalSince($0) < settleTime } ?? true }
    }
}
