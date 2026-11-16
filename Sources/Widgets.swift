import AppKit
import EventKit
import Foundation
import IOKit.ps

/// 帯に置けるウィジェットの種類。
enum WidgetKind: String, Codable, CaseIterable, Identifiable {
    case clock
    case date
    case battery
    case memory
    case cpu
    case disk
    case calendar
    case nowPlaying
    case volume
    case microphone
    case brightness
    case trend
    case clipboard
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clock: return "時計"
        case .date: return "日付"
        case .battery: return "バッテリー"
        case .memory: return "メモリ"
        case .cpu: return "CPU"
        case .disk: return "ディスク"
        case .calendar: return "予定"
        case .nowPlaying: return "再生中"
        case .volume: return "音量"
        case .microphone: return "マイク"
        case .brightness: return "明るさ"
        case .trend: return "推移"
        case .clipboard: return "クリップボード"
        case .custom: return "ライブラリ"
        }
    }

    var symbol: String {
        switch self {
        case .clock: return "clock"
        case .date: return "calendar"
        case .battery: return "battery.75percent"
        case .memory: return "memorychip"
        case .cpu: return "cpu"
        case .disk: return "internaldrive"
        case .calendar: return "calendar.badge.clock"
        case .nowPlaying: return "music.note"
        case .volume: return "speaker.wave.2"
        case .microphone: return "mic"
        case .brightness: return "sun.max"
        case .trend: return "chart.xyaxis.line"
        case .clipboard: return "doc.on.clipboard"
        case .custom: return "square.stack"
        }
    }
}

extension WidgetKind {
    /// 押したときの導線（関連するアプリ・設定）。数値を見せるだけで終わらせない。
    var destination: (title: String, target: String)? {
        switch self {
        case .clock: return ("時計を開く", "/System/Applications/Clock.app")
        case .date, .calendar: return ("カレンダーを開く", "/System/Applications/Calendar.app")
        case .battery: return ("バッテリー設定を開く", "x-apple.systempreferences:com.apple.Battery-Settings.extension")
        case .memory, .cpu, .trend:
            return ("アクティビティモニタを開く", "/System/Applications/Utilities/Activity Monitor.app")
        case .disk: return ("ストレージ設定を開く", "x-apple.systempreferences:com.apple.settings.Storage")
        case .nowPlaying: return nil
        case .clipboard: return nil
        case .volume: return ("サウンド設定を開く", "x-apple.systempreferences:com.apple.Sound-Settings.extension")
        case .microphone: return ("サウンド設定を開く", "x-apple.systempreferences:com.apple.Sound-Settings.extension")
        case .brightness: return ("ディスプレイ設定を開く", "x-apple.systempreferences:com.apple.Displays-Settings.extension")
        case .custom: return nil
        }
    }

    func openDestination() {
        guard let target = destination?.target else { return }
        let url = target.hasPrefix("/") ? URL(fileURLWithPath: target) : URL(string: target)
        if let url { NSWorkspace.shared.open(url) }
    }
}

/// ウィジェットの見え方。形（正方形・横長）と描き方を 1 つで選ぶ。横長でもグラフとは限らない。
enum WidgetFace: String, Codable, CaseIterable, Identifiable {
    case ring        // 正方形・リング
    case text        // 正方形・文字
    case wideText    // 横長・文字（時計・日付など。幅は内容で決まる）
    case wideBar     // 横長・文字＋バー
    case wideChart   // 横長・文字＋推移のグラフ
    case tallText    // 縦長・文字（左右に置くとき。時刻は行を分けて積む）
    case tallBar     // 縦長・文字＋縦のバー（左右に置くとき）

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ring: return "リング"
        case .text: return "文字（正方形）"
        case .wideText: return "文字（横長）"
        case .wideBar: return "バー（横長）"
        case .wideChart: return "グラフ（横長）"
        case .tallText: return "文字（縦長）"
        case .tallBar: return "バー（縦長）"
        }
    }

    var isWide: Bool { self == .wideText || self == .wideBar || self == .wideChart }
    var isTall: Bool { self == .tallText || self == .tallBar }
}

