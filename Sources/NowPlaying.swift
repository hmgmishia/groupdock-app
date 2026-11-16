import AppKit
import Foundation

/// 「再生中」ウィジェットの取得・操作・解釈。UI を含まない（テストできる）。
///
/// private framework（MediaRemote）は使わない（SECURITY.md の「内部 API」の例外を除く）。代わりに、
/// - ミュージック / Spotify は AppleScript で直接聞く。
/// - ブラウザ（Chrome / Safari）は、開いているタブの再生要素（video / audio）を JavaScript で読み書きする。
///   YouTube など、再生要素を持つサイトはこれで扱える。Firefox は AppleScript から JavaScript を実行できないので対象外。
/// - サムネは通信しない。ミュージックはアプリのアートワーク、ブラウザは動画のフレームから作る。

enum PlaybackSource: String, Codable, CaseIterable, Identifiable {
    case auto, system, music, spotify, chrome, safari

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "自動（再生中のもの）"
        case .system: return "システム（macOS が知っている再生）"
        case .music: return "ミュージック"
        case .spotify: return "Spotify"
        case .chrome: return "Chrome（YouTube など）"
        case .safari: return "Safari（YouTube など）"
        }
    }

    /// AppleScript の `tell application` に渡す名前。
    var appName: String {
        switch self {
        case .auto, .system: return ""
        case .music: return "Music"
        case .spotify: return "Spotify"
        case .chrome: return "Google Chrome"
        case .safari: return "Safari"
        }
    }

    var bundleID: String? {
        switch self {
        case .auto, .system: return nil
        case .music: return "com.apple.Music"
        case .spotify: return "com.spotify.client"
        case .chrome: return "com.google.Chrome"
        case .safari: return "com.apple.Safari"
        }
    }

    var isBrowser: Bool { self == .chrome || self == .safari }

    /// 起動していなければ聞かない（`tell application` はアプリを勝手に起動してしまうため）。
    var isRunning: Bool {
        guard let id = bundleID else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
    }
}

/// 帯に置くときの表示パターン。
enum PlayerLayout: String, Codable, CaseIterable, Identifiable {
    case thumbnail, thumbnailPlay, transport, full

    var id: String { rawValue }

    var title: String {
        switch self {
        case .thumbnail: return "サムネだけ"
        case .thumbnailPlay: return "サムネ＋再生/停止"
        case .transport: return "前・再生/停止・次"
        case .full: return "フル（サムネ・曲名・操作・音量）"
        }
    }

    /// 帯でのタイルの幅。アイコンの大きさから決める。
    func width(icon: CGFloat) -> CGFloat {
        switch self {
        case .thumbnail: return icon
        case .thumbnailPlay: return icon * 1.7
        case .transport: return icon * 2.0
        case .full: return max(icon * 3.4, 150)
        }
    }

    /// 左右に置くときの高さ（縦に積む）。幅はアイコン。
    func height(icon: CGFloat) -> CGFloat {
        switch self {
        case .thumbnail: return icon
        case .thumbnailPlay: return (icon * 1.7).rounded(.up)
        case .transport: return (icon * 2.0).rounded(.up)
        case .full: return max(icon * 2.8, 130).rounded(.up)
        }
    }

    func size(icon: CGFloat, vertical: Bool) -> CGSize {
        vertical ? CGSize(width: icon, height: height(icon: icon)) : CGSize(width: width(icon: icon), height: icon)
    }
}

enum PlaybackAction { case toggle, next, previous }

/// 再生元ごとに、いまできる操作。できないものは画面で灰色にする。
struct PlaybackCapabilities: Equatable {
    var toggle = true
    var next = true
    var previous = true
    var seek = false
    var volume = false

    /// 何も再生していないとき（全部できない）。
    static let none = PlaybackCapabilities(toggle: false, next: false, previous: false, seek: false, volume: false)
}

