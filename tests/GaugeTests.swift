import AppKit
import CryptoKit
import Observation

/// GaugeTests（`tests/main.swift` から呼ぶ。`check` と `failures` は main.swift のものを使う）。
func runGaugeTests() {
    // ゲージ上のホイール調整：音量・マイク・明るさを、詳細を開かずに調整する。値の計算は純粋関数。
    do {
        check("上へ回すと上がる（普通のマウス）", GaugeWheel.next(current: 50, deltaY: 1, precise: false) == 52)
        check("下へ回すと下がる", GaugeWheel.next(current: 50, deltaY: -1, precise: false) == 48)
        check("0 未満にならない", GaugeWheel.next(current: 1, deltaY: -10, precise: false) == 0)
        check("100 を超えない", GaugeWheel.next(current: 99, deltaY: 10, precise: false) == 100)
        check("トラックパッド（細かい量）は、小さく動く", GaugeWheel.next(current: 50, deltaY: 3, precise: true) == 51)
        check("ごく小さな量でも、少なくとも 1 動く（止まらない）", GaugeWheel.next(current: 50, deltaY: 0.1, precise: true) == 51)
        check("動かないとき（量 0）は、そのまま", GaugeWheel.next(current: 50, deltaY: 0, precise: true) == 50)
        check("一度に動く量は 10 まで（勢いよく回しても急に変わらない）", GaugeWheel.next(current: 50, deltaY: 100, precise: false) == 60)
        check("音量・マイク・明るさは、ホイールで調整できる",
              [WidgetKind.volume, .microphone, .brightness].allSatisfy { GaugeWheel.adjustable($0) })
        check("他の数値（CPU・メモリなど）は、調整できない",
              ![WidgetKind.cpu, .memory, .disk, .battery, .clock, .nowPlaying].contains { GaugeWheel.adjustable($0) })
    }

    // ホイール調整の競合：イベントごとに並行して「読む→計算→書く」をすると、取りこぼし・順序の逆転が起きる。
    // 量を足し合わせ、書く直前に 1 回だけ取り出す（GaugeAdjuster）。
    do {
        var adjuster = GaugeAdjuster()
        adjuster.add(deltaY: 1, precise: false)
        adjuster.add(deltaY: 1, precise: false)
        adjuster.add(deltaY: 1, precise: false)
        check("溜めた量を、まとめて 1 回で取り出せる", adjuster.take(current: 50) == 56)
        check("取り出したあとは、溜まりが空（同じ量を二重に書かない）", adjuster.take(current: 56) == nil)
        adjuster.add(deltaY: 1, precise: false)
        adjuster.add(deltaY: -1, precise: false)
        check("上と下が打ち消し合えば、書かない", adjuster.take(current: 50) == nil)
        adjuster.add(deltaY: 100, precise: false)
        adjuster.add(deltaY: 100, precise: false)
        check("溜めても、一度に動く量は上限まで（急に変わらない）", adjuster.take(current: 50) == 60)
        adjuster.add(deltaY: -100, precise: false)
        check("0 を下回らない", adjuster.take(current: 3) == 0)
        adjuster.add(deltaY: 3, precise: true)
        adjuster.add(deltaY: 3, precise: true)
        check("トラックパッドの細かい量も足し合わせる", adjuster.take(current: 50) == 52)
        // 書き込み中に来た量は、次の書き込みへ回る（落とさない）。
        adjuster.add(deltaY: 1, precise: false)
        let first = adjuster.take(current: 50)
        adjuster.add(deltaY: 1, precise: false)
        check("取り出し後に来た量は、次の取り出しで使われる", first == 52 && adjuster.take(current: 52) == 54)
        check("溜まりが無いときは、読みに行く必要が無い", { var empty = GaugeAdjuster(); return empty.hasPending == false }())
        check("溜まりが有れば、読みに行く", { var a = GaugeAdjuster(); a.add(deltaY: 1, precise: false); return a.hasPending }())
    }

    // ゲージのドラッグ：外周の帯と名前の所は「移動（D&D の並べ替え）」、中の面は「スライド調整」。Option キーなどの修飾は使わない。
    do {
        let tile = CGRect(x: 100, y: 100, width: 60, height: 60)
        check("面の中央はスライド調整", GaugeGrab.zone(at: CGPoint(x: 130, y: 130), tile: tile, labelled: false) == .slide)
        check("左の外周は移動", GaugeGrab.zone(at: CGPoint(x: 103, y: 130), tile: tile, labelled: false) == .move)
        check("右の外周は移動", GaugeGrab.zone(at: CGPoint(x: 157, y: 130), tile: tile, labelled: false) == .move)
        check("上の外周は移動", GaugeGrab.zone(at: CGPoint(x: 130, y: 157), tile: tile, labelled: false) == .move)
        check("下の外周は移動", GaugeGrab.zone(at: CGPoint(x: 130, y: 103), tile: tile, labelled: false) == .move)
        check("名前を出しているとき、名前の所は移動", GaugeGrab.zone(at: CGPoint(x: 130, y: 110), tile: tile, labelled: true) == .move)
        check("名前を出していなければ、同じ所もスライド調整", GaugeGrab.zone(at: CGPoint(x: 130, y: 112), tile: tile, labelled: false) == .slide)
        check("タイルの外は移動（調整しない）", GaugeGrab.zone(at: CGPoint(x: 10, y: 10), tile: tile, labelled: false) == .move)
        check("横長の面は、横にスライドする", GaugeGrab.axis(tile: CGRect(x: 0, y: 0, width: 120, height: 40)) == .horizontal)
        check("正方形の面は、縦にスライドする（上げると増える）", GaugeGrab.axis(tile: tile) == .vertical)
        check("長さが短くても、最低の移動量で割る（敏感すぎない）", GaugeGrab.percent(delta: 60, length: 60) == 50)
        check("最低の移動量の 1 回分で 100%", GaugeGrab.percent(delta: 120, length: 60) == 100)
        check("下げると減る", GaugeGrab.percent(delta: -60, length: 60) == -50)
        check("長い面は、その長さで割る", GaugeGrab.percent(delta: 100, length: 200) == 50)
        var slide = GaugeAdjuster()
        slide.addPercent(10); slide.addPercent(10)
        check("スライドの量は足し合わさり、1 回で大きく動ける", slide.take(current: 50, maxChange: 100) == 70)
        slide.addPercent(50)
        check("ホイールの上限（10）は、スライドには掛けない指定ができ、掛ければ 10 まで", slide.take(current: 50) == 60)
        slide.addPercent(-80)
        check("スライドでも 0 を下回らない", slide.take(current: 30, maxChange: 100) == 0)
        slide.addPercent(0.2)
        check("細かすぎて動かないときは書かない", slide.take(current: 50, maxChange: 100) == nil)
        // スライドの状態：押した所からの動きを、前回との差分（%）にして返す。
        var vertical = GaugeSlide(start: CGPoint(x: 130, y: 130), tile: tile)
        check("縦：上へ 60 点動くと +50%", vertical.move(to: CGPoint(x: 130, y: 190)) == 50)
        check("縦：続けて同じ位置なら差分は 0", vertical.move(to: CGPoint(x: 130, y: 190)) == 0)
        check("縦：下へ 30 点戻ると -25%", vertical.move(to: CGPoint(x: 130, y: 160)) == -25)
        check("縦：横の動きは無視する", vertical.move(to: CGPoint(x: 200, y: 160)) == 0)
        var horizontal = GaugeSlide(start: CGPoint(x: 10, y: 20), tile: CGRect(x: 0, y: 0, width: 240, height: 40))
        check("横長：右へ 120 点動くと +50%（長さ 240）", horizontal.move(to: CGPoint(x: 130, y: 20)) == 50)
        check("横長：左へ動くと減る", horizontal.move(to: CGPoint(x: 70, y: 20)) == -25)
        check("スライドと見なすのは 3 点以上動いてから（クリックを奪わない）",
              !GaugeSlide.isDrag(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 2, y: 0)) && GaugeSlide.isDrag(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 0, y: 3)))
    }

}