extension WidgetKind {
    /// 数値（0〜100%）を持つ種類か。リング・バー・グラフが選べる。
    var isNumeric: Bool {
        switch self {
        case .battery, .memory, .cpu, .disk, .volume, .microphone, .brightness, .trend: return true
        default: return false
        }
    }

    /// 選べる見え方。
    var availableFaces: [WidgetFace] {
        switch self {
        case .nowPlaying: return []
        case .clock, .date, .calendar: return [.wideText, .text]
        case .custom: return [.ring, .text, .wideText, .wideBar, .wideChart]
        default: return isNumeric ? [.ring, .text, .wideText, .wideBar, .wideChart] : [.text, .wideText]
        }
    }

    /// 左右に置くときに選べる見え方（横長は帯からはみ出すので出さない）。
    var sideFaces: [WidgetFace] {
        switch self {
        case .nowPlaying: return []
        case .clock, .date, .calendar: return [.tallText, .text]
        case .custom: return [.ring, .text, .tallText, .tallBar]
        default: return isNumeric ? [.ring, .text, .tallText, .tallBar] : [.text, .tallText]
        }
    }

    /// 左右に置くときの既定。時計・日付・予定は縦長の文字（時刻が切れない）。
    var defaultSideFace: WidgetFace {
        switch self {
        case .clock, .date, .calendar: return .tallText
        default: return isNumeric ? .ring : .text
        }
    }

    /// 種類ごとの既定。時計・日付・予定は時刻が切れないよう横長。
    var defaultFace: WidgetFace {
        switch self {
        case .clock, .date, .calendar: return .wideText
        case .trend: return .wideChart
        default: return isNumeric ? .ring : .text
        }
    }
}

/// ウィジェットの形。
enum WidgetShape: String, Codable, CaseIterable, Identifiable {
    case square
    case wide

    var id: String { rawValue }

    var title: String {
        switch self {
        case .square: return "正方形"
        case .wide: return "横長（グラフ）"
        }
    }
}

/// ウィジェットの見た目。
enum WidgetStyle: String, Codable, CaseIterable, Identifiable {
    case automatic
    case ring
    case text

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "自動（数値はリング）"
        case .ring: return "リング"
        case .text: return "文字"
        }
    }
}

/// ウィジェットごとに切り替えられる設定項目。
enum WidgetSetting: String, CaseIterable, Identifiable {
    case seconds
    case use24Hour
    case showTime
    case dateStyle
    case timeZone
    case shape

    var id: String { rawValue }
}

/// 1 つのウィジェット。設定はウィジェットごとに持つ。
struct Widget: Codable, Identifiable, Hashable {
    var id = UUID()
    var kind: WidgetKind
    /// 秒まで出す（時計・日付の時刻）。
    var showSeconds: Bool = true
    /// 24 時間表示（オフなら午前/午後）。
    var use24Hour: Bool = true
    /// 日付に時刻も出す。
    var showTime: Bool = true
    /// 日付の書き方（0: M/d(曜), 1: M月d日(曜), 2: yyyy/M/d(曜)）。
    var dateStyle: Int = 0
    /// 表示する地域。nil ならシステムの設定に従う。
    var timeZoneID: String? = nil
    /// 値の更新間隔（秒）。
    var refreshInterval: Double = 3
    /// 見た目（自動・リング・文字）。
    var style: WidgetStyle = .automatic
    /// アイコンの下に名前を出す。
    var showLabel: Bool = true
    /// 色（accent / red / orange / yellow / green / blue / purple / pink / gray）。
    var tint: String = "accent"
    /// 外部ライブラリの定義 ID（kind == .custom のとき使う）。
    var libraryID: String? = nil
    /// 外部ライブラリのパラメータ値（項目名 → 値）。
    var values: [String: String] = [:]
    /// 形（正方形／横長グラフ）。
    var shape: WidgetShape = .square
    /// グラフに残す点の数。
    var historyLength: Int = 40
    /// 再生中ウィジェットの表示パターン。
    var playerLayout: PlayerLayout = .full
    /// 見え方（nil なら古い設定の「形・表示」と種類から決める）。下に置くとき。
    var face: WidgetFace? = nil
    /// 左右に置くときの見え方（下置きとは別に持つ）。nil なら種類の既定。
    var sideFace: WidgetFace? = nil
    /// 左右に置くときの再生中の表示パターン（下置きとは別に持つ）。
    var sidePlayerLayout: PlayerLayout = .full
    /// 音量・マイクで固定したデバイスの UID（nil か空なら固定なし＝システムの既定に従う）。
    /// 固定したデバイスが消えても、この値は消さない（指す先を変えない。使えない表示になるだけ）。
    var pinnedDeviceUID: String? = nil
    /// 固定したデバイスの、最後に見えたときの名前（消えていても表示に使う）。
    var pinnedDeviceName: String? = nil