struct PlaybackInfo: Equatable {
    var source: PlaybackSource
    var title: String
    var artist: String
    var playing: Bool
    /// 対象サービス自身の音量（0〜100）。読めなければ nil。
    var volume: Int?
    /// サムネ（画像データ）。
    var artwork: Data?
    /// 再生位置と長さ（秒）。分からなければ nil（ライブ配信など）。
    var position: Double? = nil
    var duration: Double? = nil
    /// 位置を読んだ時刻（その後の進み具合を計算する）。
    var fetchedAt = Date()
    var capabilities = PlaybackCapabilities()
    /// システムの再生に、ブラウザの音量を付けたとき、その音量を読んだブラウザ（書き込み先）。それ以外は nil。
    var volumeBrowser: PlaybackSource? = nil

    /// いまの再生位置。再生中なら読んだ時刻からの経過を足す。長さを超えない。
    func currentPosition(at now: Date = Date()) -> Double? {
        guard let position else { return nil }
        let moved = playing ? max(0, now.timeIntervalSince(fetchedAt)) : 0
        let value = position + moved
        return duration.map { min(value, $0) } ?? value
    }

    /// 秒を「分:秒」（1 時間以上は「時:分:秒」）にする。
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// 再生状態。Store とは別の入れ物にして、毎回の更新で帯全体を描き直さない。
final class NowPlayingState: ObservableObject {
    @Published var info: PlaybackInfo?
    /// 読めなかった理由のヒント（ブラウザの許可など）。
    @Published var hint: String?
}

// MARK: - MediaRemote（private framework。条件は SECURITY.md の「内部 API」）

/// macOS が知っている「いま再生中」を、アプリを問わず読む。読み取りと再生操作だけ。
/// 外部へ送信せず、ファイルも書かない。`dlopen` で実行時に読み、取れなければ nil（呼び出し側が従来の取得に戻す）。
enum MediaRemoteBridge {
    private typealias InfoHandler = @convention(block) (CFDictionary?) -> Void
    private typealias BoolHandler = @convention(block) (Bool) -> Void
    private typealias InfoFn = @convention(c) (DispatchQueue, @escaping InfoHandler) -> Void
    private typealias PlayingFn = @convention(c) (DispatchQueue, @escaping BoolHandler) -> Void
    private typealias CommandFn = @convention(c) (UInt32, CFDictionary?) -> Bool

    private static let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    /// 再生中の情報。取れない・空のときは nil。呼び出し側は裏のキューで呼ぶ。
    static func read(wantArtwork: Bool) -> PlaybackInfo? {
        if let line = MediaRemoteHelper.run(wantArtwork ? .getWithArtwork : .getPlain) {
            return parseHelper(line, wantArtwork: wantArtwork)
        }
        guard let infoFn = symbol("MRMediaRemoteGetNowPlayingInfo", as: InfoFn.self) else { return nil }
        var dictionary: [String: Any]?
        let semaphore = DispatchSemaphore(value: 0)
        infoFn(DispatchQueue.global(qos: .userInitiated)) { info in
            dictionary = info as? [String: Any]
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 1.0) == .success, let dictionary else { return nil }

        var playing = false
        if let playingFn = symbol("MRMediaRemoteGetNowPlayingApplicationIsPlaying", as: PlayingFn.self) {
            let wait = DispatchSemaphore(value: 0)
            playingFn(DispatchQueue.global(qos: .userInitiated)) { value in
                playing = value
                wait.signal()
            }
            _ = wait.wait(timeout: .now() + 1.0)
        }
        return parse(dictionary, playing: playing, wantArtwork: wantArtwork)
    }

    /// 補助ライブラリの JSON（MediaRemote のキー＋ playing ＋ artwork の base64）を読む（純粋関数）。
    static func parseHelper(_ line: String, wantArtwork: Bool) -> PlaybackInfo? {
        guard let data = line.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let playing = object["playing"] as? Bool ?? false
        if let base64 = object["artwork"] as? String {
            object["kMRMediaRemoteNowPlayingInfoArtworkData"] = Data(base64Encoded: base64)
        }
        if let elapsed = object["elapsed"] { object["kMRMediaRemoteNowPlayingInfoElapsedTime"] = elapsed }
        if let duration = object["duration"] { object["kMRMediaRemoteNowPlayingInfoDuration"] = duration }
        guard var info = parse(object, playing: playing, wantArtwork: wantArtwork) else { return nil }
        if let commands = object["commands"] as? [Int] {
            info.capabilities = capabilities(enabled: Set(commands), hasDuration: info.duration != nil)
        }
        return info
    }

