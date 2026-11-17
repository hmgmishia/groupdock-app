import AppKit
import CryptoKit
import Observation

/// ClipboardSecurityTests（`tests/main.swift` から呼ぶ。`check` と `failures` は main.swift のものを使う）。
func runClipboardSecurityTests() {
    // クリップボードのセキュリティ：印の無い秘密（鍵・トークン・カード番号・パスワード状）と、パスワード管理アプリからのコピーを保存しない。
    do {
        check("秘密鍵のブロックは秘密", ClipboardPolicy.looksSecret("-----BEGIN RSA PRIVATE KEY-----\nMIIE...\n-----END RSA PRIVATE KEY-----"))
        check("GitHub のトークンは秘密", ClipboardPolicy.looksSecret("ghp_" + String(repeating: "a", count: 36)))
        check("AWS のアクセスキーは秘密", ClipboardPolicy.looksSecret("AKIAIOSFODNN7EXAMPLE"))
        check("sk- で始まる API キーは秘密", ClipboardPolicy.looksSecret("sk-" + String(repeating: "A1b2", count: 8)))
        check("JWT は秘密", ClipboardPolicy.looksSecret("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"))
        check("Luhn を満たすカード番号は秘密", ClipboardPolicy.looksSecret("4111 1111 1111 1111"))
        check("Luhn を満たさない数字は秘密でない", !ClipboardPolicy.looksSecret("4111111111111112"))
        check("パスワード状（記号・大小・数字）は秘密", ClipboardPolicy.looksSecret("Tr0ub4dor&3xyz"))
        check("ふつうの文は秘密でない", !ClipboardPolicy.looksSecret("明日の会議は 10 時からです"))
        check("英文は秘密でない", !ClipboardPolicy.looksSecret("hello world"))
        check("URL は秘密でない", !ClipboardPolicy.looksSecret("https://example.com/Path1?a=B2"))
        check("パスは秘密でない", !ClipboardPolicy.looksSecret("/Users/me/Documents/Report2024"))
        check("メールアドレスは秘密でない", !ClipboardPolicy.looksSecret("John.Doe1@example.com"))
        check("識別子は秘密でない（記号なし）", !ClipboardPolicy.looksSecret("ClipboardPolicy2"))
        check("パスワード管理アプリからのコピーは保存しない",
              !ClipboardPolicy.shouldRecord(types: ["public.utf8-plain-text"], sourceBundleID: "com.1password.1password"))
        check("Keychain Access からのコピーは保存しない",
              !ClipboardPolicy.shouldRecord(types: ["public.utf8-plain-text"], sourceBundleID: "com.apple.keychainaccess"))
        check("ふつうのアプリからのコピーは保存する",
              ClipboardPolicy.shouldRecord(types: ["public.utf8-plain-text"], sourceBundleID: "com.apple.Safari"))
        check("コピー元が分からなくても、印が無ければ保存する", ClipboardPolicy.shouldRecord(types: ["public.utf8-plain-text"], sourceBundleID: nil))
        check("秘密に見えるテキストは、履歴の 1 件にしない", ClipboardParse.text("ghp_" + String(repeating: "a", count: 36)) == nil)
        check("ふつうのテキストは、履歴の 1 件になる", ClipboardParse.text("議事録") != nil)
        // 既に履歴にある分の掃除（固定したものは、利用者が選んだので残す）。
        let secret = ClipEntry(kind: .text, text: "AKIAIOSFODNN7EXAMPLE", fingerprint: "text:AKIAIOSFODNN7EXAMPLE")
        let plain = ClipEntry(kind: .text, text: "議事録", fingerprint: "text:議事録")
        var pinnedSecret = ClipEntry(kind: .text, text: "AKIAIOSFODNN7EXAMPLE", fingerprint: "text:pinned")
        pinnedSecret.pinned = true
        let purged = ClipboardHistory.purgingSecrets([secret, plain, pinnedSecret])
        check("掃除で、秘密に見える履歴が消える", !purged.contains { $0.id == secret.id })
        check("掃除で、ふつうの履歴は残る", purged.contains { $0.id == plain.id })
        check("掃除でも、固定したものは残す", purged.contains { $0.id == pinnedSecret.id })
        check("画像・ファイルは、掃除の対象にしない",
              ClipboardHistory.purgingSecrets([ClipEntry(kind: .files, text: "/tmp/AKIAIOSFODNN7EXAMPLE", fingerprint: "files:x")]).count == 1)
    }

    // @Observable：使った値だけが再描画のきっかけになる（読んでいない値の変更では通知されない）。
    do {
        let state = NowPlayingState()
        var firedByHint = 0
        withObservationTracking { _ = state.info } onChange: { firedByHint += 1 }
        state.hint = "ブラウザの許可が要ります"
        check("再生状態：読んでいない値（hint）の変更では通知されない", firedByHint == 0)
        var firedByInfo = 0
        withObservationTracking { _ = state.info } onChange: { firedByInfo += 1 }
        state.info = PlaybackInfo(source: .music, title: "a", artist: "", playing: true, volume: nil, artwork: nil)
        check("再生状態：読んだ値（info）の変更では通知される", firedByInfo == 1)

        let clipboard = ClipboardStore(keys: FixedKeyProvider(key: nil))
        var firedByPaused = 0
        withObservationTracking { _ = clipboard.entries } onChange: { firedByPaused += 1 }
        clipboard.paused = true
        check("クリップボード：読んでいない値（paused）の変更では通知されない", firedByPaused == 0)
        clipboard.paused = false
    }

    // 画像名の検証（パストラバーサル）：履歴の画像名がフォルダの外を指していても、読まない・書かない・消さない。
    do {
        check("ふつうの名前は安全", ClipboardStore.isSafeImageName("3F2504E0-4F89-11D3-9A0C-0305E82C3301.gdc"))
        check("../ を含む名前は危険", !ClipboardStore.isSafeImageName("../index.json"))
        check("/ を含む名前は危険", !ClipboardStore.isSafeImageName("a/b.gdc"))
        check("バックスラッシュを含む名前は危険", !ClipboardStore.isSafeImageName("a\\b.gdc"))
        check("空の名前は危険", !ClipboardStore.isSafeImageName(""))
        check("ドットで始まる名前は危険（隠しファイル・. ..）", !ClipboardStore.isSafeImageName(".hidden") && !ClipboardStore.isSafeImageName(".."))
        check("NUL を含む名前は危険", !ClipboardStore.isSafeImageName("a\u{0}b.gdc"))
        check("長すぎる名前は危険", !ClipboardStore.isSafeImageName(String(repeating: "a", count: 200)))

        // 旧い平文の索引に、フォルダの外を指す画像名を入れる。移行が、その外のファイルを読んで暗号化し直してはいけない。
        let attackDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("groupdock-clip-attack-\(UUID().uuidString)")
        ClipboardStore.directoryOverride = attackDir
        try? FileManager.default.createDirectory(at: ClipboardStore.imageDirectory, withIntermediateDirectories: true)
        let outside = attackDir.appendingPathComponent("outside.txt")
        let outsidePlain = Data("フォルダの外のファイル".utf8)
        try? outsidePlain.write(to: outside)
        let evil = ClipEntry(kind: .image, imageName: "../outside.txt", fingerprint: "image:evil")
        let evilEncoder = JSONEncoder()
        evilEncoder.dateEncodingStrategy = .iso8601
        try? evilEncoder.encode([evil]).write(to: ClipboardStore.indexURL)
        let victim = ClipboardStore(keys: FixedKeyProvider(key: ClipboardCrypto.newMasterKey()))
        let outsideAfter = (try? Data(contentsOf: outside)) ?? Data()
        check("移行が、フォルダの外のファイルを書き換えない", outsideAfter == outsidePlain)
        check("危険な画像名の履歴は、読み込みで除く", !victim.entries.contains { $0.imageName == "../outside.txt" })
        check("危険な画像名は、復号の経路でも読まない", victim.originalImage(for: evil) == nil)
        try? FileManager.default.removeItem(at: attackDir)
    }

    // コピー元の除外：パスワード管理アプリを増やした分と、ポップアップの注記（実装と合わせる）。
    do {
        let apps = [
            "ch.protonmail.pass", "me.proton.pass.electron", "com.nordpass.macos", "com.callpod.keepermac",
            "com.siber.roboform", "com.stickypassword.StickyPassword", "com.zoho.vault",
            "com.1password.1password", "com.bitwarden.desktop", "org.keepassxc.keepassxc",
        ]
        for app in apps {
            check("パスワード管理アプリからのコピーは記録しない: \(app)",
                  !ClipboardPolicy.shouldRecord(types: ["public.utf8-plain-text"], sourceBundleID: app))
        }
        check("無関係のアプリは記録する", ClipboardPolicy.shouldRecord(types: ["public.utf8-plain-text"], sourceBundleID: "com.apple.TextEdit"))
        check("名前が似ているだけのアプリは除外しない（前方一致の取り違え）",
              ClipboardPolicy.shouldRecord(types: ["public.utf8-plain-text"], sourceBundleID: "com.example.keeperlike"))
        let note = ClipboardPolicy.popupNote
        check("注記に、コピー元の除外を書く", note.contains("パスワード管理アプリ"))
        check("注記に、秘密に見える内容の除外を書く", note.contains("秘密に見える"))
        check("注記に、見逃しがあることを書く", note.contains("見逃"))
        check("注記は改行で短く区切る（1 行 24 文字以内）", note.split(separator: "\n").allSatisfy { $0.count <= 24 })
    }

    // 保存期間：期限を過ぎた項目を消す。固定した項目は消さない。画像のファイルも一緒に消す。
    do {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func entry(_ text: String, ageSeconds: Double, pinned: Bool = false) -> ClipEntry {
            var e = ClipEntry(kind: .text, text: text, fingerprint: "text:" + text)
            e.date = now.addingTimeInterval(-ageSeconds)
            e.pinned = pinned
            return e
        }
        check("選択肢は 無期限・1 時間・1 日・7 日・30 日",
              ClipboardRetention.allCases.map(\.seconds) == [nil, 3600, 86_400, 604_800, 2_592_000])
        check("既定は 7 日", ClipboardRetention.default == .week)
        check("知らない値は既定に戻す", ClipboardRetention(storedRaw: "bogus") == .week && ClipboardRetention(storedRaw: nil) == .week)
        check("保存した値を読み戻せる", ClipboardRetention(storedRaw: ClipboardRetention.hour.rawValue) == .hour)
        let list = [entry("新しい", ageSeconds: 60), entry("1 日と少し", ageSeconds: 90_000), entry("固定の古いもの", ageSeconds: 5_000_000, pinned: true), entry("古い", ageSeconds: 5_000_000)]
        let day = ClipboardHistory.removingExpired(list, retention: .day, now: now).map(\.text)
        check("1 日：新しいものと固定は残り、期限切れは消える", day == ["新しい", "固定の古いもの"])
        check("無期限：何も消えない", ClipboardHistory.removingExpired(list, retention: .forever, now: now).count == 4)
        check("1 時間：固定以外の古いものが消える",
              ClipboardHistory.removingExpired(list, retention: .hour, now: now).map(\.text) == ["新しい", "固定の古いもの"])
        check("30 日：90000 秒（約 1 日）のものは残る",
              ClipboardHistory.removingExpired(list, retention: .month, now: now).map(\.text) == ["新しい", "1 日と少し", "固定の古いもの"])
        check("ちょうど期限のものは残す（境界）",
              ClipboardHistory.removingExpired([entry("境界", ageSeconds: 3600)], retention: .hour, now: now).count == 1)
        check("期限を 1 秒過ぎたものは消える",
              ClipboardHistory.removingExpired([entry("過ぎた", ageSeconds: 3601)], retention: .hour, now: now).isEmpty)

        // 画像のファイルも消える（保存先はテスト用のフォルダ）。
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("groupdock-clip-retention-\(UUID().uuidString)")
        ClipboardStore.directoryOverride = dir
        let store = ClipboardStore(keys: FixedKeyProvider(key: ClipboardCrypto.newMasterKey()))
        let png = Data([1, 2, 3, 4])
        var oldImage = ClipboardParse.image(png, name: "old-image.gdc", thumbnail: Data([9]))!
        oldImage.date = Date().addingTimeInterval(-3 * 86_400)
        store.add(oldImage, imageData: png)
        store.add(ClipboardParse.text("残る")!, imageData: nil)
        store.retention = .day
        store.purgeExpired()
        let imageFile = ClipboardStore.imageDirectory.appendingPathComponent("old-image.gdc").path
        check("期限切れの画像の履歴が消える", !store.entries.contains { $0.kind == .image })
        check("期限切れの画像のファイルも消える", !FileManager.default.fileExists(atPath: imageFile))
        check("期限内のテキストは残る", store.entries.contains { $0.text == "残る" })

        // 使った項目は、期限の数え直し：コピーし直したら日時を今にする（使った直後に消えない）。
        let reuseDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("groupdock-clip-reuse-\(UUID().uuidString)")
        ClipboardStore.directoryOverride = reuseDir
        let reuse = ClipboardStore(keys: FixedKeyProvider(key: ClipboardCrypto.newMasterKey()))
        reuse.retention = .week
        var almostExpired = ClipboardParse.text("期限間際")!
        almostExpired.date = Date().addingTimeInterval(-6.9 * 86_400)
        reuse.add(almostExpired, imageData: nil)
        check("追加すると、日時は元のまま（期限間際）", reuse.entries.first.map { Date().timeIntervalSince($0.date) > 6 * 86_400 } == true)
        reuse.copyBack(reuse.entries[0])
        check("コピーし直すと、日時が今になる", reuse.entries.first.map { Date().timeIntervalSince($0.date) < 60 } == true)
        reuse.purgeExpired(now: Date().addingTimeInterval(2 * 86_400))
        check("コピーし直した項目は、2 日後でも期限内で残る", reuse.entries.contains { $0.text == "期限間際" })
        try? FileManager.default.removeItem(at: reuseDir)
        try? FileManager.default.removeItem(at: dir)
    }
}