    /// 音量・マイクが指すデバイス。
    var audioTarget: AudioTarget {
        AudioDevices.target(pinnedUID: pinnedDeviceUID, pinnedName: pinnedDeviceName)
    }

    /// 指す先を保存形式に書く。
    mutating func setAudioTarget(_ target: AudioTarget) {
        switch target {
        case .followDefault:
            pinnedDeviceUID = nil
            pinnedDeviceName = nil
        case .pinned(let uid, let name):
            pinnedDeviceUID = uid
            pinnedDeviceName = name
        }
    }

    /// 音量・マイクの向き。
    var audioDirection: AudioDirection { kind == .microphone ? .input : .output }

    /// 左右に置くときに使う見え方。下置きで正方形（リング・文字）を選んでいれば、それを引き継ぐ。
    var resolvedSideFace: WidgetFace {
        let options = kind.sideFaces
        if let sideFace, options.contains(sideFace) { return sideFace }
        if options.contains(resolvedFace) { return resolvedFace }
        return options.contains(kind.defaultSideFace) ? kind.defaultSideFace : (options.first ?? .text)
    }

    /// 帯の向きに合わせた見え方・再生中の表示パターン。
    func look(vertical: Bool) -> WidgetFace { vertical ? resolvedSideFace : resolvedFace }
    func playerLook(vertical: Bool) -> PlayerLayout { vertical ? sidePlayerLayout : playerLayout }

    /// 帯でのタイルの大きさ。下置きは高さがアイコン、左右は幅がアイコンで、もう一方が内容で伸びる。
    func tileSize(icon: CGFloat, vertical: Bool) -> CGSize {
        if kind == .nowPlaying { return playerLook(vertical: vertical).size(icon: icon, vertical: vertical) }
        return WidgetSizing.size(face: look(vertical: vertical), sample: sampleText, icon: icon)
    }

    /// 実際に使う見え方。選べないものが入っていたら種類の既定に戻す。
    var resolvedFace: WidgetFace {
        let options = kind.availableFaces
        if let face, options.contains(face) { return face }
        // 古い設定：横長はグラフ、表示がリング／文字ならそれ、自動なら種類の既定。
        if shape == .wide, options.contains(.wideChart) { return .wideChart }
        if style == .ring, options.contains(.ring) { return .ring }
        if style == .text, options.contains(.text), kind.isNumeric { return .text }
        return options.contains(kind.defaultFace) ? kind.defaultFace : (options.first ?? .text)
    }

    /// 帯でのタイルの幅（アイコンの大きさから決める）。
    func tileWidth(icon: CGFloat) -> CGFloat { tileSize(icon: icon, vertical: false).width }

