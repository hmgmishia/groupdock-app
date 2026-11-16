import AppKit
import ApplicationServices
import Combine

/// ドラッグ中に重なっているタイル（ハイライト用）。見た目だけの状態。
final class DropState: ObservableObject {
    struct Insertion: Equatable { var id: String; var after: Bool }
    @Published var targetID: String?
    /// ドラッグ中のアプリを入れる位置（周りが退くプレビューに使う）。
    var insertion: Insertion?
    var dragging = false
    /// グループの吹き出しのスクロール量（見た目だけの状態）。
    @Published var bubbleScroll: CGFloat = 0
}

/// アイコンの入れ物。パスごとに更新日時を覚え、変わったときだけ読み直す。
/// 毎回 OS に聞くと重いので、確認は `checkInterval` 秒に 1 回までにする。判定の関数は差し替えられる（テスト用）。
enum IconCache {
    struct Entry { var image: NSImage; var stamp: Date?; var checkedAt: Date }

    static var entries: [String: Entry] = [:]
    static let checkInterval: TimeInterval = 3

    /// バンドルの更新日時。アプリの更新で変わる（バンドル本体と Info.plist の新しい方）。
    static func bundleStamp(_ path: String) -> Date? {
        let manager = FileManager.default
        let dates = [path, path + "/Contents/Info.plist", path + "/Contents/Resources"].compactMap {
            (try? manager.attributesOfItem(atPath: $0))?[.modificationDate] as? Date
        }
        return dates.max()
    }

    static func image(
        for path: String,
        now: Date = Date(),
        stamp: (String) -> Date? = IconCache.bundleStamp,
        load: (String) -> NSImage = { NSWorkspace.shared.icon(forFile: $0) }
    ) -> NSImage {
        if var entry = entries[path] {
            guard now.timeIntervalSince(entry.checkedAt) >= checkInterval else { return entry.image }
            entry.checkedAt = now
            let current = stamp(path)
            if current != entry.stamp {
                entry.image = load(path)
                entry.stamp = current
            }
            entries[path] = entry
            return entry.image
        }
        let image = load(path)
        entries[path] = Entry(image: image, stamp: stamp(path), checkedAt: now)
        return image
    }

    /// 覚えているアイコンのうち、更新されたものがあるか（あれば読み直す）。画面の描き直しの合図に使う。
    static func refreshChanged(
        now: Date = Date(),
        stamp: (String) -> Date? = IconCache.bundleStamp,
        load: (String) -> NSImage = { NSWorkspace.shared.icon(forFile: $0) }
    ) -> Bool {
        var changed = false
        for (path, var entry) in entries {
            let current = stamp(path)
            entry.checkedAt = now
            if current != entry.stamp {
                entry.image = load(path)
                entry.stamp = current
                changed = true
            }
            entries[path] = entry
        }
        return changed
    }
}

/// 1 つのアプリ（.app バンドルのパスだけを持つ）。
struct AppRef: Codable, Identifiable, Hashable {
    var path: String
    /// 起動するときの引数（Unity のプロジェクトのように、同じアプリを別の引数で使うため）。
    var arguments: String = ""
    /// 終了しても帯に残す（標準 Dock のピン留めと同じ）。false なら終了時に外れる。
    var keepWhenQuit: Bool = true

    /// 標準で必ず置いておくアプリ（外せない）。
    static let pinnedPaths = [
        "/System/Library/CoreServices/Finder.app",
        "/System/Applications/Apps.app",
    ]

    /// 同じアプリでも引数が違えば別の項目として扱う。
    var id: String { arguments.isEmpty ? path : path + "\u{1}" + arguments }
    var isPinned: Bool { AppRef.pinnedPaths.contains(path) }

    /// 引数を配列にしたもの（空白区切り）。
    var argumentList: [String] {
        arguments.split(separator: " ").map(String.init).filter { !$0.isEmpty }
    }
    var name: String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension }

    // Bundle とアイコンは毎回作ると重いので、パスごとに一度だけ読む。
    private static var bundleIDs: [String: String?] = [:]

    var bundleID: String? {
        if let cached = AppRef.bundleIDs[path] { return cached }
        let id = Bundle(path: path)?.bundleIdentifier
        AppRef.bundleIDs[path] = id
        return id
    }

    /// アイコン。アプリが更新されたら（バンドルの更新日時が変わったら）読み直す。
    var icon: NSImage { IconCache.image(for: path) }

    init(path: String, arguments: String = "", keepWhenQuit: Bool = true) {
        self.path = path
        self.arguments = arguments
        self.keepWhenQuit = keepWhenQuit
    }

    // 古い groups.json（keepWhenQuit が無い）でも既定値で読めるようにする。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        arguments = try c.decodeIfPresent(String.self, forKey: .arguments) ?? ""
        keepWhenQuit = try c.decodeIfPresent(Bool.self, forKey: .keepWhenQuit) ?? true
    }
}

/// 名前付きのアプリの集まり。
struct Group: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var apps: [AppRef] = []
}

/// グループの中の並べ替え（純粋関数）。
enum GroupOrder {
    /// `index` の項目を `offset`（-1 で前、+1 で後ろ）だけ動かす。端を越えるときは動かさない。
    static func move(_ apps: [AppRef], index: Int, by offset: Int) -> [AppRef] {
        let target = index + offset
        guard apps.indices.contains(index), apps.indices.contains(target) else { return apps }
        var list = apps
        list.swapAt(index, target)
        return list
    }

    /// 名前順（大文字小文字・かなの違いを無視）。同じ名前は引数で並べる。
    static func byName(_ apps: [AppRef]) -> [AppRef] {
        apps.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.arguments < $1.arguments : order == .orderedAscending
        }
    }
}

extension Notification.Name {
    /// グループの設定を開く（object = グループの UUID）。
    static let groupDockOpenGroupSettings = Notification.Name("GroupDockOpenGroupSettings")
    /// GroupDock がアプリを起動したとき（userInfo["ref"] = AppRef）。
    static let groupDockLaunch = Notification.Name("GroupDockLaunch")
}

/// 履歴の並び（純粋関数）。同じ（パス＋引数）は 1 件、新しいものが先頭、件数は上限まで。
enum HistoryList {
    static let limit = 20

