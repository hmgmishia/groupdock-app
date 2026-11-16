import CoreGraphics

/// 文字・記号の大きさの定義（pt）。画面ごとに値を直書きせず、役割の名前で 1 か所に集める。
/// 値を変えるときは、ここだけを直す。
enum Typo {
    /// 最小の補助文字（再生中のごく小さな表示・ギャラリーの注記）。
    static let tiny: CGFloat = 8
    /// タイル下の名前・小さな注記・ページ表示。
    static let caption: CGFloat = 9
    /// タイトル・名前の標準（ウィジェットの題名など）。
    static let label: CGFloat = 10
    /// 小さな記号（ギャラリーの補助）。
    static let symbolSmall: CGFloat = 14
    /// 記号（再生ボタンなど）。
    static let symbol: CGFloat = 16
    /// ギャラリーの種類アイコン。
    static let glyph: CGFloat = 18
    /// ギャラリーの大きめの種類アイコン。
    static let glyphLarge: CGFloat = 20
    /// 再生中の大きな記号（サムネの代わり）。
    static let hero: CGFloat = 30
}
