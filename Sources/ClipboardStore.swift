import AppKit
import CryptoKit
import Foundation
import Observation

/// 件数の表示用（ウィジェットの文を作るスレッドから読むので、数字だけを別に持つ）。
enum ClipboardCount {
    private static let lock = NSLock()
    private static var value = 0
    static var current: Int {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

/// クリップボード履歴の監視・保存・コピーし直し。
/// - 見るのは `NSPasteboard.general.changeCount`（変わったときだけ中身を読む。0.5 秒ごとに数字だけ見る）。
/// - 保存は暗号化する（マスター鍵 1 つ＋件ごとの別の鍵。`ClipboardCrypto`）。鍵が取れないときは保存しない。
/// - 保存先は GroupDock 専用のフォルダ（自分だけが読める権限）。通信はしない。
/// - 機密の印（パスワード管理アプリなど）が付いた内容は保存しない。
@Observable
final class ClipboardStore {
    private(set) var entries: [ClipEntry] = [] {
        didSet { ClipboardCount.current = entries.count }
    }
    /// 一時停止中は何も記録しない（設定に保存する）。
    var paused: Bool {
        didSet { UserDefaults.standard.set(paused, forKey: "ClipboardPaused") }
    }
    /// 履歴の保存期間（設定に保存する）。変えたら、期限切れをすぐ消す。
    var retention: ClipboardRetention {
        didSet {
            UserDefaults.standard.set(retention.rawValue, forKey: "ClipboardRetention")
            if oldValue != retention { purgeExpired() }
        }
    }

    @ObservationIgnored private var lastChange = NSPasteboard.general.changeCount
    @ObservationIgnored private var timer: Timer?
    /// 自分でクリップボードへ入れたときの変更回数（自分の書き込みを履歴に足し直さないため）。
    @ObservationIgnored private var ownChange: Int?
    @ObservationIgnored private let keys: ClipboardKeyProvider
    /// 暗号化された索引があるのに開けない状態（鍵が違う・一時的に取れない）。この間は、既存の索引を上書きしない。
    @ObservationIgnored private var locked = false
    /// 保存期間の削除を最後に確かめた時刻（監視中は 1 分に 1 回だけ確かめる）。
    @ObservationIgnored private var lastExpiryCheck = Date.distantPast
    static var directoryOverride: URL?

    static var directory: URL {
        if let directoryOverride { return directoryOverride }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("GroupDock/Clipboard", isDirectory: true)
    }
    static var indexURL: URL { directory.appendingPathComponent("index.json") }
    static var imageDirectory: URL { directory.appendingPathComponent("images", isDirectory: true) }

    init(keys: ClipboardKeyProvider = KeychainKeyProvider()) {
        self.keys = keys
        paused = UserDefaults.standard.bool(forKey: "ClipboardPaused")
        retention = ClipboardRetention(storedRaw: UserDefaults.standard.string(forKey: "ClipboardRetention"))
        entries = load()
        // 平文だった旧い履歴は、読めたらすぐ暗号化して書き直す（画像も）。
        migrateIfNeeded()
        purgeSecrets()
        purgeExpired()
    }

    /// 保存期間を過ぎた項目を、画像のファイルごと消す（固定したものは残す）。変わったときだけ書く。
    /// 起動時・設定を変えたとき・監視中の履歴の更新のたびに呼ぶ。
    func purgeExpired(now: Date = Date()) {
        let kept = ClipboardHistory.removingExpired(entries, retention: retention, now: now)
        guard kept.count != entries.count, unlockedForWriting() else { return }
        let before = entries
        entries = kept
        for name in ClipboardHistory.droppedImages(before: before, after: kept) { Self.deleteImage(name) }
        save()
    }

    /// 以前の版で保存された、秘密に見えるテキストを履歴から消す（固定したものは残す）。変わったときだけ書く。
    private func purgeSecrets() {
        let cleaned = ClipboardHistory.purgingSecrets(entries)
        guard cleaned.count != entries.count, unlockedForWriting() else { return }
        entries = cleaned
        save()
    }

    // MARK: - 監視

    /// 監視を始める。ウィジェットが無い間は呼ばない（使わない機能の費用ゼロ）。
    func start() {
        guard timer == nil else { return }
        lastChange = NSPasteboard.general.changeCount
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    var isRunning: Bool { timer != nil }

    private func poll() {
        // 保存期間の削除は 1 分に 1 回（0.5 秒ごとに全件を調べない）。
        if Date().timeIntervalSince(lastExpiryCheck) >= 60 {
            lastExpiryCheck = Date()
            purgeExpired()
        }
        let board = NSPasteboard.general
        let count = board.changeCount
        guard count != lastChange else { return }
        lastChange = count
        if let own = ownChange, own == count { ownChange = nil; return }
        guard !paused else { return }
        guard let entry = Self.read(board, sourceBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier) else { return }
        add(entry.entry, imageData: entry.imageData)
    }

    /// クリップボードの中身を読む。機密の印があるか、コピー元がパスワード管理アプリなら nil。
    /// コピー元は、検知した時点で最前面のアプリ（0.5 秒ごとの監視なので近似。印が無い場合の保険）。
    /// 優先順位：ファイル → 画像（保存せずに直接入れた画像も含む）→ テキスト。
    static func read(_ board: NSPasteboard, sourceBundleID: String? = nil) -> (entry: ClipEntry, imageData: Data?)? {
        let types = (board.types ?? []).map(\.rawValue)
        guard ClipboardPolicy.shouldRecord(types: types, sourceBundleID: sourceBundleID) else { return nil }

        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty, let entry = ClipboardParse.files(urls.map(\.path)) {
            return (entry, nil)
        }
        // 画像：PNG があればそれを、無ければ TIFF 等から PNG に直す（スクリーンショットや「クリップボードへコピー」）。
        if let data = imageData(from: board),
           let entry = ClipboardParse.image(data, name: "\(UUID().uuidString).gdc", thumbnail: thumbnail(of: data)) {
            return (entry, data)
        }
        if let string = board.string(forType: .string), let entry = ClipboardParse.text(string) {
            return (entry, nil)
        }
        return nil
    }

    private static func imageData(from board: NSPasteboard) -> Data? {
        if let png = board.data(forType: .png) { return png }
        for type in [NSPasteboard.PasteboardType.tiff, NSPasteboard.PasteboardType("public.jpeg")] {
            if let data = board.data(forType: type), let image = NSImage(data: data),
               let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                return png
            }
        }
        return nil
    }

    /// 一覧用の超縮小画像（PNG）。元画像は復号して使う。
    /// 画面の倍率（Retina の 2 倍など）に左右されないよう、ピクセル数を指定したビットマップに描く。
    static func thumbnail(of data: Data) -> Data? {
        guard let image = NSImage(data: data), image.size.width > 0 else { return nil }
        let target = ClipboardThumbnail.size(for: image.size)
        let width = Int(target.width), height = Int(target.height)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - 履歴の更新

    func add(_ entry: ClipEntry, imageData: Data?) {
        // 鍵が取れなければ保存しない（平文で残さない）。
        guard keys.masterKey() != nil else {
            NSLog("GroupDock: clipboard history is not saved (the encryption key is unavailable)")
            return
        }
        guard unlockedForWriting() else { return }
        let before = entries
        var item = entry
        let existing = before.first { $0.fingerprint == entry.fingerprint }
        if item.kind == .image {
            if let existing {
                item.imageName = existing.imageName
                item.thumbnail = existing.thumbnail
            } else if let imageData, let name = item.imageName {
                writeImage(imageData, name: name)
            }
        }
        entries = ClipboardHistory.adding(item, to: before)
        for name in ClipboardHistory.droppedImages(before: before, after: entries) { Self.deleteImage(name) }
        save()
    }

    func remove(_ id: UUID) {
        guard unlockedForWriting() else { return }
        let before = entries
        entries.removeAll { $0.id == id }
        for name in ClipboardHistory.droppedImages(before: before, after: entries) { Self.deleteImage(name) }
        save()
    }

    func clear(keepPinned: Bool = true) {
        guard unlockedForWriting() else { return }
        let before = entries
        entries = keepPinned ? entries.filter(\.pinned) : []
        for name in ClipboardHistory.droppedImages(before: before, after: entries) { Self.deleteImage(name) }
        save()
    }

    func togglePin(_ id: UUID) {
        guard unlockedForWriting() else { return }
        entries = ClipboardHistory.togglingPin(id, in: entries)
        save()
    }

    /// 履歴の 1 件を、クリップボードへ入れ直す（履歴の先頭にも移る）。画像はここで初めて復号する。
    func copyBack(_ entry: ClipEntry) {
        guard unlockedForWriting() else { return }
        let board = NSPasteboard.general
        board.clearContents()
        switch entry.kind {
        case .text:
            board.setString(entry.text, forType: .string)
        case .files:
            let urls = entry.text.split(separator: "\n").map { URL(fileURLWithPath: String($0)) as NSURL }
            board.writeObjects(urls)
        case .image:
            if let data = originalImage(for: entry) {
                board.setData(data, forType: .png)
                if let image = NSImage(data: data), let tiff = image.tiffRepresentation { board.setData(tiff, forType: .tiff) }
            }
        }
        ownChange = board.changeCount
        lastChange = board.changeCount
        // 使った項目は、保存期間の数え直し（日時を今にする）。古い日時のまま戻すと、使った直後に期限切れで消える。
        var used = entry
        used.date = Date()
        entries = ClipboardHistory.adding(used, to: entries)
        save()
    }

    // MARK: - 画像・保存

    /// 一覧に出す縮小画像（暗号化された索引から読んだもの。復号は要らない）。
    func thumbnail(for entry: ClipEntry) -> NSImage? {
        entry.thumbnail.flatMap { NSImage(data: $0) }
    }

    /// 元の画像（暗号化されたファイルを復号する）。押したときだけ使う。
    func originalImage(for entry: ClipEntry) -> Data? {
        guard let name = entry.imageName, Self.isSafeImageName(name),
                let master = keys.masterKey(),
                let sealed = try? Data(contentsOf: Self.imageDirectory.appendingPathComponent(name)) else { return nil }
        if ClipboardCrypto.isSealed(sealed) { return try? ClipboardCrypto.open(sealed, master: master) }
        return sealed                                    // 旧い平文のまま（移行前）
    }

    /// 画像ファイルの名前として安全か（フォルダの外を指さない）。履歴の索引は外から書き換えられうるので、
    /// 読む・書く・消す・移行の全箇所でこの判定を通す。区切り文字・`..`・隠しファイル・NUL・長すぎる名前は拒否する。
    static func isSafeImageName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 100, !name.hasPrefix(".") else { return false }
        return !name.contains(where: { $0 == "/" || $0 == "\\" || $0 == "\u{0}" })
    }

    /// 履歴の画像を、選ばれた場所へ書き出す（暗号化されたファイルを、ここで復号して PNG にする）。
    /// 書き出したファイルは暗号化されない（利用者が選んだ場所の普通のファイル）。成功したら true。
    @discardableResult
    func exportImage(_ entry: ClipEntry, to url: URL) -> Bool {
        guard entry.kind == .image, let data = originalImage(for: entry) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            NSLog("GroupDock: cannot export the clipboard image: \(error.localizedDescription)")
            return false
        }
    }

    private static func prepareDirectories() {
        let manager = FileManager.default
        for url in [directory, imageDirectory] {
            try? manager.createDirectory(at: url, withIntermediateDirectories: true,
                                         attributes: [.posixPermissions: 0o700])
            try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
    }

    /// 画像を暗号化して書く。名前が安全でないときは書かない。
    private func writeImage(_ data: Data, name: String) {
        guard Self.isSafeImageName(name),
              let master = keys.masterKey(), let sealed = try? ClipboardCrypto.seal(data, master: master) else { return }
        Self.prepareDirectories()
        let url = Self.imageDirectory.appendingPathComponent(name)
        try? sealed.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func deleteImage(_ name: String) {
        // フォルダの外を消さない（名前を検証する）。
        guard isSafeImageName(name) else { return }
        try? FileManager.default.removeItem(at: imageDirectory.appendingPathComponent(name))
    }

    /// 索引を暗号化して書く（テキストも縮小画像もここに入るので、索引ごと暗号化する）。
    private func save() {
        // 開けない索引は上書きしない（上書きすると、既存の履歴が失われる）。
        guard !locked, let master = keys.masterKey() else { return }
        Self.prepareDirectories()
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let sealed = try ClipboardCrypto.seal(try encoder.encode(entries), master: master)
            try sealed.write(to: Self.indexURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.indexURL.path)
        } catch {
            NSLog("GroupDock: cannot save clipboard history: \(error.localizedDescription)")
        }
    }

    /// 暗号化された索引を読む。旧い平文の索引（JSON）も読める（移行のため）。
    /// 索引があるのに開けないときは、空を返し、`locked` を立てる（あとで鍵が戻れば読み直す）。
    private func load() -> [ClipEntry] {
        guard let data = try? Data(contentsOf: Self.indexURL) else { locked = false; return [] }
        let json: Data
        if ClipboardCrypto.isSealed(data) {
            guard let master = keys.masterKey(), let opened = try? ClipboardCrypto.open(data, master: master) else {
                locked = true
                return []
            }
            json = opened
        } else {
            json = data
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let list = try? decoder.decode([ClipEntry].self, from: json) else { locked = true; return [] }
        locked = false
        // 索引は外から書き換えられうる。フォルダの外を指す画像名の項目は、読み込みの時点で除く。
        return list.filter { $0.kind != .image || ($0.imageName.map(Self.isSafeImageName) ?? false) }
    }

    /// 書き込む前に呼ぶ。開けなかった索引は、鍵が戻っていれば読み直す。まだ開けなければ false（何も書かない）。
    private func unlockedForWriting() -> Bool {
        guard locked else { return true }
        let loaded = load()
        guard !locked else {
            NSLog("GroupDock: clipboard history is locked (the saved index cannot be opened); nothing is written")
            return false
        }
        entries = loaded
        migrateIfNeeded()
        return true
    }

    /// 索引か画像が平文のままなら、暗号化して書き直す。
    private func migrateIfNeeded() {
        guard keys.masterKey() != nil else { return }
        if let data = try? Data(contentsOf: Self.indexURL), !ClipboardCrypto.isSealed(data), !entries.isEmpty {
            // 旧い画像には縮小画像が無いので、ここで作り、元の画像は暗号化して書き直す。
            entries = entries.map { entry in
                guard entry.kind == .image, entry.thumbnail == nil, let name = entry.imageName,
                      let plain = try? Data(contentsOf: Self.imageDirectory.appendingPathComponent(name)),
                      !ClipboardCrypto.isSealed(plain) else { return entry }
                var copy = entry
                copy.thumbnail = Self.thumbnail(of: plain)
                writeImage(plain, name: name)
                return copy
            }
            save()
        }
    }
}
