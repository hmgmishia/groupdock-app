import Foundation

/// 音量・マイク・明るさのポップアップの寸法と文言（純粋）。
/// 以前は長い 1 文を折り返さず、幅が 260 以上に広がっていた。文を短く切り、1 行 24 文字以内に改行して、幅を抑える。
enum PopupLayout {
    /// ポップアップの幅。
    static let width: CGFloat = 220

    /// 固定の説明。`subject` は「デバイス」「ディスプレイ」。1 行 24 文字以内で、改行済み。
    static func pinnedNote(pinned: Bool, subject: String) -> String {
        if pinned {
            return "固定中：他の\(subject)が選ばれても、\nこの\(subject)へ戻します。"
        }
        return "固定していません：\n既定の\(subject)を操作します。"
    }

    /// 接続されていないときの説明。名前は長いことがあるので、先頭を切って改行する。
    static func unavailableNote(name: String) -> String {
        let short = name.count > 14 ? String(name.prefix(13)) + "…" : name
        return "「\(short)」は\n接続されていません。\nつなぐと、また使えます。"
    }
}