    /// 幅を見積もるための代表の文字（時刻は実際の書式で作る。数値は最大の桁）。
    var sampleText: String {
        switch kind {
        case .clock: return WidgetValues.clock(withSeconds: showSeconds, use24Hour: use24Hour, timeZoneID: timeZoneID)
        case .date:
            return WidgetValues.date(style: dateStyle, showTime: showTime, withSeconds: showSeconds,
                                     use24Hour: use24Hour, timeZoneID: timeZoneID)
        case .calendar: return "12:00 打ち合わせ"
        case .custom: return "000000"
        default: return "100%"
        }
    }

    /// 設定で変えられる更新頻度か（CPU・メモリ・推移・ライブラリだけ。他は種類ごとに固定で、設定に出さない）。
    var hasRefreshSetting: Bool {
        switch kind {
        case .cpu, .memory, .trend, .custom: return true
        default: return false
        }
    }

    /// 実際に使う更新間隔（秒）。時計・日付は表示が変わるので 1 秒、遅い問い合わせは長めに固定する。
    var effectiveInterval: Double {
        switch kind {
        case .clock, .date: return showSeconds ? 0.25 : 1   // 秒の境目で更新する（1 秒だと秒が飛んで見える）
        case .battery, .calendar: return 30
        case .disk: return 60
        case .volume, .microphone, .brightness: return 5
        case .nowPlaying: return 60   // 再生情報は別の経路（約 1.5 秒ごと）で読むので、文字の更新は不要
        case .cpu, .memory, .trend: return max(0.5, refreshInterval)
        case .clipboard: return 1     // 件数の表示だけ。履歴の取得は別の監視（0.5 秒ごとに変更回数を見る）で行う
        case .custom: return max(10, refreshInterval)
        }
    }

    /// 表示名（ライブラリの定義があればその名前）。
    var title: String {
        if kind == .custom {
            return WidgetLibrary.definition(id: libraryID)?.title ?? "ライブラリ"
        }
        return kind.title
    }

    /// 記号（ライブラリの定義があればその記号）。
    var symbol: String {
        if kind == .custom {
            return WidgetLibrary.definition(id: libraryID)?.symbol ?? "square.stack"
        }
        return kind.symbol
    }

    init(kind: WidgetKind) {
        self.kind = kind
    }

