import Foundation

/// アプリが固まったら、標準 Dock を自動で戻す見張り。
///
/// GroupDock はメニューバー常駐（`LSUIElement`）なので「強制終了」の一覧にも出ず、
/// 固まると触る手段が無くなる。そこで別スレッドからメインスレッドの心拍を見張り、
/// 一定時間止まったら `SystemDock.showDock()` で Dock を出して、Mac を操作できる状態に戻す。
final class Watchdog {
    /// これ以上メインスレッドが止まったら「固まった」とみなす（秒）。
    static let stallThreshold: TimeInterval = 4
    /// 復旧を試す間隔（秒）。
    static let retryInterval: TimeInterval = 15

    private let queue = DispatchQueue(label: "GroupDock.watchdog", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var heartbeat = Date()
    private var lastRecovery = Date.distantPast
    private var reported = false

    /// 固まったかどうか（純粋関数なのでテストできる）。
    static func isStalled(lastBeat: Date, now: Date, threshold: TimeInterval = stallThreshold) -> Bool {
        now.timeIntervalSince(lastBeat) >= threshold
    }

    func start() {
        // メインスレッドの心拍（1 秒ごと）。固まるとこれが止まる。
        let beat = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.heartbeat = Date()
        }
        RunLoop.main.add(beat, forMode: .common)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 1)
        timer.setEventHandler { [weak self] in
            self?.check()
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func check() {
        let now = Date()
        guard Watchdog.isStalled(lastBeat: heartbeat, now: now) else {
            if reported {
                reported = false
                NSLog("GroupDock: watchdog: recovered (main thread is responding again)")
            }
            return
        }
        guard now.timeIntervalSince(lastRecovery) >= Watchdog.retryInterval else { return }
        lastRecovery = now
        if !reported {
            reported = true
            NSLog("GroupDock: watchdog: main thread stalled, restoring the system Dock")
            NotificationLog.write("watchdog: 固まったため標準 Dock を戻しました")
        }
        // 固まっていても、標準 Dock を戻せば操作は続けられる。
        SystemDock.showDock()
    }
}

/// 固まったことを後から確認できるように、ファイルにも残す（ログが読めないとき用）。
enum NotificationLog {
    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("GroupDock/watchdog.log")
    }

    static func write(_ message: String) {
        let line = ISO8601DateFormatter().string(from: Date()) + " " + message + "\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: fileURL)
        }
    }
}
