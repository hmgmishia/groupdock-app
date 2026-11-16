import CryptoKit
import Foundation
import Security

/// クリップボード履歴の暗号化（純粋な部品）。
/// - マスター鍵は 1 つ。件ごとに乱数のソルトを作り、HKDF で「その件だけの鍵」を導く。
/// - 暗号は AES-GCM（改ざんされたら開けない）。通信しない。private framework も使わない。
/// - 保存形式：`GDC1`（4 バイト）+ ソルト（16 バイト）+ AES-GCM の結合データ（nonce + 暗号文 + タグ）。
enum ClipboardCrypto {
    static let magic = Data("GDC1".utf8)
    static let saltLength = 16
    private static let info = Data("GroupDock clipboard item".utf8)

    enum Failure: Error { case notEncrypted, truncated, wrongKey }

    /// 暗号化したデータか（先頭の印で見分ける。平文の旧履歴と区別するため）。
    static func isSealed(_ data: Data) -> Bool { data.starts(with: magic) }

    /// マスター鍵から、ソルトごとの鍵を導く。
    static func itemKey(master: SymmetricKey, salt: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: master, salt: salt, info: info, outputByteCount: 32)
    }

    /// 暗号化する。毎回新しいソルトを使うので、同じ内容でも暗号文は毎回変わる。
    static func seal(_ plain: Data, master: SymmetricKey, salt: Data? = nil) throws -> Data {
        let salt = salt ?? Data((0..<saltLength).map { _ in UInt8.random(in: .min ... .max) })
        let box = try AES.GCM.seal(plain, using: itemKey(master: master, salt: salt))
        guard let combined = box.combined else { throw Failure.truncated }
        return magic + salt + combined
    }

    /// 復号する。鍵が違う・改ざん・途中で切れているときは例外。
    static func open(_ sealed: Data, master: SymmetricKey) throws -> Data {
        guard isSealed(sealed) else { throw Failure.notEncrypted }
        let body = sealed.dropFirst(magic.count)
        guard body.count > saltLength else { throw Failure.truncated }
        let salt = Data(body.prefix(saltLength))
        let combined = Data(body.dropFirst(saltLength))
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(box, using: itemKey(master: master, salt: salt))
        } catch {
            throw Failure.wrongKey
        }
    }

    static func newMasterKey() -> SymmetricKey { SymmetricKey(size: .bits256) }
}

/// マスター鍵の置き場。本番はキーチェーン、テストは差し替える。
protocol ClipboardKeyProvider {
    func masterKey() -> SymmetricKey?
}

/// キーチェーンの 1 項目（GroupDock だけが取り出せる、このデバイスの中だけの項目）。
/// 無ければ新しい鍵を作って置く。取り出せないとき（許可されない等）は nil を返し、呼び出し側は保存しない。
struct KeychainKeyProvider: ClipboardKeyProvider {
    static let service = "dev.hmgm.GroupDock.clipboard"
    static let account = "master-key"

    func masterKey() -> SymmetricKey? {
        if let existing = read() { return SymmetricKey(data: existing) }
        let key = ClipboardCrypto.newMasterKey()
        let data = key.withUnsafeBytes { Data($0) }
        return write(data) ? key : nil
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
    }

    private func read() -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private func write(_ data: Data) -> Bool {
        var query = baseQuery
        query[kSecValueData as String] = data
        // このデバイスの中だけ（バックアップや他の端末へ移さない）、ロック解除後に読める。
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }
}

/// テスト用：固定の鍵を返す（キーチェーンに触れない）。
struct FixedKeyProvider: ClipboardKeyProvider {
    let key: SymmetricKey?
    func masterKey() -> SymmetricKey? { key }
}