    /// 再生元が受け付ける命令の番号から、できる操作を決める（純粋関数）。
    /// 再生/停止 = 2（または 再生 0・一時停止 1）、次 = 4、前 = 5、位置 = 24。
    static func capabilities(enabled commands: Set<Int>, hasDuration: Bool) -> PlaybackCapabilities {
        PlaybackCapabilities(
            toggle: commands.contains(2) || (commands.contains(0) && commands.contains(1)),
            next: commands.contains(4),
            previous: commands.contains(5),
            seek: hasDuration && commands.contains(24),
            volume: false)
    }

    /// 辞書を読む（純粋関数。テストする）。
    static func parse(_ info: [String: Any], playing: Bool, wantArtwork: Bool) -> PlaybackInfo? {
        guard let title = info["kMRMediaRemoteNowPlayingInfoTitle"] as? String, !title.isEmpty else { return nil }
        let duration = (info["kMRMediaRemoteNowPlayingInfoDuration"] as? Double).flatMap { $0 > 0 ? $0 : nil }
        let position = info["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? Double
        return PlaybackInfo(
            source: .system,
            title: title,
            artist: info["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? "",
            playing: playing,
            volume: nil,
            artwork: wantArtwork ? info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data : nil,
            position: duration == nil ? nil : position,
            duration: duration,
            // システムの再生は、音量を変えられない（アプリごとの音量が取れない）。位置は長さが分かるときだけ。
            capabilities: PlaybackCapabilities(seek: duration != nil, volume: false)
        )
    }

    /// 再生操作を送る。送れたら true。
    @discardableResult
    static func send(_ action: PlaybackAction) -> Bool {
        let call: MediaRemoteHelper.Call
        switch action {
        case .toggle: call = .toggle
        case .next: call = .next
        case .previous: call = .previous
        }
        if let line = MediaRemoteHelper.run(call) { return line.contains("true") }
        guard let commandFn = symbol("MRMediaRemoteSendCommand", as: CommandFn.self) else { return false }
        return commandFn(command(action), nil)
    }

    /// MediaRemote の命令番号（再生/停止 = 2、次 = 4、前 = 5）。
    static func command(_ action: PlaybackAction) -> UInt32 {
        switch action {
        case .toggle: return 2
        case .next: return 4
        case .previous: return 5
        }
    }
}

// MARK: - 解釈（純粋関数）

enum NowPlayingParse {
    static let separator = "\u{1F}"

    /// 数字を読む（地域によって小数点が「,」になるのを直す）。
    static func number(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }

    /// ミュージック / Spotify の出力「状態 ␟ 曲名 ␟ アーティスト ␟ 音量 ␟ 再生位置 ␟ 長さ」を読む。
    /// Spotify の長さはミリ秒で返るので秒に直す。
    static func delimited(_ text: String, source: PlaybackSource) -> PlaybackInfo? {
        let parts = text.components(separatedBy: separator)
        guard parts.count >= 3, !parts[1].isEmpty else { return nil }
        let volume = parts.count > 3 ? Int(parts[3].trimmingCharacters(in: .whitespaces)) : nil
        let position = parts.count > 4 ? number(parts[4]) : nil
        var duration = parts.count > 5 ? number(parts[5]) : nil
        if source == .spotify { duration = duration.map { $0 / 1000 } }
        if let value = duration, value <= 0 { duration = nil }
        return PlaybackInfo(
            source: source,
            title: parts[1],
            artist: parts[2],
            playing: parts[0] == "playing",
            volume: volume,
            artwork: nil,
            position: duration == nil ? nil : position,
            duration: duration,
            capabilities: PlaybackCapabilities(seek: duration != nil, volume: volume != nil)
        )
    }

    /// ブラウザの JavaScript が返す JSON（t: 題, a: 作者, p: 再生中, v: 音量, img: サムネの data URL）を読む。
    static func browser(_ json: String, source: PlaybackSource) -> PlaybackInfo? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = object["t"] as? String, !title.isEmpty else { return nil }
        let duration = (object["du"] as? Double).flatMap { $0 > 0 && $0.isFinite ? $0 : nil }
        let volume = (object["v"] as? Double).map { min(100, max(0, Int($0.rounded()))) }
        return PlaybackInfo(
            source: source,
            title: title,
            artist: object["a"] as? String ?? "",
            playing: object["p"] as? Bool ?? false,
            volume: volume,
            artwork: (object["img"] as? String).flatMap(dataURL),
            position: duration == nil ? nil : object["ct"] as? Double,
            duration: duration,
            // 次へは YouTube の「次へ」ボタンがあるときだけ。前へは無くても頭出しできる。
            capabilities: PlaybackCapabilities(
                next: object["nx"] as? Bool ?? false, seek: duration != nil, volume: volume != nil)
        )
    }

    /// `data:image/jpeg;base64,...` から画像データを取り出す。
    static func dataURL(_ text: String) -> Data? {
        guard text.hasPrefix("data:"), let range = text.range(of: "base64,") else { return nil }
        return Data(base64Encoded: String(text[range.upperBound...]))
    }

    /// システムの再生（音量を持たない）に、ブラウザが読めた音量を足す。
    /// 付けるのは「再生中」で「題名が一致する」ブラウザだけ（別の曲のタブや止まったタブの音量を出さない）。
    /// 操作の元はシステムのまま。音量だけ、読んだブラウザの JavaScript で読み書きする（`volumeBrowser` に覚える）。
    static func merging(browsers: [PlaybackInfo], into info: PlaybackInfo) -> PlaybackInfo {
        guard info.source == .system, !info.title.isEmpty else { return info }
        let match = browsers.first { browser in
            browser.source.isBrowser && browser.playing && browser.volume != nil
                && !browser.title.isEmpty && titlesMatch(browser.title, info.title)
        }
        guard let match, let volume = match.volume else { return info }
        var merged = info
        merged.volume = volume
        merged.capabilities.volume = true
        merged.volumeBrowser = match.source
        return merged
    }

    /// 題名が同じか。ブラウザのタブ名は「曲名 - YouTube」のように足されることがあるので、どちらかが相手を含めば一致とする。
    static func titlesMatch(_ a: String, _ b: String) -> Bool {
        let x = a.trimmingCharacters(in: .whitespaces), y = b.trimmingCharacters(in: .whitespaces)
        guard !x.isEmpty, !y.isEmpty else { return false }
        return x == y || x.contains(y) || y.contains(x)
    }

    /// 音量を書き込む先（純粋関数）。システムの再生は、音量を読んだブラウザ。無ければ書けない（nil）。
    static func volumeTarget(for info: PlaybackInfo) -> PlaybackSource? {
        if info.source == .system { return info.volumeBrowser }
        return info.source == .auto ? nil : info.source
    }

    /// 複数の候補から 1 つ選ぶ。再生中のものを優先する。
    static func pick(_ infos: [PlaybackInfo]) -> PlaybackInfo? {
        infos.first(where: \.playing) ?? infos.first
    }
}

// MARK: - AppleScript の組み立て（純粋関数）

enum NowPlayingScript {
    /// 再生要素を選ぶ JavaScript。再生中のものを優先し、無ければ途中まで進んだものを使う。
    static let pickJS = "var els=Array.prototype.slice.call(document.querySelectorAll('video,audio'));"
        + "var e=els.filter(function(x){return !x.paused&&!x.ended&&x.readyState>2})[0]"
        + "||els.filter(function(x){return x.currentTime>0&&!x.ended})[0];if(!e)return '';"