    /// この種類が持つ設定項目（設定画面を組み立てるのに使う）。
    var settings: Set<WidgetSetting> {
        switch kind {
        case .clock: return [.seconds, .use24Hour, .timeZone]
        case .date: return [.seconds, .use24Hour, .showTime, .dateStyle, .timeZone]
        case .calendar: return [.timeZone]
        case .trend: return [.shape]
        default: return []
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decode(WidgetKind.self, forKey: .kind)
        showSeconds = try c.decodeIfPresent(Bool.self, forKey: .showSeconds) ?? true
        use24Hour = try c.decodeIfPresent(Bool.self, forKey: .use24Hour) ?? true
        showTime = try c.decodeIfPresent(Bool.self, forKey: .showTime) ?? true
        dateStyle = try c.decodeIfPresent(Int.self, forKey: .dateStyle) ?? 0
        timeZoneID = try c.decodeIfPresent(String.self, forKey: .timeZoneID)
        refreshInterval = try c.decodeIfPresent(Double.self, forKey: .refreshInterval) ?? 3
        style = try c.decodeIfPresent(WidgetStyle.self, forKey: .style) ?? .automatic
        showLabel = try c.decodeIfPresent(Bool.self, forKey: .showLabel) ?? true
        tint = try c.decodeIfPresent(String.self, forKey: .tint) ?? "accent"
        libraryID = try c.decodeIfPresent(String.self, forKey: .libraryID)
        values = try c.decodeIfPresent([String: String].self, forKey: .values) ?? [:]
        shape = try c.decodeIfPresent(WidgetShape.self, forKey: .shape) ?? .square
        historyLength = try c.decodeIfPresent(Int.self, forKey: .historyLength) ?? 40
        playerLayout = try c.decodeIfPresent(PlayerLayout.self, forKey: .playerLayout) ?? .full
        face = try c.decodeIfPresent(WidgetFace.self, forKey: .face)
        sideFace = try c.decodeIfPresent(WidgetFace.self, forKey: .sideFace)
        sidePlayerLayout = try c.decodeIfPresent(PlayerLayout.self, forKey: .sidePlayerLayout) ?? .full
        pinnedDeviceUID = try c.decodeIfPresent(String.self, forKey: .pinnedDeviceUID)
        pinnedDeviceName = try c.decodeIfPresent(String.self, forKey: .pinnedDeviceName)
    }

    /// ライブラリの定義から作る。
    init(definition: WidgetDefinition) {
        kind = .custom
        libraryID = definition.id
        refreshInterval = definition.interval
        tint = definition.tint
        style = definition.isRing ? .ring : .automatic
        shape = definition.isChart ? .wide : .square
        face = definition.isChart ? .wideChart : (definition.isRing ? .ring : .text)
    }

    /// 選べる色。
    static let tints: [(id: String, name: String)] = [
        ("accent", "アクセント"),
        ("red", "赤"),
        ("orange", "オレンジ"),
        ("yellow", "黄"),
        ("green", "緑"),
        ("blue", "青"),
        ("purple", "紫"),
        ("pink", "ピンク"),
        ("gray", "グレー"),
    ]

    /// 選べる地域（システム設定＋よく使うもの）。
    static let timeZones: [(id: String?, name: String)] = [
        (nil, "システムの設定"),
        ("Asia/Tokyo", "東京"),
        ("UTC", "UTC"),
        ("Asia/Shanghai", "上海"),
        ("Asia/Singapore", "シンガポール"),
        ("Europe/London", "ロンドン"),
        ("Europe/Berlin", "ベルリン"),
        ("America/New_York", "ニューヨーク"),
        ("America/Los_Angeles", "ロサンゼルス"),
        ("Australia/Sydney", "シドニー"),
    ]
}

/// ウィジェットに出す値を OS から読む。
enum WidgetValues {
    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M/d(E)"
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    static func big(_ widget: Widget) -> String {
        switch widget.kind {
        case .clock:
            return clock(
                withSeconds: widget.showSeconds,
                use24Hour: widget.use24Hour,
                timeZoneID: widget.timeZoneID
            )
        case .date:
            return date(
                style: widget.dateStyle,
                showTime: widget.showTime,
                withSeconds: widget.showSeconds,
                use24Hour: widget.use24Hour,
                timeZoneID: widget.timeZoneID
            )
        case .custom:
            guard let def = WidgetLibrary.definition(id: widget.libraryID) else { return "—" }
            return WidgetLibrary.run(def, values: widget.values) ?? "—"
        case .volume, .microphone:
            return AudioReader.reading(for: widget).big
        case .brightness:
            return DisplayReader.reading(for: widget).big
        default:
            return big(widget.kind)
        }
    }

    /// リング・バーに使う 0...1 の割合（ウィジェット版）。音量・マイク・明るさは、固定した対象の値。
    static func fraction(_ widget: Widget) -> Double? {
        switch widget.kind {
        case .volume, .microphone: return AudioReader.reading(for: widget).fraction
        case .brightness: return DisplayReader.reading(for: widget).fraction
        default: return fraction(widget.kind)
        }
    }

    static func big(_ kind: WidgetKind, showSeconds: Bool = true, timeZoneID: String? = nil) -> String {
        switch kind {
        case .clock: return clock(withSeconds: showSeconds, timeZoneID: timeZoneID)
        case .date: return dateFormatter.string(from: Date())
        case .battery: return batteryPercent().map { "\($0)%" } ?? "—"
        case .memory: return memoryUsedPercent().map { "\($0)%" } ?? "—"
        case .cpu: return "\(CPULoad.percent())%"
        case .disk: return diskUsedPercent().map { "\($0)%" } ?? "—"
        case .calendar: return CalendarAccess.nextEventText() ?? "—"
        case .nowPlaying: return "—"
        case .volume, .microphone, .brightness: return "—"      // ウィジェット版（`big(_ widget:)`）で、固定したデバイスを見て読む
        case .trend: return "\(CPULoad.percent())%"
        case .clipboard: return "\(ClipboardCount.current)"
        case .custom: return "—"
        }
    }

