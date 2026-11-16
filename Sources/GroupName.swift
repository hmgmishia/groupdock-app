import Foundation

/// グループ名の確定規則（純粋）。帯のタイル・吹き出しの見出し・グループの設定で、同じ規則を使う。
enum GroupName {
    /// 名前の最大文字数。
    static let maxLength = 40

    /// 入力された文字を、保存する名前にする。
    /// 改行は空白にして 1 行にし、前後の空白を除く。空なら元の名前に戻す。長すぎれば切る。
    static func commit(_ input: String, previous: String) -> String {
        let oneLine = input.replacingOccurrences(of: "\n", with: " ")
        let trimmed = oneLine.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return previous }
        return String(trimmed.prefix(maxLength))
    }
}