    /// 読み取り用。題・作者・再生中・音量と、動画ならサムネ（フレームを縮小した JPEG）を JSON で返す。
    static func readJS(wantArtwork: Bool) -> String {
        "(function(){" + pickJS
            + "var m=navigator.mediaSession&&navigator.mediaSession.metadata;var img='';"
            + "try{if(\(wantArtwork)&&e.tagName==='VIDEO'&&e.videoWidth>0){var c=document.createElement('canvas');"
            + "c.width=160;c.height=Math.round(160*e.videoHeight/e.videoWidth);"
            + "c.getContext('2d').drawImage(e,0,0,c.width,c.height);img=c.toDataURL('image/jpeg',0.7);}}catch(x){}"
            + "var nb=document.querySelector('.ytp-next-button');"
            + "var nx=!!(nb&&getComputedStyle(nb).display!=='none'&&nb.getAttribute('aria-disabled')!=='true');"
            + "return JSON.stringify({t:(m&&m.title)||document.title,a:(m&&m.artist)||location.hostname,"
            + "p:!e.paused,v:Math.round((e.muted?0:e.volume)*100),img:img,"
            + "ct:e.currentTime,du:(isFinite(e.duration)?e.duration:0),nx:nx});})()"
    }

    /// 操作用。次・前は YouTube のボタンを押す（他のサイトは前だけ頭出し、次は何もしない）。
    static func controlJS(_ action: PlaybackAction) -> String {
        let body: String
        switch action {
        case .toggle: body = "if(e.paused){e.play()}else{e.pause()}"
        case .next: body = "var b=document.querySelector('.ytp-next-button');if(b){b.click()}"
        case .previous:
            body = "var b=document.querySelector('.ytp-prev-button');"
                + "if(b&&getComputedStyle(b).display!=='none'){b.click()}else{e.currentTime=0}"
        }
        return "(function(){" + pickJS + body + "return 'ok';})()"
    }

