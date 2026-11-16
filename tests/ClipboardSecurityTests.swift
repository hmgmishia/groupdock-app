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

}
