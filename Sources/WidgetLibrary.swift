import AppKit
import Foundation

/// 外部ウィジェットが持てる「自由な設定項目」。コマンド内では `{id}` で参照できる。
struct WidgetParameter: Codable, Hashable, Identifiable {
    /// コマンド内で使う名前（例 "city" → `{city}`）。
    var id: String
    var label: String
    /// text / number / toggle / choice
    var kind: String = "text"
    var defaultValue: String = ""
    /// kind == "choice" のときの選択肢。
    var choices: [String] = []

    init(id: String, label: String, kind: String = "text", defaultValue: String = "", choices: [String] = []) {
        self.id = id
        self.label = label
        self.kind = kind
        self.defaultValue = defaultValue
        self.choices = choices
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? id
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "text"
        defaultValue = try c.decodeIfPresent(String.self, forKey: .defaultValue) ?? ""
        choices = try c.decodeIfPresent([String].self, forKey: .choices) ?? []
    }
}

/// 外部で作ったウィジェットの定義。`~/Library/Application Support/GroupDock/Widgets/*.json` に置く。
struct WidgetDefinition: Codable, Identifiable, Hashable {
    /// 一意な ID（例 "com.example.weather"）。
    var id: String
    var title: String
    var symbol: String = "square.stack"
    /// 表示の種類: text / ring / chart / clock / date
    /// chart は「12,18,25」のような数値の並びを返すと、横長のグラフになる。
    var type: String = "text"
    /// text と ring で実行するコマンド（/bin/sh -c で実行し、標準出力を表示）。
    var command: String?
    /// 既定の更新間隔（秒）。
    var interval: Double = 30
    /// 既定の色。
    var tint: String = "accent"
    /// このウィジェットが持てる設定項目（自由に増やせる）。
    var parameters: [WidgetParameter] = []
    /// `.groupwidget` のときのフォルダ（コマンドから `{bundle}` で参照できる）。
    var bundlePath: String?

    /// 数値を 0...100 で返す想定か（リング表示）。
    var isRing: Bool { type == "ring" }

    /// 数値の並びを返す想定か（横長グラフ）。
    var isChart: Bool { type == "chart" }

    init(id: String, title: String) {
        self.id = id
        self.title = title
    }

    // 古い定義（新しいキーが無い）でも既定値で読めるようにする。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? "square.stack"
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "text"
        command = try c.decodeIfPresent(String.self, forKey: .command)
        interval = try c.decodeIfPresent(Double.self, forKey: .interval) ?? 30
        tint = try c.decodeIfPresent(String.self, forKey: .tint) ?? "accent"
        parameters = try c.decodeIfPresent([WidgetParameter].self, forKey: .parameters) ?? []
    }
}

/// 外部ウィジェット定義の読み込みとコマンド実行。
/// ウィジェットのコマンド実行をどこまで許すか（アプリ内で絞るための方針）。
struct WidgetPolicy {
    /// コマンドの実行を許可した定義の ID。ここに無いものはコマンドを実行しない（ウィジェットごとに許可する）。
    var approved: Set<String> = []
    /// 通信の使用を許可した定義の ID。ここに無いものは sandbox-exec で通信を拒否する。
    var networkApproved: Set<String> = []

    func canRun(_ id: String) -> Bool { approved.contains(id) }
    func canUseNetwork(_ id: String) -> Bool { networkApproved.contains(id) }
}

enum WidgetLibrary {
    /// 現在の方針。`Store` が設定から入れる。
    static var policy = WidgetPolicy()

    /// 通信と自分のホーム外への書き込みを塞ぐプロファイル（読み取りは許可）。
    static let noNetworkProfile = """
    (version 1)
    (allow default)
    (deny network*)
    (deny file-write*)
    (allow file-write* (subpath "/private/tmp") (subpath "/private/var/folders"))
    """
    /// 定義を置くフォルダ（テストでは差し替える）。
    static var directoryOverride: URL?