    static func adding(_ ref: AppRef, to list: [AppRef], limit: Int = HistoryList.limit) -> [AppRef] {
        var next = list.filter { $0.id != ref.id }
        next.insert(ref, at: 0)
        return Array(next.prefix(limit))
    }
}

/// hover と右クリックに出す情報（純粋関数）。
enum HistoryInfo {
    static func text(_ ref: AppRef) -> String {
        var lines = [ref.name, ref.path]
        lines.append(ref.arguments.isEmpty ? "引数: なし" : "引数: \(ref.arguments)")
        return lines.joined(separator: "\n")
    }
}

/// 読めない要素（廃止した種類など）は nil にして飛ばす。
struct LossyWidget: Decodable {
    let value: Widget?
    init(from decoder: Decoder) throws { value = try? Widget(from: decoder) }
}

/// 帯の見た目と動作の設定。settings.json に保存する。
struct Prefs: Codable, Equatable {
    /// タイル 1 つの一辺（ポイント）。
    var iconSize: Double = 52
    /// マウスが離れたら画面の下へ引っ込む（標準 ON）。
    var autoHide: Bool = true
    /// macOS の Dock を隠す（標準 ON。オフに戻すと元の設定に戻る）。
    var hideSystemDock: Bool = true
    /// アイコンの間隔。帯の中も、グループの中（履歴・インスタンス選択を含む）も、この 1 つの値を共有する。
    var gap: Double = 10
    /// アイコンの下に名前を出す（基本はオフ）。
    var showNames: Bool = false
    /// 帯に置くウィジェット。
    var widgets: [Widget] = []
    /// 起動したアプリを帯に自動で追加する（標準 ON）。
    var autoAddLaunched: Bool = true
    /// 自動で追加したアプリを、終了後も帯に残す（標準 OFF＝標準 Dock と同じ）。
    var keepLaunched: Bool = false
    /// 帯の位置（bottom / left / right）。
    var position: String = "bottom"
    /// すべてのディスプレイに帯を出す（標準はメイン画面だけ）。
    var allDisplays: Bool = false
    /// コマンドの実行を許可したウィジェット定義の ID。ここに無いものはコマンドを実行しない（ウィジェットごとに許可）。
    var approvedWidgets: [String] = []
    /// 通信の使用を許可したウィジェット定義の ID。ここに無いものは通信を拒否する（標準は拒否）。
    var networkWidgets: [String] = []
    /// 要素が画面に収まらないときの方式。pages＝ページを切り替える（FF14 のホットバーのように、大きさを保つ。既定）／shrink＝アイコンを縮める（標準 Dock と同じ）。
    /// 既定を pages にした理由：縮める方式は、収まらないほど多いと、スライダーを動かしても同じ大きさに縮み続け、変えても変わらなく見えるため。
    var overflow: String = "pages"
    /// ページ切り替えで、縦に並べる数（左右置きは列の数、下置きは段の数）。既定 1。ページに関係なく一定。
    var stripLines: Int = 1
    /// Finder をクリックしたとき、毎回新しいウィンドウを開くか。false（既定）なら、開いているウィンドウを前面に出す。Finder の右クリックで切り替える。
    var finderNewWindow: Bool = false
    /// 並べる数は 1〜6 に収める。
    static func clampLines(_ value: Int) -> Int { max(1, min(6, value)) }

    init() {}

    // 古い settings.json（一部のキーしか無い）でも既定値で埋まるようにする。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Prefs()
        iconSize = try c.decodeIfPresent(Double.self, forKey: .iconSize) ?? d.iconSize
        autoHide = try c.decodeIfPresent(Bool.self, forKey: .autoHide) ?? d.autoHide
        hideSystemDock = try c.decodeIfPresent(Bool.self, forKey: .hideSystemDock) ?? d.hideSystemDock
        gap = try c.decodeIfPresent(Double.self, forKey: .gap) ?? d.gap
        // 廃止した種類（再生中など）が残っていても、他の設定を巻き込まずに読み飛ばす。
        widgets = (try c.decodeIfPresent([LossyWidget].self, forKey: .widgets))?.compactMap(\.value) ?? d.widgets
        showNames = try c.decodeIfPresent(Bool.self, forKey: .showNames) ?? d.showNames
        autoAddLaunched = try c.decodeIfPresent(Bool.self, forKey: .autoAddLaunched) ?? d.autoAddLaunched
        keepLaunched = try c.decodeIfPresent(Bool.self, forKey: .keepLaunched) ?? d.keepLaunched
        position = try c.decodeIfPresent(String.self, forKey: .position) ?? d.position
        allDisplays = try c.decodeIfPresent(Bool.self, forKey: .allDisplays) ?? d.allDisplays
        approvedWidgets = try c.decodeIfPresent([String].self, forKey: .approvedWidgets) ?? d.approvedWidgets
        networkWidgets = try c.decodeIfPresent([String].self, forKey: .networkWidgets) ?? d.networkWidgets
        overflow = try c.decodeIfPresent(String.self, forKey: .overflow) ?? d.overflow
        stripLines = Prefs.clampLines(try c.decodeIfPresent(Int.self, forKey: .stripLines) ?? d.stripLines)
        finderNewWindow = try c.decodeIfPresent(Bool.self, forKey: .finderNewWindow) ?? d.finderNewWindow
    }
}