    /// 再生位置を動かす（秒）。数字は書式で作るので、JavaScript に文字は入らない。
    static func seekJS(_ seconds: Double) -> String {
        "(function(){" + pickJS + "e.currentTime=" + String(format: "%.2f", max(0, seconds)) + ";return 'ok';})()"
    }

    static func volumeJS(_ value: Int) -> String {
        "(function(){" + pickJS + "e.muted=false;e.volume=\(min(100, max(0, value)))/100;return 'ok';})()"
    }

    /// 全ウィンドウ・全タブに JavaScript を流して結果を返す。
    /// 別ウィンドウ（全画面・別の Space・別ディスプレイ）で再生中のタブを取りこぼさない。
    /// - 読み取り（`act: false`）：副作用が無いので 1 回の走査。再生中（`"p":true`）を見つけたらすぐ返す。無ければ最初の結果。
    ///   Apple Events はタブ 1 つにつき 1 回だけ（以前と同じ費用）。
    /// - 操作（`act: true`）：副作用があるので、再生中のタブを先に探してから 1 つだけに送る（読み取りの JavaScript で探す）。
    ///   再生中が無ければ、最初に結果が返ったタブへ送る。
    /// - 上限は、ウィンドウごとに 40 タブ（別のウィンドウのタブを、前のウィンドウの数で締め出さない）。
    /// JavaScript が許可されていないときは "NEEDS_JS" を返す。
    static func browser(_ source: PlaybackSource, js: String, act: Bool = false) -> String {
        let call = source == .chrome
            ? "execute t javascript \"\(js)\""
            : "do JavaScript \"\(js)\" in t"
        let probe = source == .chrome
            ? "execute t javascript \"\(playingProbeJS)\""
            : "do JavaScript \"\(playingProbeJS)\" in t"
        return """
        tell application "\(source.appName)"
        \(scan(call: call, probe: act ? probe : nil))
        end tell
        """
    }

