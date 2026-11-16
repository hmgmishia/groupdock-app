import Foundation

/// ウィジェットのポップアップから、その場で変えられる操作。UI を含まない（テストできる）。

/// 1 つのプロセス。
struct TopProcess: Identifiable, Equatable {
    let pid: Int32
    let name: String
    /// CPU 使用率（%）。
    let cpu: Double
    /// 使用メモリ（MB）。
    let memoryMB: Double
    var id: Int32 { pid }
}

enum ProcessList {
    enum Metric { case cpu, memory }

    /// `ps -o pid=,pcpu=,rss=,comm=` の出力を読む。名前に空白があっても崩れないよう、先頭 3 つだけ分けて残りを名前にする。
    static func parse(_ output: String) -> [TopProcess] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4,
                  let pid = Int32(parts[0]), let cpu = Double(parts[1]), let rss = Double(parts[2]) else { return nil }
            return TopProcess(pid: pid, name: String(parts[3]), cpu: cpu, memoryMB: rss / 1024)
        }
    }

    /// 指標の大きい順に `count` 件。自分自身と pid 1 以下は、誤って止めないよう除く。
    static func top(
        _ list: [TopProcess], by metric: Metric, count: Int = 3, excluding own: Int32 = ProcessInfo.processInfo.processIdentifier
    ) -> [TopProcess] {
        let candidates = list.filter { $0.pid > 1 && $0.pid != own }
        let sorted = candidates.sorted { metric == .cpu ? $0.cpu > $1.cpu : $0.memoryMB > $1.memoryMB }
        return Array(sorted.prefix(count))
    }

    /// 自分のユーザーのプロセスだけを読む（他のユーザーや OS のプロセスは対象にしない）。
    static func read() -> [TopProcess] {
        let user = NSUserName()
        guard let output = Shell.run("/bin/ps", ["-U", user, "-ceo", "pid=,pcpu=,rss=,comm="]) else { return [] }
        return parse(output)
    }

    /// 終了（SIGTERM）または強制終了（SIGKILL）を送る。送れたら true。
    @discardableResult
    static func signal(_ pid: Int32, force: Bool) -> Bool {
        guard pid > 1, pid != ProcessInfo.processInfo.processIdentifier else { return false }
        return kill(pid, force ? SIGKILL : SIGTERM) == 0
    }
}

/// 音量と低電力モード。
enum SystemControls {
    /// 出力音量（0〜100）とミュート。
    static func volume() -> (level: Int, muted: Bool)? {
        guard let out = Shell.run("/usr/bin/osascript", ["-e", "get volume settings"]) else { return nil }
        return parseVolume(out)
    }

    static func parseVolume(_ text: String) -> (level: Int, muted: Bool)? {
        var level: Int?
        var muted = false
        for part in text.split(separator: ",") {
            let pair = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard pair.count == 2 else { continue }
            if pair[0] == "output volume" { level = Int(pair[1]) }
            if pair[0] == "output muted" { muted = pair[1] == "true" }
        }
        return level.map { (min(100, max(0, $0)), muted) }
    }

    static func setVolume(_ level: Int) {
        let value = min(100, max(0, level))
        _ = Shell.run("/usr/bin/osascript", ["-e", "set volume output volume \(value)"])
    }

    static func setMuted(_ muted: Bool) {
        _ = Shell.run("/usr/bin/osascript", ["-e", "set volume output muted \(muted ? "true" : "false")"])
    }

    /// 低電力モードが入っているか。
    static func lowPowerEnabled() -> Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    /// 低電力モードを切り替える。管理者の認証ダイアログが出る（pmset が管理者権限を要するため）。
    @discardableResult
    static func setLowPower(_ on: Bool) -> Bool {
        let script = "do shell script \"/usr/bin/pmset -a lowpowermode \(on ? 1 : 0)\" with administrator privileges"
        return Shell.run("/usr/bin/osascript", ["-e", script]) != nil
    }
}

/// 外部コマンドを、シェルを通さず引数つきで直接実行する。
enum Shell {
    static func run(_ executable: String, _ arguments: [String], environment: [String: String] = [:]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        if !environment.isEmpty {
            task.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// 再生中の補助ライブラリを、Apple 署名の /usr/bin/perl に読み込ませて呼ぶ。
/// macOS は MediaRemote の情報を Apple 署名のプロセスにしか返さないため。出力は標準出力の JSON 1 行だけ。
enum MediaRemoteHelper {
    /// perl の小さな台本：ライブラリを読み、指定の関数を呼ぶだけ。引数は台本に埋め込まず、引数で渡す。
    static let script = "use DynaLoader; my $l = DynaLoader::dl_load_file($ARGV[0], 0) or exit 1; "
        + "my $s = DynaLoader::dl_find_symbol($l, $ARGV[1]) or exit 1; "
        + "DynaLoader::dl_install_xsub('main::gd', $s); gd();"

    static var libraryPath: String? {
        Bundle.main.path(forResource: "gdnowplaying", ofType: "dylib")
    }

    /// 決まった関数だけを呼ぶ（呼び出し側が任意の名前を渡せないよう、列挙で限定する）。
    enum Call: String {
        case getWithArtwork = "gd_get_artwork"
        case getPlain = "gd_get_plain"
        case toggle = "gd_toggle"
        case next = "gd_next"
        case previous = "gd_previous"
        case seek = "gd_seek"
    }

    /// 再生位置の秒を、環境変数の文字にする（数字だけ。負は 0）。
    static func seekValue(_ seconds: Double) -> String { String(format: "%.2f", max(0, seconds)) }

    static func run(_ call: Call, seconds: Double? = nil) -> String? {
        guard let path = libraryPath else { return nil }
        let environment = seconds.map { ["GD_SEEK": seekValue($0)] } ?? [:]
        return Shell.run("/usr/bin/perl", ["-e", script, path, call.rawValue], environment: environment)
    }
}
