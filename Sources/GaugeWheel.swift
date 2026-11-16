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
struct GaugeAdjuster {
    private var pending: [(deltaY: Double, precise: Bool)] = []

    /// 溜まりが有るか（無ければ、現在値を読みに行く必要が無い）。
    var hasPending: Bool { !pending.isEmpty }

    mutating func add(deltaY: Double, precise: Bool) {
        guard deltaY != 0 else { return }
        pending.append((deltaY, precise))
    }

    /// 溜めた量をまとめて、次の値にする。溜まりは空にする（同じ量を二重に書かない）。
    /// 動かない（溜まりが無い・打ち消し合って同じ値）ときは nil。
    /// 1 回で動く量は `GaugeWheel.maxStep` まで（溜めても、急には変わらない）。
    mutating func take(current: Int) -> Int? {
        guard hasPending else { return nil }
        var value = Double(current)
        for item in pending {
            let scaled = item.precise ? item.deltaY / 3 : item.deltaY * Double(GaugeWheel.step)
            value += scaled
        }
        pending.removeAll()
        var change = Int(value.rounded()) - current
        change = max(-GaugeWheel.maxStep, min(GaugeWheel.maxStep, change))
        let next = max(0, min(100, current + change))
        return next == current ? nil : next
    }
}