    /// 走査の本体（`tell application` の中身）。テストでは、見本の窓とタブで実際に走らせる。
    /// `probe` があれば操作用（再生中のタブを先に探す）、無ければ読み取り用（再生中を見つけたら即返す）。
    static func scan(call: String, probe: String?, windows: String = "windows", tabs: String = "tabs of w") -> String {
        let limit = tabLimitPerWindow
        if let probe {
            return """
            set sawError to false
            repeat with w in \(windows)
            set n to 0
            repeat with t in \(tabs)
            set n to n + 1
            if n > \(limit) then exit repeat
            try
            if (\(probe)) is "1" then
            set r to \(call)
            if r is not missing value then
            if r is not "" then return r
            end if
            end if
            on error
            set sawError to true
            end try
            end repeat
            end repeat
            repeat with w in \(windows)
            set n to 0
            repeat with t in \(tabs)
            set n to n + 1
            if n > \(limit) then exit repeat
            try
            set r to \(call)
            if r is not missing value then
            if r is not "" then return r
            end if
            on error
            set sawError to true
            end try
            end repeat
            end repeat
            if sawError then return "NEEDS_JS"
            return ""
            """
        }
        return """
        set sawError to false
        set firstResult to ""
        repeat with w in \(windows)
        set n to 0
        repeat with t in \(tabs)
        set n to n + 1
        if n > \(limit) then exit repeat
        try
        set r to \(call)
        if r is not missing value then
        if r is not "" then
        if r contains "\\"p\\":true" then return r
        if firstResult is "" then set firstResult to r
        end if
        end if
        on error
        set sawError to true
        end try
        end repeat
        end repeat
        if firstResult is not "" then return firstResult
        if sawError then return "NEEDS_JS"
        return ""
        """
    }

    /// 1 つのウィンドウで調べるタブの数の上限。
    static let tabLimitPerWindow = 40

    /// 再生中の要素があるタブだけ "1" を返す（操作の前に、再生中のタブを探すため。読み取りだけで副作用が無い）。
    static let playingProbeJS = "(function(){var els=Array.prototype.slice.call(document.querySelectorAll('video,audio'));"
        + "return els.some(function(x){return !x.paused&&!x.ended&&x.readyState>2})?'1':'0';})()"

    /// ミュージック / Spotify の現在の曲。止まっているときは空を返す。
    static func player(_ source: PlaybackSource) -> String {
        """
        tell application "\(source.appName)"
        if player state is stopped then return ""
        set t to current track
        set sep to (ASCII character 31)
        return (player state as text) & sep & (name of t) & sep & (artist of t) & sep & (sound volume as text) ¬
            & sep & (player position as text) & sep & (duration of t as text)
        end tell
        """
    }

    static let musicArtwork = "tell application \"Music\" to return data of artwork 1 of current track"

    static func playerControl(_ source: PlaybackSource, _ action: PlaybackAction) -> String {
        let verb: String
        switch action {
        case .toggle: verb = "playpause"
        case .next: verb = "next track"
        case .previous: verb = "previous track"
        }
        return "tell application \"\(source.appName)\" to \(verb)"
    }

    static func playerSeek(_ source: PlaybackSource, _ seconds: Double) -> String {
        "tell application \"\(source.appName)\" to set player position to " + String(format: "%.2f", max(0, seconds))
    }

    static func playerVolume(_ source: PlaybackSource, _ value: Int) -> String {
        "tell application \"\(source.appName)\" to set sound volume to \(min(100, max(0, value)))"
    }
}

// MARK: - 実行

enum AppleScriptRunner {
    /// 結果の文字列・データと、失敗したか。呼び出し側は 1 本の裏キューでだけ呼ぶ。
    static func run(_ source: String) -> (text: String?, data: Data?, failed: Bool) {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return (nil, nil, true) }
        let result = script.executeAndReturnError(&error)
        if error != nil { return (nil, nil, true) }
        return (result.stringValue, result.data, false)
    }
}

/// 再生情報を読む。サムネは曲が変わったときだけ作り直し、同じ曲の間は使い回す。
final class NowPlayingFetcher {
    private var artworkKey = ""
    private var artwork: Data?