    static func small(_ kind: WidgetKind) -> String {
        switch kind {
        case .clock: return "時計"
        case .date: return "日付"
        case .battery: return batteryPercent() == nil ? "電源" : "バッテリー"
        case .memory: return "メモリ"
        case .cpu: return "CPU"
        case .disk: return "ディスク"
        case .calendar: return "予定"
        case .nowPlaying: return "再生中"
        case .volume: return "音量"
        case .microphone: return "マイク"
        case .brightness: return "明るさ"
        case .trend: return "推移"
        case .clipboard: return "クリップボード"
        case .custom: return "ライブラリ"
        }
    }

    /// 時計の文字（秒の有無と地域を反映）。
    static func clock(withSeconds: Bool, use24Hour: Bool = true, timeZoneID: String?) -> String {
        let f = DateFormatter()
        if use24Hour {
            f.dateFormat = withSeconds ? "HH:mm:ss" : "HH:mm"
        } else {
            f.locale = Locale(identifier: "en_US")
            f.dateFormat = withSeconds ? "h:mm:ss a" : "h:mm a"
        }
        if let id = timeZoneID, let zone = TimeZone(identifier: id) {
            f.timeZone = zone
        }
        return f.string(from: Date())
    }

    /// 日付（好みの書き方＋任意で時刻）。
    static func date(
        style: Int,
        showTime: Bool,
        withSeconds: Bool,
        use24Hour: Bool,
        timeZoneID: String?
    ) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: use24Hour ? "ja_JP" : "en_US")
        let day: String
        switch style {
        case 1: day = "M月d日(E)"
        case 2: day = "yyyy/M/d(E)"
        default: day = "M/d(E)"
        }
        if showTime {
            let time = use24Hour
                ? (withSeconds ? "HH:mm:ss" : "HH:mm")
                : (withSeconds ? "h:mm:ss a" : "h:mm a")
            f.dateFormat = "\(day) \(time)"
        } else {
            f.dateFormat = day
        }
        if let id = timeZoneID, let zone = TimeZone(identifier: id) {
            f.timeZone = zone
        }
        return f.string(from: Date())
    }

    /// グラフに足す 1 点ぶんの値（0...100）。数値でないウィジェットは nil。
    static func sample(_ widget: Widget) -> Double? {
        switch widget.kind {
        case .custom:
            // chart 型はコマンドの出力がそのまま並びになるので、ここでは足さない。
            guard let def = WidgetLibrary.definition(id: widget.libraryID), !def.isChart else { return nil }
            return nil
        default:
            return fraction(widget.kind).map { min(100, max(0, $0 * 100)) }
        }
    }

    /// ライブラリの chart 型が返す並び（コマンドを実行する）。
    static func series(_ widget: Widget) -> [Double]? {
        guard widget.kind == .custom,
              let def = WidgetLibrary.definition(id: widget.libraryID),
              def.isChart,
              let output = WidgetLibrary.run(def, values: widget.values, fullOutput: true) else { return nil }
        let numbers = WidgetLibrary.parseSeries(output)
        return numbers.isEmpty ? nil : numbers
    }

    /// リング表示に使う 0...1 の割合。数値でないウィジェットは nil。
    static func fraction(_ kind: WidgetKind) -> Double? {
        switch kind {
        case .custom: return nil
        case .battery: return batteryPercent().map { Double($0) / 100 }
        case .memory: return memoryUsedPercent().map { Double($0) / 100 }
        case .cpu: return Double(CPULoad.percent()) / 100
        case .disk: return diskUsedPercent().map { Double($0) / 100 }
        case .trend: return Double(CPULoad.percent()) / 100
        default: return nil
        }
    }

    /// 詳細ポップアップ用の文。時計・日付は、押したときに日付と時刻の両方を出す（地域も反映）。
    static func detail(_ widget: Widget) -> String {
        switch widget.kind {
        case .clock, .date:
            let f = DateFormatter()
            f.locale = Locale(identifier: "ja_JP")
            f.dateStyle = .full
            f.timeStyle = .medium
            if let id = widget.timeZoneID, let zone = TimeZone(identifier: id) { f.timeZone = zone }
            return f.string(from: Date())
        case .volume, .microphone:
            return AudioReader.reading(for: widget).detail
        case .brightness:
            return DisplayReader.reading(for: widget).detail
        default:
            return detail(widget.kind)
        }
    }

    /// 詳細ポップアップ用の文（クリックしたときに出る）。
    static func detail(_ kind: WidgetKind) -> String {
        switch kind {
        case .clock: return DateFormatter.localizedString(from: Date(), dateStyle: .full, timeStyle: .none)
        case .date: return DateFormatter.localizedString(from: Date(), dateStyle: .full, timeStyle: .none)
        case .battery: return batteryPercent().map { "残量 \($0)%" } ?? "バッテリーなし（電源に接続）"
        case .memory: return memoryUsedPercent().map { "使用率 \($0)%" } ?? "読めませんでした"
        case .cpu: return "使用率 \(CPULoad.percent())%"
        case .disk: return diskUsedPercent().map { "起動ディスク \($0)% 使用" } ?? "読めませんでした"
        case .calendar: return CalendarAccess.nextEventText().map { "次の予定 \($0)" } ?? "今日の予定はありません"
        case .nowPlaying: return "再生中のもの"
        case .volume, .microphone, .brightness: return "読めませんでした"      // ウィジェット版（`detail(_ widget:)`）で読む
        case .trend: return "CPU 使用率の推移（直近 \(CPULoad.percent())%）"
        case .clipboard: return "コピーした履歴 \(ClipboardCount.current) 件"
        case .custom: return "外部ライブラリのウィジェット"
        }
    }

    /// バッテリー残量（%）。デスクトップなど電源が無ければ nil。
    private static func batteryPercent() -> Int? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue()
                    as? [String: Any],
                  let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return Int((Double(current) / Double(max) * 100).rounded())
        }
        return nil
    }

    /// メモリ使用率（%）。
    private static func memoryUsedPercent() -> Int? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let pageSize = UInt64(vm_kernel_page_size)
        let used = (UInt64(stats.active_count) + UInt64(stats.wire_count)
                    + UInt64(stats.compressor_page_count)) * pageSize
        let total = ProcessInfo.processInfo.physicalMemory
        guard total > 0 else { return nil }
        return Int((Double(used) / Double(total) * 100).rounded())
    }

    /// 起動ディスクの使用率（%）。
    private static func diskUsedPercent() -> Int? {
        let url = URL(fileURLWithPath: "/")
        guard let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]),
              let total = values.volumeTotalCapacity, total > 0,
              let free = values.volumeAvailableCapacity else { return nil }
        return Int((Double(total - free) / Double(total) * 100).rounded())
    }
}