/// groups.json の読み書きと、実行状態を描き直すための拍。
final class Store: ObservableObject {
    @Published var groups: [Group] {
        didSet { if !loading { save() } }
    }
    @Published var prefs: Prefs {
        didSet {
            FinderOpen.newWindow = prefs.finderNewWindow
            if !loading {
                schedulePrefsSave()
                applyWidgetPolicy()
                restartWidgetTimer()
                syncClipboardWatcher()
            }
        }
    }
    /// Dock に残すアプリ（標準 Dock のピン留め相当）。グループとは別の並び。
    @Published var kept: [AppRef] = [] {
        didSet { if !loading { saveKept() } }
    }
    /// 実行中のアプリ（キャッシュ。3 秒ごとと起動・終了の通知で更新）。
    @Published private(set) var running: [AppRef] = []
    /// 実行中アプリの bundle id。アイコンの点を引くのに使う。
    @Published private(set) var runningBundleIDs: Set<String> = []
    /// 実行中のインスタンス数（アプリのパス → 数）。引数が違っても同じアプリの別インスタンスとして数える。
    @Published private(set) var instanceCounts: [String: Int] = [:]
    /// アイコンが更新されたら増える（画面の描き直しの合図）。
    @Published private(set) var iconVersion = 0
    /// 応答していないアプリのパス（「終了」を「強制終了」にする）。
    @Published private(set) var hungPaths: Set<String> = []
    /// アプリごとのウィンドウ数（パス → 数）。インスタンスの選択に使う。
    @Published private(set) var windowCounts: [String: Int] = [:]
    private let responsivenessQueue = DispatchQueue(label: "GroupDock.responsiveness", qos: .utility)
    private var responsivenessInFlight = false
    /// 標準 Dock の未読バッジ（アプリのパス → 表示する文字）。
    @Published private(set) var badges: [String: String] = [:]
    /// ウィジェットに出す文（重い処理は 3 秒ごとに裏で作る）。
    @Published private(set) var widgetText: [UUID: WidgetText] = [:]
    /// 外部ウィジェット定義の版（変わったら描き直す）。
    @Published private(set) var libraryVersion = 0
    /// 横長グラフ用の履歴（ウィジェット ID → 値の並び）。
    @Published private(set) var widgetHistory: [UUID: [Double]] = [:]
    /// 帯の中で開いているグループ（フォルダ）の ID。
    @Published var expanded: Group.ID?
    /// 本人が明示的に外したアプリ（実行中の一覧にも出さない。終了するまで覚えておく）。
    @Published var hiddenRunning: Set<String> = [] {
        didSet { if !loading { saveHidden() } }
    }
    /// ドラッグ中のハイライトは別の入れ物に分ける（Store の更新で全タイルを描き直さないため）。
    let dropState = DropState()
    /// アイコンをドラッグ中か。ドラッグ中は、空け分をウィンドウに確保して大きさを固定する。
    var dragging: Bool {
        get { dropState.dragging }
        set {
            guard dropState.dragging != newValue else { return }
            dropState.dragging = newValue
            objectWillChange.send()
        }
    }
    /// 入れる位置が変わったときだけ、帯と吹き出しを組み直す（マウスの動きごとには描き直さない）。
    var insertion: DropState.Insertion? {
        get { dropState.insertion }
        set {
            guard dropState.insertion != newValue else { return }
            dropState.insertion = newValue
            objectWillChange.send()
        }
    }
    var dropTargetID: String? {
        get { dropState.targetID }
        set { if dropState.targetID != newValue { dropState.targetID = newValue } }
    }
    /// 帯の自動縮小の結果（入力が変わらない間は使い回す。描画のたび・タイルごとに作り直すと固まる）。
    var fitCache: (input: StripFitInput, result: (icon: CGFloat, entries: [StripEntry]))?
    /// ページ切り替え方式での、区画ごとのいまのページ（0 始まり。保存しない＝起動時は先頭）。範囲外は、使うときに収める。
    @Published var stripPages: [StripSection: Int] = [:]

    /// ページを送る（ページ切り替え方式）。
    func setPage(_ section: StripSection, _ page: Int) {
        guard stripPages[section] != page else { return }
        stripPages[section] = page
    }

    /// 再生中ウィジェットの状態。Store とは別の入れ物（毎回の更新で帯全体を描き直さない）。
    let nowPlaying = NowPlayingState()
    var nowPlayingBusy = false
    var lastNowPlayingPoll = Date.distantPast
    private var runningTick = 0
    let nowPlayingQueue = DispatchQueue(label: "GroupDock.nowplaying", qos: .userInitiated)
    let nowPlayingFetcher = NowPlayingFetcher()
    /// クリップボード履歴。ウィジェットを置いている間だけ作る（作るとキーチェーンの鍵を読むので、使わないときは触れない）。
    private(set) lazy var clipboard = ClipboardStore()
    private var clipboardCreated = false

    /// クリップボードのウィジェットがあれば監視を始め、無ければ止める（使わない機能の費用ゼロ）。
    /// 固定したデバイス（音量・マイク）の既定を保つ仕組み。固定が無ければ、何も見ない。
    let audioPins = AudioPinEnforcer()

    func syncClipboardWatcher() {
        audioPins.update(widgets: prefs.widgets)
        let wanted = prefs.widgets.contains { $0.kind == .clipboard }
        if wanted {
            clipboardCreated = true
            if !clipboard.isRunning { clipboard.start() }
        } else if clipboardCreated, clipboard.isRunning {
            clipboard.stop()
        }
    }

    /// 監視中か（作っていなければ false。確認のために履歴を作らない）。
    var clipboardIsRunning: Bool { clipboardCreated && clipboard.isRunning }

    /// 最近起動したアプリ（新しい順・20 件まで）。
    @Published private(set) var history: [AppRef] = Store.loadHistory()
    /// 帯が自動で隠れている間は true。見えないウィジェットと再生の更新を止める。出るときにすぐ更新する。
    var stripHidden = false {
        didSet {
            guard oldValue != stripHidden else { return }
            restartWidgetTimer()
            if !stripHidden {
                widgetUpdatedAt.removeAll()
                lastNowPlayingPoll = .distantPast
                refreshWidgetText()
                refreshNowPlaying()
            }
        }
    }
    private var runningLoaded = false
    private var runningFirstSeen: [String: Date] = [:]
    private var loading = true
    private var timer: Timer?
    private var widgetTimer: Timer?
    private var libraryTimer: Timer?
    private var badgeTimer: Timer?
    private let badgeQueue = DispatchQueue(label: "GroupDock.badges", qos: .utility)
    private var badgeInFlight = false
    private let widgetQueue = DispatchQueue(label: "GroupDock.widgets", qos: .utility)
    private var widgetTextInFlight = false
    private var lastWidgetRefresh = Date.distantPast
    private var widgetUpdatedAt: [UUID: Date] = [:]
    /// 設定の保存はドラッグ中に毎回書かず、少し待ってからまとめて書く。
    private var prefsSaveWork: DispatchWorkItem?
    /// 保存の失敗を、保存先ごとに数える（続けて失敗したときだけ、利用者に知らせる）。
    private var saveFailures = SaveFailureTracker()