    private enum Outcome { case info(PlaybackInfo), none, needsJS }

    func fetch(source: PlaybackSource, wantArtwork: Bool) -> (info: PlaybackInfo?, hint: String?) {
        // まず macOS が知っている再生を試す。空なら、従来のアプリ別取得に戻す。
        if source == .auto || source == .system, let info = MediaRemoteBridge.read(wantArtwork: wantArtwork) {
            // システムの再生は音量を持たない。実行中のブラウザの再生が同じ曲なら、その音量を付ける。
            return (volumeAttached(to: info), nil)
        }
        if source == .system { return (nil, nil) }
        let candidates: [PlaybackSource] = source == .auto ? [.music, .spotify, .chrome, .safari] : [source]
        var infos: [PlaybackInfo] = []
        var needsJS = false
        for candidate in candidates where candidate.isRunning {
            switch read(candidate, wantArtwork: wantArtwork) {
            case .info(let info): infos.append(info)
            case .needsJS: needsJS = true
            case .none: break
            }
        }
        if var info = NowPlayingParse.pick(infos) {
            attachArtwork(&info, wantArtwork: wantArtwork)
            return (info, nil)
        }
        let hint = needsJS
            ? "ブラウザの再生を読めませんでした。ブラウザのメニュー［表示 > デベロッパー > Apple Events からの JavaScript を許可］（Safari は［開発］メニュー）をオンにしてください。"
            : nil
        return (nil, hint)
    }

    /// システムの再生に、同じ曲を再生中のブラウザの音量を付ける（実行中のブラウザだけ読む。画像は読まない）。
    private func volumeAttached(to info: PlaybackInfo) -> PlaybackInfo {
        guard info.source == .system else { return info }
        var browsers: [PlaybackInfo] = []
        for candidate in [PlaybackSource.chrome, .safari] where candidate.isRunning {
            if case .info(let item) = read(candidate, wantArtwork: false) { browsers.append(item) }
        }
        return NowPlayingParse.merging(browsers: browsers, into: info)
    }

    private func read(_ source: PlaybackSource, wantArtwork: Bool) -> Outcome {
        if source.isBrowser {
            let result = AppleScriptRunner.run(
                NowPlayingScript.browser(source, js: NowPlayingScript.readJS(wantArtwork: wantArtwork)))
            guard let text = result.text, !result.failed else { return .none }
            if text == "NEEDS_JS" { return .needsJS }
            return NowPlayingParse.browser(text, source: source).map(Outcome.info) ?? .none
        }
        let result = AppleScriptRunner.run(NowPlayingScript.player(source))
        guard let text = result.text, !result.failed, !text.isEmpty else { return .none }
        return NowPlayingParse.delimited(text, source: source).map(Outcome.info) ?? .none
    }

    private func attachArtwork(_ info: inout PlaybackInfo, wantArtwork: Bool) {
        let key = "\(info.source.rawValue)|\(info.title)|\(info.artist)"
        if key == artworkKey {
            info.artwork = artwork
            return
        }
        if wantArtwork, info.source == .music {
            info.artwork = AppleScriptRunner.run(NowPlayingScript.musicArtwork).data
        }
        artworkKey = key
        artwork = info.artwork
    }
}

/// 操作を送る。呼び出し側は 1 本の裏キューでだけ呼ぶ。
enum NowPlayingControl {
    static func send(_ action: PlaybackAction, to source: PlaybackSource) {
        if source == .system {
            MediaRemoteBridge.send(action)
            return
        }
        guard source != .auto, source.isRunning else { return }
        if source.isBrowser {
            _ = AppleScriptRunner.run(NowPlayingScript.browser(source, js: NowPlayingScript.controlJS(action), act: true))
        } else {
            _ = AppleScriptRunner.run(NowPlayingScript.playerControl(source, action))
        }
    }