/// 全 CPU の使用率。前回との差分で出す。
enum CPULoad {
    private static var previous: (idle: UInt64, total: UInt64)?

    static func percent() -> Int {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }

        let user = UInt64(info.cpu_ticks.0)
        let system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)
        let total = user + system + idle + nice

        defer { previous = (idle, total) }
        guard let last = previous, total > last.total else { return 0 }
        let idleDelta = Double(idle - last.idle)
        let totalDelta = Double(total - last.total)
        guard totalDelta > 0 else { return 0 }
        return Int(((totalDelta - idleDelta) / totalDelta * 100).rounded())
    }
}

/// カレンダーの次の予定（今日ぶん）。
enum CalendarAccess {
    private static let store = EKEventStore()
    private static var requested = false

    static func nextEventText() -> String? {
        if !requested {
            requested = true
            store.requestFullAccessToEvents { _, _ in }
        }
        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: 1, to: now) ?? now
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        guard let event = store.events(matching: predicate).first else { return nil }
        let start = event.startDate ?? now
        return WidgetValues.timeString(start)
    }
}

extension WidgetValues {
    static func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}

/// 音量。osascript は重いので数秒キャッシュする。
enum MediaAccess {
    private static var volumeCache: (value: Int?, at: Date)?
    private static let ttl: TimeInterval = 4