    /// 保存先のフォルダ。テストでは差し替え、実データに触れない（`ClipboardStore.directoryOverride` と同じ形）。
    /// 差し替えは `Store()` を作る前に行う。
    nonisolated(unsafe) static var directoryOverride: URL?

    static var directory: URL {
        if let directoryOverride { return directoryOverride }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("GroupDock", isDirectory: true)
    }

    static var fileURL: URL { directory.appendingPathComponent("groups.json") }
    static var prefsURL: URL { directory.appendingPathComponent("settings.json") }
    static var keptURL: URL { directory.appendingPathComponent("kept.json") }
    static var historyURL: URL { directory.appendingPathComponent("history.json") }
    static var hiddenURL: URL { directory.appendingPathComponent("hidden.json") }

    /// 設定から、ウィジェットの実行許可を組み立て直す。
    /// ウィジェットの判定タイマーを、いまのウィジェットに合う間隔で張り直す（間隔が変わるときだけ）。
    private func restartWidgetTimer() {
        let interval = PollPolicy.widgetTimerInterval(prefs.widgets, hidden: stripHidden)
        if let current = widgetTimer, abs(current.timeInterval - interval) < 0.001 { return }
        widgetTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.refreshNowPlaying()
            self?.refreshWidgetText()
        }
        RunLoop.main.add(timer, forMode: .common)
        widgetTimer = timer
    }

    func applyWidgetPolicy() {
        WidgetLibrary.policy = WidgetPolicy(
            approved: Set(prefs.approvedWidgets),
            networkApproved: Set(prefs.networkWidgets)
        )
    }

    /// 取り込みを承認する（コマンド実行を許す）。
    func approveWidget(id: String) {
        if !prefs.approvedWidgets.contains(id) {
            prefs.approvedWidgets.append(id)
        }
        applyWidgetPolicy()
    }

    /// 通信の使用を許可する／やめる（そのウィジェットだけ）。
    func setWidgetNetwork(id: String, allowed: Bool) {
        prefs.networkWidgets.removeAll { $0 == id }
        if allowed { prefs.networkWidgets.append(id) }
        applyWidgetPolicy()
        widgetUpdatedAt.removeAll()
        refreshWidgetText()
    }

    /// 承認を取り消す（以後そのウィジェットのコマンドは実行しない。通信の許可も外す）。
    func revokeWidget(id: String) {
        prefs.approvedWidgets.removeAll { $0 == id }
        prefs.networkWidgets.removeAll { $0 == id }
        applyWidgetPolicy()
        widgetUpdatedAt.removeAll()
        refreshWidgetText()
    }

    init() {
        // 外部ウィジェット定義を先に読む。
        WidgetLibrary.reload()
        groups = Store.load()
        prefs = Store.loadPrefs()
        FinderOpen.newWindow = prefs.finderNewWindow
        loading = false
        // 初回起動では取り込んだ内容をそのまま保存しておく（init 中は didSet が走らない）。
        if !FileManager.default.fileExists(atPath: Store.fileURL.path) {
            save()
        }
        kept = Store.loadKept()
        // 古いデータの「残さない」印は、区分け（残す／残さない）に置き換えたので、残す側は全部オンにそろえる。
        kept = kept.map { var ref = $0; ref.keepWhenQuit = true; return ref }
        for g in groups.indices {
            for a in groups[g].apps.indices { groups[g].apps[a].keepWhenQuit = true }
        }
        hiddenRunning = Store.loadHidden()
        // 定義の監視は、保存の読み込みが終わってから始める。
        applyWidgetPolicy()
        syncClipboardWatcher()
        startWatchingWidgetLibrary()
        // GroupDock から起動したアプリ（引数つきを含む）を履歴に残す。
        NotificationCenter.default.addObserver(forName: .groupDockLaunch, object: nil, queue: .main) { [weak self] note in
            if let ref = note.userInfo?["ref"] as? AppRef { self?.recordHistory([ref], explicit: true) }
        }
        separatePinnedApps()

        // 実行中アプリは 3 秒ごとに読み直す（毎秒だと Bundle 走査で重い）。
        refreshRunning()
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            self?.refreshRunning()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // 起動・終了・スリープ復帰で即座に更新する。
        let center = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
        ] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshRunning()
                self?.checkResponsiveness()      // ウィンドウ数（青丸）もすぐ数え直す
            }
        }
        // 前面のアプリが変わったとき（新しいウィンドウを開いた直後など）も、ウィンドウ数を数え直す。
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.checkResponsiveness()
        }

        // ウィジェットの値は 3 秒ごと、裏のスレッドで作る（予定や音量は特に重い）。
        refreshWidgetText()
        // 秒まで出す時計・日付があるときだけ 0.25 秒ごと。無ければ 1 秒（更新は種類ごとの間隔で絞る）。
        restartWidgetTimer()

        // 標準 Dock の未読バッジは 5 秒ごとに裏で読む（Dock のアクセシビリティ経由）。
        refreshBadges()
        let badgeTimer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            self?.refreshBadges()
        }
        RunLoop.main.add(badgeTimer, forMode: .common)
        self.badgeTimer = badgeTimer
    }

    /// Dock に出ている未読バッジを読み直す。AX の問い合わせは裏のスレッドで行う。
    private static var askedAccessibility = false

    private func refreshBadges() {
        // 通知バッジは Dock のアクセシビリティから読む。許可が無いと何も出ないので、一度だけ許可を求める。
        if !AXIsProcessTrusted(), !Store.askedAccessibility {
            Store.askedAccessibility = true
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
        guard !badgeInFlight else { return }
        badgeInFlight = true
        badgeQueue.async { [weak self] in
            let next = BadgeReader.read()
            DispatchQueue.main.async {
                guard let self else { return }
                self.badgeInFlight = false
                if next != self.badges { self.badges = next }
            }
        }
    }

    /// 実行中アプリの一覧を作り直す。UI スレッドで 3 秒に 1 回だけ走る。
    private func refreshRunning() {
        let own = Bundle.main.bundlePath
        var seen = Set<String>()
        var refs: [AppRef] = []
        var ids = Set<String>()
        var allPaths: [String] = []
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && !app.isTerminated {
            guard let url = app.bundleURL?.resolvingSymlinksInPath(), url.path != own else { continue }
            allPaths.append(url.path)
            guard seen.insert(url.path).inserted else { continue }
            refs.append(AppRef(path: url.path))
        }
        // 緑丸は「通常のアプリ」に限らず、動いていれば出す（Unity のように通常のアプリ扱いにならないものがある）。
        ids = RunningMatch.bundleIDs(NSWorkspace.shared.runningApplications.map {
            RunningMatch.Entry(id: $0.bundleIdentifier, terminated: $0.isTerminated, isSelf: $0.bundleURL?.path == own)
        })
        // 起動してすぐ終わる一時的なアプリは、2 秒続くまで「実行中」の枠にも履歴にも出さない（緑丸は出す）。
        let now = Date()
        let currentPaths = refs.map(\.path)
        runningFirstSeen = RunningSettle.update(runningFirstSeen, current: currentPaths, now: now)
        let settled = Set(RunningSettle.settled(runningFirstSeen, current: currentPaths, now: now))
        refs = refs.filter { settled.contains($0.path) }
        if RunningSettle.hasPending(runningFirstSeen, current: currentPaths, now: now) {
            DispatchQueue.main.asyncAfter(deadline: .now() + RunningSettle.settleTime + 0.1) { [weak self] in
                self?.refreshRunning()
            }
        }
        if refs.map(\.path) != running.map(\.path) {
            // 最初の読み込みは履歴に入れない（すでに動いていたアプリ）。
            if runningLoaded {
                let before = Set(running.map(\.path))
                recordHistory(refs.filter { !before.contains($0.path) }, explicit: false)
            }
            runningLoaded = true
            running = refs
        }
        if ids != runningBundleIDs { runningBundleIDs = ids }
        let counts = AppInstances.counts(paths: allPaths)
        if counts != instanceCounts { instanceCounts = counts }
        // アイコンの更新（30 秒に 1 回）と応答・ウィンドウ数の確認（6 秒に 1 回）は、毎回はやらない。
        runningTick &+= 1
        if PollPolicy.checksIcons(tick: runningTick), IconCache.refreshChanged() { iconVersion += 1 }
        if PollPolicy.checksResponsiveness(tick: runningTick, hidden: stripHidden) { checkResponsiveness() }
    }

    /// 置いてあるウィジェットの文を、ウィジェットごとの更新頻度に合わせて作り直す。
    /// ウィジェットの値を、次の周期を待たずにすぐ読み直す（ホイール調整のあと、ゲージを即座に動かす）。
    func refreshWidgetsNow() {
        widgetUpdatedAt = [:]
        refreshWidgetText()
    }

    private func refreshWidgetText() {
        let widgets = prefs.widgets
        guard !widgets.isEmpty else {
            if !widgetText.isEmpty { widgetText = [:] }
            if !widgetUpdatedAt.isEmpty { widgetUpdatedAt = [:] }
            return
        }
        guard !stripHidden, !widgetTextInFlight else { return }

        let now = Date()
        let due = widgets.filter { widget in
            let last = widgetUpdatedAt[widget.id] ?? .distantPast
            return now.timeIntervalSince(last) >= widget.effectiveInterval
        }
        guard !due.isEmpty else { return }

        widgetTextInFlight = true
        let previous = widgetText
        widgetQueue.async { [weak self] in
            guard let self else { return }
            var next = previous
            for widget in due {
                next[widget.id] = WidgetText(
                    big: WidgetValues.big(widget),
                    small: widget.kind == .custom ? widget.title : WidgetValues.small(widget.kind),
                    detail: WidgetValues.detail(widget),
                    fraction: WidgetValues.fraction(widget)
                )
            }
            // グラフ用の値を集める（数値系は 1 点足す、chart 型は並びを置き換える）。
            var samples: [UUID: [Double]] = [:]
            for widget in due {
                if let series = WidgetValues.series(widget) {
                    samples[widget.id] = Array(series.suffix(max(2, widget.historyLength)))
                } else if let point = WidgetValues.sample(widget) {
                    samples[widget.id] = [point]
                }
            }

            let stamp = Date()
            DispatchQueue.main.async {
                self.widgetTextInFlight = false
                for widget in due { self.widgetUpdatedAt[widget.id] = stamp }
                if next != self.widgetText { self.widgetText = next }
                for (id, points) in samples {
                    self.appendHistory(id: id, points: points)
                }
            }
        }
    }

    /// Widgets フォルダを見張る。ファイルを置いた / 消したら、その場で読み直す
    /// （アプリの再ビルド・再起動は要らない）。
    private func startWatchingWidgetLibrary() {
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if WidgetLibrary.reloadIfChanged() {
                DispatchQueue.main.async {
                    self.libraryVersion &+= 1
                    self.widgetUpdatedAt.removeAll()   // 次の周期ですぐ値を作り直す
                    self.refreshWidgetText()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        libraryTimer = timer

        // 定義の変更はビューの更新中に届くことがある。その場で @Published を
        // 書き換えると AttributeGraph が落ちるので、次のループで反映する。
        WidgetLibrary.onChange = { [weak self] in
            DispatchQueue.main.async {
                self?.libraryVersion &+= 1
            }
        }
    }

    /// ウィジェットを取り込む（`.json` / `.groupwidget`）。取り込んだらすぐ使える。
    @discardableResult
    func importWidget(at url: URL) -> String? {
        do {
            let def = try WidgetLibrary.importItem(at: url)
            // 取り込んだものは、その場でコマンド実行を承認する（内容は確認済み）。
            approveWidget(id: def.id)
            libraryVersion &+= 1
            // 取り込んだウィジェットを帯に足す（定義そのものが使える状態になる）。
            if !prefs.widgets.contains(where: { $0.libraryID == def.id }) {
                prefs.widgets.append(Widget(definition: def))
            }
            widgetUpdatedAt.removeAll()
            refreshWidgetText()
            return nil
        } catch {
            NSLog("GroupDock: widget import failed: \(error.localizedDescription)")
            return error.localizedDescription
        }
    }

    /// 履歴を足す（数値系は 1 点、chart 型は並びをそのまま）。
    private func appendHistory(id: UUID, points: [Double]) {
        guard let widget = prefs.widgets.first(where: { $0.id == id }) else { return }
        let limit = max(2, widget.historyLength)
        var list = widgetHistory[id] ?? []
        if points.count > 1 {
            list = points                       // コマンドが返した並びで置き換える
        } else {
            list.append(contentsOf: points)     // 1 点ずつ積む
        }
        if list.count > limit { list = Array(list.suffix(limit)) }
        if widgetHistory[id] != list { widgetHistory[id] = list }
    }

    func addGroup() {
        groups.append(Group(name: "新しいグループ"))
    }

    /// Finder と アプリ は「アプリ一覧」に常に出るので、グループからは外す。
    func separatePinnedApps() {
        for index in groups.indices {
            groups[index].apps.removeAll { $0.isPinned }
        }
        kept.removeAll { $0.isPinned }
    }

    /// アプリを別のグループへ移す（他のグループからは外す）。
    func move(_ path: String, to id: Group.ID) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        guard !groups[index].apps.contains(where: { $0.path == path }) else { return }
        var keep = true
        for other in groups.indices where groups[other].id != id {
            if let app = groups[other].apps.first(where: { $0.path == path }) {
                keep = app.keepWhenQuit
                groups[other].apps.removeAll { $0.path == path }
            }
        }
        groups[index].apps.append(AppRef(path: path, keepWhenQuit: keep))
    }

    func remove(_ group: Group) {
        groups.removeAll { $0.id == group.id }
    }

    /// いま実行中の通常アプリ。running のキャッシュを返すだけ（毎回 OS に聞かない）。
    var runningApps: [AppRef] { running }

    /// 起動したアプリを帯に足す（入っていなければ。追加先は先頭のグループ）。
    func autoAdd(_ path: String) {
        // 起動しただけのアプリは「残さない」区分（実行中として出て、終了で消える）。ここでは何も足さない。
        // 「残す」にするのは、追加ボタンかメニューの「バーに残す」だけ。
        unhide(path)
    }

    /// 追加ボタンで選んだアプリを「残す」区分（アプリ一覧）の末尾へ入れる。残す＝オンで入る。
    func addToStrip(paths: [String]) {
        for path in paths where !AppRef.pinnedPaths.contains(path) {
            unhide(path)
            if kept.contains(where: { $0.path == path }) { continue }
            if groups.contains(where: { group in group.apps.contains { $0.path == path } }) { continue }
            kept.append(AppRef(path: path, keepWhenQuit: true))
        }
    }

    /// ドラッグされたアプリをこのグループへ移す（固定アプリは動かさない）。
    @discardableResult
    func moveInto(_ id: Group.ID, appIDs: [String]) -> Bool {
        guard let target = groups.firstIndex(where: { $0.id == id }) else { return false }
        var moved = false
        for appID in appIDs {
            guard let source = groups.first(where: { group in
                group.apps.contains { $0.id == appID }
            }), let ref = source.apps.first(where: { $0.id == appID }) else { continue }
            if ref.isPinned { continue }
            for other in groups.indices where groups[other].id != id {
                if groups[other].apps.contains(where: { $0.id == appID }) {
                    groups[other].apps.removeAll { $0.id == appID }
                    moved = true
                }
            }
            if !groups[target].apps.contains(where: { $0.id == appID }) {
                groups[target].apps.append(ref)
                moved = true
            }
        }
        return moved
    }

    // MARK: - ドラッグ＆ドロップ（iPhone と同じ操作）

    /// どの並びにいるアプリか（"kept" か グループ ID）。
    private func location(of id: String) -> (group: Group.ID?, index: Int)? {
        if let index = kept.firstIndex(where: { $0.id == id }) { return (nil, index) }
        for group in groups {
            if let index = group.apps.firstIndex(where: { $0.id == id }) { return (group.id, index) }
        }
        return nil
    }

    /// タイルの id から AppRef を探す。
    func appRef(id: String) -> AppRef? {
        if let ref = kept.first(where: { $0.id == id }) { return ref }
        for group in groups {
            if let ref = group.apps.first(where: { $0.id == id }) { return ref }
        }
        // まだ「残す」にもグループにも入っていない実行中アプリも掴める。
        return running.first { $0.id == id }
    }

    /// id（パス＋引数）からパスだけ取り出す。
    func pathOf(id: String) -> String? {
        appRef(id: id)?.path ?? (id.contains("\u{1}") ? String(id.split(separator: "\u{1}")[0]) : id)
    }

    /// もう一度置いたら、実行中の一覧から隠すのをやめる。
    func unhide(_ path: String) {
        hiddenRunning.remove(path)
    }

    /// そのアプリが入っているグループ（アプリ一覧なら nil）。
    func groupID(ofApp id: String) -> Group.ID? {
        for group in groups where group.apps.contains(where: { $0.id == id }) {
            return group.id
        }
        return nil
    }

    /// アプリを別のグループへ移す（iPhone のフォルダへ入れる動き）。
    func move(appID: String, intoGroup groupID: Group.ID) {
        guard let target = groups.firstIndex(where: { $0.id == groupID }) else { return }
        guard let ref = appRef(id: appID), !ref.isPinned, isInKeepZone(appID: appID) else { return }
        if groups[target].apps.contains(where: { $0.id == appID }) { return }
        unhide(ref.path)
        remove(appID: appID)
        groups[target].apps.append(ref)
    }

    /// アプリを 1 つだけ外す（どこにあっても）。
    private func remove(appID: String) {
        kept.removeAll { $0.id == appID }
        for index in groups.indices {
            groups[index].apps.removeAll { $0.id == appID }
        }
    }

    /// 2 つのアプリをまとめて新しいグループを作る（iPhone でアイコンを重ねたとき）。
    @discardableResult
    func createGroup(from appID: String, with otherID: String) -> Group.ID? {
        guard let first = appRef(id: appID), let second = appRef(id: otherID) else { return nil }
        guard first.id != second.id, !first.isPinned, !second.isPinned else { return nil }
        // グループは「残す」区分の中だけ。残さない（実行中だけ）のアプリは入れられない。
        guard isInKeepZone(appID: first.id), isInKeepZone(appID: second.id) else { return nil }
        remove(appID: first.id)
        remove(appID: second.id)
        let group = Group(name: "新規グループ", apps: [second, first])
        groups.append(group)
        return group.id
    }

    /// 並び替え：ドラッグしたアプリを、対象の直前へ移す。
    func reorder(appID: String, before targetID: String, after: Bool = false) {
        guard appID != targetID,
              let source = appRef(id: appID),
              let destination = location(of: targetID) else { return }
        guard !source.isPinned else { return }
        // 「残す」区分と「残さない」区分の間は動かせない。
        guard isInKeepZone(appID: appID), isInKeepZone(appID: targetID) else { return }
        remove(appID: appID)
        let offset = after ? 1 : 0
        if let groupID = destination.group {
            guard let index = groups.firstIndex(where: { $0.id == groupID }),
                  let insertion = groups[index].apps.firstIndex(where: { $0.id == targetID }) else { return }
            groups[index].apps.insert(source, at: insertion + offset)
        } else {
            guard let insertion = kept.firstIndex(where: { $0.id == targetID }) else { return }
            kept.insert(source, at: insertion + offset)
        }
    }

    /// ウィジェットの並べ替え：`id` を `targetID` の前（after なら後ろ）へ。
    func reorderWidget(_ id: UUID, before targetID: UUID, after: Bool = false) {
        guard id != targetID, let from = prefs.widgets.firstIndex(where: { $0.id == id }) else { return }
        var list = prefs.widgets
        let widget = list.remove(at: from)
        guard let to = list.firstIndex(where: { $0.id == targetID }) else { return }
        list.insert(widget, at: to + (after ? 1 : 0))
        prefs.widgets = list
    }

    /// アプリを「残す」並びの末尾へ移す（何もない所へドロップ）。
    func moveToEnd(appID: String) {
        guard let ref = appRef(id: appID), !ref.isPinned else { return }
        if location(of: appID)?.group == nil, kept.last?.id == appID { return }
        remove(appID: appID)
        kept.append(ref)
    }

    /// グループを別のグループへ重ねたら統合する（iPhone のフォルダ同士）。
    func merge(groupID: Group.ID, into targetID: Group.ID) {
        guard groupID != targetID,
              let sourceIndex = groups.firstIndex(where: { $0.id == groupID }),
              let targetIndex = groups.firstIndex(where: { $0.id == targetID }) else { return }
        let moving = groups[sourceIndex].apps.filter { !$0.isPinned }
        for ref in moving where !groups[targetIndex].apps.contains(where: { $0.id == ref.id }) {
            groups[targetIndex].apps.append(ref)
        }
        groups.remove(at: sourceIndex)
    }

    /// 同じアプリを引数だけ変えて複製する（Unity のプロジェクト違いなど）。
    func duplicate(_ ref: AppRef, arguments: String) {
        guard let index = groups.firstIndex(where: { group in
            group.apps.contains { $0.id == ref.id }
        }) else { return }
        let copy = AppRef(path: ref.path, arguments: arguments, keepWhenQuit: ref.keepWhenQuit)
        guard !groups[index].apps.contains(where: { $0.id == copy.id }) else { return }
        groups[index].apps.append(copy)
    }

    /// グループへアプリを追加する（ファイル選択）。
    func addAppsTo(_ id: Group.ID) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "追加"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !groups[index].apps.contains(where: { $0.path == url.path }) {
            groups[index].apps.append(AppRef(path: url.path))
            unhide(url.path)
        }
    }

    /// 「Dock に残す」：実行中アプリを、グループとは別の「残す」並びへ入れる。
    func keepOnStrip(_ path: String) {
        unhide(path)
        guard !kept.contains(where: { $0.path == path }) else { return }
        // グループに入っているなら外へ出す（グループと固定は別物）。
        for index in groups.indices {
            groups[index].apps.removeAll { $0.path == path }
        }
        kept.append(AppRef(path: path, keepWhenQuit: true))
    }

    /// 「Dock から外す」対象か（「残す」並びに入っている）。
    func isKept(_ path: String) -> Bool {
        kept.contains { $0.path == path }
    }

    /// 「残す」並びのアプリの右クリック用（引数違いも区別）。
    func keptRef(id: String) -> AppRef? {
        kept.first { $0.id == id }
    }

    /// 帯から完全に外す（引数違いも含めて id 単位で）。
    func removeEverywhere(id: String) {
        for group in groups.indices {
            groups[group].apps.removeAll { $0.id == id && !$0.isPinned }
        }
        kept.removeAll { $0.id == id && !$0.isPinned }
        // 実行中の一覧にも出さない（出したままにすると「消したのに戻る」に見える）。
        if let path = pathOf(id: id) { hiddenRunning.insert(path) }
    }

    /// 帯から完全に外す。
    func removeEverywhere(_ path: String) {
        guard !AppRef.pinnedPaths.contains(path) else { return }
        for index in groups.indices {
            groups[index].apps.removeAll { $0.path == path }
        }
        kept.removeAll { $0.path == path }
        hiddenRunning.insert(path)
    }

    /// 終了したアプリを、残さない設定なら帯から外す。
    func removeOnQuit(_ path: String) {
        // 終了したアプリは「隠す」を解除する（次に起動したら普通に出る）。
        hiddenRunning.remove(path)
        // 実行中の一覧からは、通知を待たず即座に外す（終了したのにアイコンが残らないように）。
        running.removeAll { $0.path == path }
        // 「残す」区分（アプリ一覧・グループ）は、終了しても消さない。消えるのは「残さない」区分（実行中だけ）。
    }

    /// 「残す」区分か（アプリ一覧・グループ・固定）。実行中だけのアプリは「残さない」区分。
    func isInKeepZone(appID: String) -> Bool {
        guard let ref = appRef(id: appID) else { return false }
        if ref.isPinned { return true }
        return kept.contains { $0.id == appID } || groups.contains { $0.apps.contains { $0.id == appID } }
    }

    /// Dock にピン留めしてあるアプリをグループに足す（既定は先頭のグループ）。
    func importDockApps(into id: Group.ID? = nil) {
        let refs = Store.dockPinnedApps()
        guard !refs.isEmpty else { return }
        guard let index = groups.firstIndex(where: { $0.id == (id ?? groups.first?.id) }) else {
            groups.append(Group(name: "Dock", apps: refs))
            return
        }
        for ref in refs where !groups[index].apps.contains(where: { $0.path == ref.path }) {
            groups[index].apps.append(ref)
        }
    }

    private static func load() -> [Group] {
        if let groups = Persistence.load([Group].self, from: fileURL) { return groups }
        // 初回は macOS の Dock にピン留めしてあるアプリを取り込んでおく。
        return [Group(name: "Dock", apps: dockPinnedApps())]
    }

    private static func loadHidden() -> Set<String> {
        Set(Persistence.load([String].self, from: hiddenURL) ?? [])
    }

    /// 保存して、失敗は記録する。続けて失敗したときだけ、利用者に知らせる（`SaveFailureTracker`）。
    private func persist<T: Encodable>(_ value: T, to url: URL, pretty: Bool = true) {
        let error = Persistence.save(value, to: url, pretty: pretty)
        if let error { NSLog("GroupDock: cannot save \(url.path): \(error.localizedDescription)") }
        if saveFailures.record(failed: error != nil, key: url.lastPathComponent) {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "設定を保存できません"
                alert.informativeText = "\(url.lastPathComponent) を続けて保存できませんでした。ディスクの空きと、フォルダの権限を確認してください。\n\(url.deletingLastPathComponent().path)"
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    private func saveHidden() { persist(hiddenRunning.sorted(), to: Store.hiddenURL) }

    private static func loadKept() -> [AppRef] {
        Persistence.load([AppRef].self, from: keptURL) ?? []
    }

    private static func loadHistory() -> [AppRef] {
        Persistence.load([AppRef].self, from: historyURL) ?? []
    }

    /// 選べるインスタンスが 2 つ以上あるか（プロセスでもウィンドウでも）。青丸と選択ポップアップの条件。
    func hasMultipleInstances(_ path: String) -> Bool {
        AppInstances.isMultiple(AppInstances.choiceCount(
            processes: instanceCounts[path] ?? 0, windows: windowCounts[path] ?? 0))
    }

    /// 実行中アプリが応答しているかを裏で調べ、変わったときだけ反映する。
    private func checkResponsiveness() {
        guard AXIsProcessTrusted(), !responsivenessInFlight else { return }
        responsivenessInFlight = true
        let own = Bundle.main.bundlePath
        let targets = NSWorkspace.shared.runningApplications.compactMap { app -> (pid_t, String)? in
            guard app.activationPolicy == .regular, !app.isTerminated,
                  let path = app.bundleURL?.resolvingSymlinksInPath().path, path != own else { return nil }
            return (app.processIdentifier, path)
        }
        responsivenessQueue.async { [weak self] in
            var hung = Set<String>()
            var windows: [String: Int] = [:]
            for (pid, path) in targets {
                if AppResponsiveness.isHung(pid: pid) { hung.insert(path); continue }
                windows[path, default: 0] += AppInstances.windowTitles(pid: pid).count
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.responsivenessInFlight = false
                if hung != self.hungPaths { self.hungPaths = hung }
                if windows != self.windowCounts { self.windowCounts = windows }
            }
        }
    }

    /// 明示的に起動した時刻（同じ起動を、実行中の検出でもう一度履歴に足さないため）。
    private var explicitLaunch: [String: Date] = [:]

    /// 履歴に足す。同じ（パス＋引数）は 1 件にまとめ、新しいものを先頭へ。引数違いは別の項目として残す。
    func recordHistory(_ launched: [AppRef], explicit: Bool = false) {
        var next = history
        for ref in launched.reversed() {
            if explicit {
                explicitLaunch[ref.path] = Date()
            } else if let at = explicitLaunch[ref.path], Date().timeIntervalSince(at) < 15 {
                continue
            }
            next = HistoryList.adding(ref, to: next)
        }
        guard next != history else { return }
        history = next
        saveHistory()
    }

    /// 履歴から 1 件消す。
    func removeHistory(id: String) {
        history.removeAll { $0.id == id }
        saveHistory()
    }

    private func saveHistory() { persist(history, to: Store.historyURL, pretty: false) }

    private func saveKept() { persist(kept, to: Store.keptURL) }

    private func save() { persist(groups, to: Store.fileURL) }

    private static func loadPrefs() -> Prefs {
        Persistence.load(Prefs.self, from: prefsURL) ?? Prefs()
    }

    /// 設定の保存を 0.4 秒待ってからまとめて行う（毎フレーム書くとドラッグがカクつく）。
    private func schedulePrefsSave() {
        prefsSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.savePrefs() }
        prefsSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// 終了時に呼ぶ。待たずに書き出す。
    func flushPrefs() {
        prefsSaveWork?.cancel()
        savePrefs()
    }

    private func savePrefs() { persist(prefs, to: Store.prefsURL) }

    private static func dockPinnedApps() -> [AppRef] {
        guard let dock = UserDefaults(suiteName: "com.apple.dock"),
              let items = dock.array(forKey: "persistent-apps") as? [[String: Any]] else { return [] }

        let paths: [String] = items.compactMap { item in
            guard let tile = item["tile-data"] as? [String: Any],
                  let file = tile["file-data"] as? [String: Any],
                  let url = file["_CFURLString"] as? String else { return nil }
            var path = url
            if path.hasPrefix("file://") { path.removeFirst("file://".count) }
            path = path.removingPercentEncoding ?? path
            while path.hasSuffix("/") { path.removeLast() }   // file:///…/Foo.app/ の形で来る
            return path.hasSuffix(".app") ? path : nil
        }
        // 同じアプリが二度入るのを防ぐ。
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }.map { AppRef(path: $0) }
    }
}
