import Foundation

/// ゲージ（リング・バー）の上でのホイール調整。音量・マイク・明るさを、詳細を開かずに調整する。
/// 値の計算は純粋関数。実際の書き込み（CoreAudio・DisplayServices）は、呼び出し側が裏のスレッドで行う。
enum GaugeWheel {
    /// 普通のマウスのホイール 1 目盛りあたりの変化（%）。
    static let step = 2
    /// 1 回のイベントで動く量の上限（%）。勢いよく回しても、急に変わらない。
    static let maxStep = 10

    /// ホイールの量（上が正）から、次の値（0〜100）を出す。
    /// - トラックパッド（`precise`）は細かい量が連続して来るので、そのまま小さく動かす。
    /// - 量が 0 でなければ、少なくとも 1 動く（小さな量で止まらない）。
    static func next(current: Int, deltaY: Double, precise: Bool) -> Int {
        guard deltaY != 0 else { return current }
        let scaled = precise ? deltaY / 3 : deltaY * Double(step)
        var change = Int(scaled.rounded())
        if change == 0 { change = deltaY > 0 ? 1 : -1 }
        change = max(-maxStep, min(maxStep, change))
        return max(0, min(100, current + change))
    }

    /// ホイールで調整できる種類（ゲージを持ち、値を操作できるもの）。
    static func adjustable(_ kind: WidgetKind) -> Bool {
        kind == .volume || kind == .microphone || kind == .brightness
    }
}

/// ホイールの量を足し合わせる（純粋な値）。イベントごとに「読む→計算→書く」を並行して行うと、
/// 同じ値を読んだ取りこぼしや、書く順序の逆転が起きる。量だけを溜め、書く側が直列キューで 1 回ずつ取り出す。
/// スライド（ドラッグ）の量は、割合（%）でそのまま足す。
struct GaugeAdjuster {
    private enum Item {
        case wheel(deltaY: Double, precise: Bool)
        case percent(Double)
    }
    private var pending: [Item] = []

    /// 溜まりが有るか（無ければ、現在値を読みに行く必要が無い）。
    var hasPending: Bool { !pending.isEmpty }

    mutating func add(deltaY: Double, precise: Bool) {
        guard deltaY != 0 else { return }
        pending.append(.wheel(deltaY: deltaY, precise: precise))
    }

    /// スライドの変化（%。上・右へ動かすと正）を足す。
    mutating func addPercent(_ value: Double) {
        guard value != 0 else { return }
        pending.append(.percent(value))
    }

    /// 溜めた量をまとめて、次の値にする。溜まりは空にする（同じ量を二重に書かない）。
    /// 動かない（溜まりが無い・打ち消し合って同じ値）ときは nil。
    /// 1 回で動く量は `maxChange` まで。ホイールは既定の `GaugeWheel.maxStep`（急には変わらない）、スライドは広く取る。
    mutating func take(current: Int, maxChange: Int = GaugeWheel.maxStep) -> Int? {
        guard hasPending else { return nil }
        var value = Double(current)
        for item in pending {
            switch item {
            case .wheel(let deltaY, let precise):
                value += precise ? deltaY / 3 : deltaY * Double(GaugeWheel.step)
            case .percent(let percent):
                value += percent
            }
        }
        pending.removeAll()
        var change = Int(value.rounded()) - current
        change = max(-maxChange, min(maxChange, change))
        let next = max(0, min(100, current + change))
        return next == current ? nil : next
    }
}

/// ゲージ上のドラッグの分け方（純粋関数）。並べ替え（D&D）とスライド調整を、掴む場所で分ける。修飾キーは使わない。
/// 外周の帯と、名前を出しているときの名前の所は「移動」。その内側の面は「スライド」。
enum GaugeGrab {
    enum Zone: Equatable { case move, slide }
    enum Axis: Equatable { case horizontal, vertical }

    /// 外周の幅。ここを掴むと並べ替え。
    static let edge: CGFloat = 8
    /// 名前（タイルの下）の高さ。名前を出しているときは、ここも移動。
    static let nameHeight: CGFloat = 16
    /// スライドで、全幅（100%）に当たる長さの下限。面が小さくても、敏感になりすぎない。
    static let minTravel: CGFloat = 120

    /// `tile` は画面座標（左下原点）のタイルの枠（名前の所を含む）。
    static func zone(at point: CGPoint, tile: CGRect, labelled: Bool) -> Zone {
        guard tile.contains(point) else { return .move }
        let face = faceRect(tile: tile, labelled: labelled)
        guard face.contains(point) else { return .move }
        let inner = face.insetBy(dx: edge, dy: edge)
        guard !inner.isEmpty, inner.contains(point) else { return .move }
        return .slide
    }

    /// 名前の所を除いた、ゲージの面の枠。
    static func faceRect(tile: CGRect, labelled: Bool) -> CGRect {
        labelled ? CGRect(x: tile.minX, y: tile.minY + nameHeight, width: tile.width, height: tile.height - nameHeight) : tile
    }

    /// スライドの向き。横長は横、それ以外は縦（上げると増える）。
    static func axis(tile: CGRect) -> Axis { tile.width > tile.height * 1.5 ? .horizontal : .vertical }

    /// 動いた量（点）から、値の変化（%）。`length` は面の長さ。短い面は `minTravel` で割る。
    static func percent(delta: CGFloat, length: CGFloat) -> Double {
        Double(delta / max(length, minTravel) * 100)
    }
}

/// ゲージ上のスライド（ドラッグ）の状態（純粋な値）。押した所から動いた分を、前回との差分（%）にして返す。
/// 値の書き込みは、差分を `GaugeAdjuster` に足して、直列キューで行う（ホイールと同じ経路）。
struct GaugeSlide {
    /// 何点動いたらスライドと見なすか。これ未満はクリックとして SwiftUI に任せる。
    static let threshold: CGFloat = 3

    let axis: GaugeGrab.Axis
    let length: CGFloat
    private var last: CGPoint

    init(start: CGPoint, tile: CGRect) {
        axis = GaugeGrab.axis(tile: tile)
        length = axis == .horizontal ? tile.width : tile.height
        last = start
    }

    static func isDrag(from start: CGPoint, to point: CGPoint) -> Bool {
        hypot(point.x - start.x, point.y - start.y) >= threshold
    }

    /// 画面座標（上が正）で `point` へ動いたときの、前回からの変化（%）。軸と違う向きの動きは無視する。
    mutating func move(to point: CGPoint) -> Double {
        let delta = axis == .horizontal ? point.x - last.x : point.y - last.y
        if axis == .horizontal { last.x = point.x } else { last.y = point.y }
        return GaugeGrab.percent(delta: delta, length: length)
    }
}