    /// 出力音量（%）。
    static func volume() -> Int? {
        if let cache = volumeCache, Date().timeIntervalSince(cache.at) < ttl { return cache.value }
        var value: Int?
        if let out = runAppleScript("output volume of (get volume settings)"),
           let number = Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) {
            value = number
        }
        volumeCache = (value, Date())
        return value
    }

    private static func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if error != nil { return nil }
        let text = result.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty ?? true) ? nil : text
    }
}

/// 裏で作っておくウィジェットの文。
struct WidgetText: Equatable {
    var big: String
    var small: String
    var detail: String
    /// リング表示の割合。描画のたびに OS へ問い合わせないよう、裏で作っておく。
    var fraction: Double?
}

/// ウィジェットの幅（純粋関数）。描画結果は読まず、見え方と代表の文字から見積もる。
enum WidgetSizing {
    /// 文字の幅の見積もり（等幅数字のおよその幅。全角は 2 文字分）。
    static func textWidth(_ text: String, fontSize: CGFloat) -> CGFloat {
        let units = text.unicodeScalars.reduce(0.0) { $0 + ($1.isASCII ? 0.62 : 1.0) }
        return CGFloat(units) * fontSize
    }

    /// タイルの大きさ。縦長の見え方は幅がアイコンで高さが伸び、それ以外は高さがアイコンで幅が伸びる。
    static func size(face: WidgetFace, sample: String, icon: CGFloat) -> CGSize {
        face.isTall
            ? CGSize(width: icon, height: height(face: face, sample: sample, icon: icon))
            : CGSize(width: width(face: face, sample: sample, icon: icon), height: icon)
    }

    /// 縦長の見え方の高さ（記号＋行ごとの文字、バーは 2 マス分）。
    static func height(face: WidgetFace, sample: String, icon: CGFloat) -> CGFloat {
        switch face {
        case .tallText:
            let lines = CGFloat(TallText.lines(sample).count)
            return max(icon * 1.3, lines * icon * 0.30 + icon * 0.30 + 12).rounded(.up)
        case .tallBar: return (icon * 2).rounded(.up)
        default: return icon
        }
    }

    static func width(face: WidgetFace, sample: String, icon: CGFloat) -> CGFloat {
        switch face {
        case .ring, .text, .tallText, .tallBar: return icon
        case .wideText:
            // 記号の分（icon×0.36）＋余白（16）＋文字。正方形より狭くはしない。
            return max(icon * 1.4, textWidth(sample, fontSize: icon * 0.30) + icon * 0.36 + 16).rounded(.up)
        case .wideBar: return max(icon * 2.0, textWidth(sample, fontSize: icon * 0.30) + 24).rounded(.up)
        case .wideChart: return (icon * 2.6).rounded(.up)
        }
    }
}

/// 縦長の文字の行分け（純粋関数）。空白で行を分け、秒まである時刻は「時:分」と「:秒」に分ける。
enum TallText {
    static func lines(_ text: String) -> [String] {
        var out: [String] = []
        for part in text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init) {
            if part.filter({ $0 == ":" }).count == 2, let last = part.lastIndex(of: ":") {
                out.append(String(part[..<last]))
                out.append(String(part[last...]))
            } else {
                out.append(part)
            }
        }
        return out.isEmpty ? [text] : out
    }
}