    /// 定義を置くフォルダ。無ければ作る。
    static var directory: URL {
        let url: URL
        if let directoryOverride {
            url = directoryOverride
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            url = base.appendingPathComponent("GroupDock/Widgets", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private(set) static var definitions: [WidgetDefinition] = []
    /// 直近に読み込んだときのフォルダの状態（変化の検出に使う）。
    private static var lastSignature = ""
    /// 定義が変わったときに呼ばれる。
    static var onChange: (() -> Void)?

    /// 定義を読み直す。壊れたものは飛ばして名前だけ記録する。
    /// 単体の `.json` と、`manifest.json` を持つ `.groupwidget` フォルダの両方を読む。
    @discardableResult
    static func reload() -> [String] {
        var loaded: [WidgetDefinition] = []
        var broken: [String] = []
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []

        for file in files {
            let isDirectory = (try? file.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let manifest: URL?
            if isDirectory, file.pathExtension == "groupwidget" {
                manifest = file.appendingPathComponent("manifest.json")
            } else if file.pathExtension == "json" {
                manifest = file
            } else {
                continue
            }
            guard let manifest else { continue }
            do {
                let data = try Data(contentsOf: manifest)
                var def = try JSONDecoder().decode(WidgetDefinition.self, from: data)
                // バンドルなら、コマンドから {bundle} で中のファイルを参照できる。
                if isDirectory { def.bundlePath = file.path }
                if !loaded.contains(where: { $0.id == def.id }) { loaded.append(def) }
            } catch {
                broken.append(file.lastPathComponent)
                NSLog("GroupDock: widget definition broken \(file.lastPathComponent): \(error.localizedDescription)")
            }
        }

        let next = loaded.sorted { $0.title < $1.title }
        if next != definitions {
            definitions = next
            onChange?()
        }
        lastSignature = signature()
        return broken
    }

    /// フォルダの状態（ファイル名・更新時刻）。変わっていれば true を返して読み直す。
    @discardableResult
    static func reloadIfChanged() -> Bool {
        guard signature() != lastSignature else { return false }
        reload()
        return true
    }

    private static func signature() -> String {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return files.map { file in
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate?.timeIntervalSince1970 ?? 0
            return "\(file.lastPathComponent):\(Int(date))"
        }.sorted().joined(separator: "|")
    }

    /// ウィジェットを取り込む（`.json` か `.groupwidget`）。
    /// アプリの再ビルドも再起動も要らない。取り込んだらその場で読み直す。
    static func importItem(at url: URL) throws -> WidgetDefinition {
        let fm = FileManager.default
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        let manifest = isDirectory ? url.appendingPathComponent("manifest.json") : url
        let data = try Data(contentsOf: manifest)
        var def = try JSONDecoder().decode(WidgetDefinition.self, from: data)

        if isDirectory {
            let destination = directory.appendingPathComponent(url.lastPathComponent)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.copyItem(at: url, to: destination)
            def.bundlePath = destination.path
        } else {
            // 同じ ID の古い定義があれば消してから置く。
            let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "json" {
                if let old = try? JSONDecoder().decode(WidgetDefinition.self, from: Data(contentsOf: file)),
                   old.id == def.id {
                    try? fm.removeItem(at: file)
                }
            }
            let destination = directory.appendingPathComponent("\(def.id).json")
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try data.write(to: destination)
        }
        reload()
        return def
    }

    static func definition(id: String?) -> WidgetDefinition? {
        guard let id else { return nil }
        return definitions.first { $0.id == id }
    }

    /// パラメータの `{name}` を実際の値に置き換える。
    /// パラメータの値を安全な形にする。
    /// 改行・NUL はコマンドを分断できるので落とし、長さも制限する。
    static func sanitize(_ value: String) -> String {
        let cleaned = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\0", with: "")
        return String(cleaned.prefix(200))
    }

    /// シェル用に 1 つの引数として安全に引用する（シングルクォート）。
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// コマンド内の `{id}` を、引用済みの値に置き換える。
    /// 生の文字列を差し込むと `$(...)` などで追加のコマンドが動くため、必ず引用する。
    static func expand(_ command: String, definition: WidgetDefinition?, values: [String: String]) -> String {
        guard let definition else { return command }
        var result = command
        if let bundle = definition.bundlePath {
            result = result.replacingOccurrences(of: "{bundle}", with: shellQuote(bundle))
        }
        for parameter in definition.parameters {
            let raw = values[parameter.id] ?? parameter.defaultValue
            result = result.replacingOccurrences(of: "{\(parameter.id)}", with: shellQuote(sanitize(raw)))
        }
        return result
    }

    /// 「12, 18 25」のような出力を数値の並びにする（カンマ・空白・改行区切り）。
    static func parseSeries(_ text: String) -> [Double] {
        let separators = CharacterSet(charactersIn: ",、 \t\n")
        return text
            .components(separatedBy: separators)
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// 環境変数として渡す値（`$GROUPWIDGET_<ID>` で参照できる）。
    static func environment(for definition: WidgetDefinition?, values: [String: String]) -> [String: String] {
        guard let definition else { return [:] }
        var env: [String: String] = [:]
        for parameter in definition.parameters {
            let raw = values[parameter.id] ?? parameter.defaultValue
            let key = "GROUPWIDGET_" + parameter.id.uppercased()
                .replacingOccurrences(of: "-", with: "_")
            env[key] = sanitize(raw)
        }
        if let bundle = definition.bundlePath {
            env["GROUPWIDGET_BUNDLE"] = bundle
        }
        return env
    }

    /// コマンドを実行して 1 行目の文字を返す（5 秒で打ち切る）。
    static func run(_ def: WidgetDefinition) -> String? {
        run(def, values: [:])
    }

    /// `fullOutput` が真なら全行を返す（グラフ用）。既定は 1 行目だけ。
    static func run(_ def: WidgetDefinition, values: [String: String], fullOutput: Bool = false) -> String? {
        guard let raw = def.command, !raw.isEmpty else { return nil }
        // 許可していない定義は実行しない（取り込んだだけのものを勝手に走らせない）。
        guard policy.canRun(def.id) else {
            NSLog("GroupDock: widget \(def.id) is not approved to run commands")
            return nil
        }
        // シェルは使わない。許可したプログラムだけを、引数つきで直接起動する。
        let parsed: CommandGuard.Parsed
        do {
            parsed = try CommandGuard.parse(raw, definition: def, values: values)
        } catch {
            NSLog("GroupDock: widget \(def.id) command rejected: \(error)")
            return nil
        }

        let task = Process()
        if policy.canUseNetwork(def.id) {
            task.executableURL = parsed.executable
            task.arguments = parsed.arguments
        } else {
            // 通信を使わせない。sandbox-exec のプロファイルで network を拒否する。
            task.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            task.arguments = ["-p", Self.noNetworkProfile, parsed.executable.path] + parsed.arguments
        }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        env.merge(environment(for: def, values: values)) { _, new in new }
        task.environment = env
        task.qualityOfService = .utility
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        // 出力を読み切れないまま溢れないよう、上限を決めておく。
        pipe.fileHandleForReading.readabilityHandler = nil

        do {
            try task.run()
        } catch {
            NSLog("GroupDock: widget command failed \(def.id): \(error.localizedDescription)")
            return nil
        }

        // 固まったコマンドで帯が止まらないよう、5 秒で打ち切る。
        // 子プロセスが残らないよう、プロセスグループごと止める。
        let pid = task.processIdentifier
        let deadline = Date().addingTimeInterval(5)
        while task.isRunning, Date() < deadline {
            usleep(50_000)
        }
        if task.isRunning {
            // 先に子プロセスを止める（`sh -c` の子が残るとポートやファイルを掴み続ける）。
            let pkill = Process()
            pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            pkill.arguments = ["-TERM", "-P", String(pid)]
            try? pkill.run()
            pkill.waitUntilExit()
            task.terminate()
            _ = pipe.fileHandleForReading.readDataToEndOfFile()
            NSLog("GroupDock: widget command timed out \(def.id)")
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        // 上限 256KB。長すぎる出力は先頭だけ見る。
        let limit = 256 * 1024
        let clipped = data.count > limit ? data.prefix(limit) : data
        guard let raw = String(data: Data(clipped), encoding: .utf8) else { return nil }
        let text = fullOutput
            ? raw.trimmingCharacters(in: .whitespacesAndNewlines)
            : raw.split(separator: "\n").first.map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty ?? true) ? nil : text
    }

    /// パラメータ付きのひな形を書き出す（自由な設定を作るための例）。
    static func writeTemplate() -> URL? {
        let url = directory.appendingPathComponent("template-weather.json")
        let sample = """
        {
          "id": "com.example.weather",
          "title": "天気",
          "symbol": "cloud.sun",
          "type": "ring",
          "command": "echo 65",
          "interval": 60,
          "tint": "blue",
          "parameters": [
            { "id": "city", "label": "都市", "kind": "text", "defaultValue": "Tokyo" },
            { "id": "unit", "label": "単位", "kind": "choice", "defaultValue": "C",
              "choices": ["C", "F"] },
            { "id": "detail", "label": "詳細も出す", "kind": "toggle", "defaultValue": "false" }
          ]
        }
        """
        try? sample.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// ひな形を書き出す（外部で作り始めるための例）。
    static func writeSample() -> URL? {
        let url = directory.appendingPathComponent("sample-greeting.json")
        let sample = """
        {
          "id": "dev.hmgm.sample.greeting",
          "title": "あいさつ",
          "symbol": "hand.wave",
          "type": "text",
          "command": "echo こんにちは",
          "interval": 60,
          "tint": "green"
        }
        """
        try? sample.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
