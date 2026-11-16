import CoreGraphics

/// グループの吹き出しをどこに出すか（純粋関数なのでテストできる）。
enum BubblePlacement {
    /// 帯の枠（表示されている位置）を基準に、吹き出しの左下の点を決める。
    /// 下置きなら帯の真上、左置きなら帯の右、右置きなら帯の左。
    /// `tile`: 開いたグループのタイルの枠（画面座標）。あれば、帯の中央ではなくそのタイルに揃える。
    static func origin(
        anchor: CGRect,
        size: CGSize,
        position: String,
        gap: CGFloat = 8,
        tile: CGRect? = nil
    ) -> CGPoint {
        let center = tile ?? anchor
        switch position {
        case "left":
            return CGPoint(x: anchor.maxX + gap, y: center.midY - size.height / 2)
        case "right":
            return CGPoint(x: anchor.minX - size.width - gap, y: center.midY - size.height / 2)
        default:
            return CGPoint(x: center.midX - size.width / 2, y: anchor.maxY + gap)
        }
    }
}