    static func seek(to seconds: Double, on source: PlaybackSource) {
        if source == .system {
            _ = MediaRemoteHelper.run(.seek, seconds: seconds)
            return
        }
        guard source != .auto, source.isRunning else { return }
        if source.isBrowser {
            _ = AppleScriptRunner.run(NowPlayingScript.browser(source, js: NowPlayingScript.seekJS(seconds), act: true))
        } else {
            _ = AppleScriptRunner.run(NowPlayingScript.playerSeek(source, seconds))
        }
    }

    static func setVolume(_ value: Int, on info: PlaybackInfo) {
        // システムの再生は、音量を読んだブラウザへ書く（読めていなければ何もしない）。
        guard let source = NowPlayingParse.volumeTarget(for: info), source.isRunning else { return }
        if source.isBrowser {
            _ = AppleScriptRunner.run(NowPlayingScript.browser(source, js: NowPlayingScript.volumeJS(value), act: true))
        } else {
            _ = AppleScriptRunner.run(NowPlayingScript.playerVolume(source, value))
        }
    }
}

// MARK: - Store との接続

extension Store {
    /// 再生状態を裏で読み直す（再生中は 3 秒、止まっていれば 6 秒に 1 回。操作したときは即座に読む）。再生中ウィジェットが無ければ何もしない。
    func refreshNowPlaying() {
        guard let widget = prefs.widgets.first(where: { $0.kind == .nowPlaying }) else {
            if nowPlaying.info != nil || nowPlaying.hint != nil {
                nowPlaying.info = nil
                nowPlaying.hint = nil
            }
            return
        }
        guard !stripHidden else { return }
        let interval = PollPolicy.nowPlayingInterval(playing: nowPlaying.info?.playing == true)
        guard !nowPlayingBusy, Date().timeIntervalSince(lastNowPlayingPoll) >= interval else { return }
        nowPlayingBusy = true
        lastNowPlayingPoll = Date()
        let source = PlaybackSource.auto           // 常に再生中のものを見る（対象は選ばせない）
        let wantArtwork = widget.playerLook(vertical: prefs.position != "bottom") != .transport
        nowPlayingQueue.async { [weak self] in
            guard let self else { return }
            let result = self.nowPlayingFetcher.fetch(source: source, wantArtwork: wantArtwork)
            DispatchQueue.main.async {
                self.nowPlayingBusy = false
                if self.nowPlaying.info != result.info { self.nowPlaying.info = result.info }
                if self.nowPlaying.hint != result.hint { self.nowPlaying.hint = result.hint }
            }
        }
    }

    /// 操作の対象。いま再生情報を出しているサービス。
    private func playbackTarget() -> PlaybackSource? {
        if let info = nowPlaying.info { return info.source }
        return nil
    }

    func playback(_ action: PlaybackAction) {
        guard let source = playbackTarget() else { return }
        // 表示は先に変える（反応を待たせない）。
        if action == .toggle, var info = nowPlaying.info {
            info.playing.toggle()
            nowPlaying.info = info
        }
        nowPlayingQueue.async { [weak self] in
            NowPlayingControl.send(action, to: source)
            DispatchQueue.main.async { self?.lastNowPlayingPoll = .distantPast }
        }
    }

    func seekPlayback(to seconds: Double) {
        guard let source = playbackTarget(), nowPlaying.info?.capabilities.seek == true else { return }
        // 表示は先に動かす（反応を待たせない）。
        if var info = nowPlaying.info {
            info.position = seconds
            info.fetchedAt = Date()
            nowPlaying.info = info
        }
        nowPlayingQueue.async { [weak self] in
            NowPlayingControl.seek(to: seconds, on: source)
            DispatchQueue.main.async { self?.lastNowPlayingPoll = .distantPast }
        }
    }

    func setPlaybackVolume(_ value: Int) {
        guard let info = nowPlaying.info, NowPlayingParse.volumeTarget(for: info) != nil else { return }
        var updated = info
        updated.volume = value
        nowPlaying.info = updated
        nowPlayingQueue.async { [weak self] in
            NowPlayingControl.setVolume(value, on: info)
            DispatchQueue.main.async { self?.lastNowPlayingPoll = .distantPast }
        }
    }
}
