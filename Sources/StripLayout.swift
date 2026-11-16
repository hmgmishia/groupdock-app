import AppKit
import CoreGraphics
import Foundation
import SwiftUI

/// 帯と吹き出しの配置。状態（Store）から枠を**計算するだけ**で、描画結果は読まない。
/// 描画・当たり判定・ウィンドウの大きさは、すべてここで出した同じ枠を使う。
/// SwiftUI の測定（GeometryReader / PreferenceKey）を状態へ書き戻さないので、
/// レイアウト中に状態が変わって固まる・落ちることがない。

/// 帯の区画。はみ出すときのページ切り替えは、区画ごとに別々のページを持つ（FF14 のホットバーのように）。
enum StripSection: String, Equatable, Hashable {
    case widgets, apps
}

/// 帯に並べる 1 つ分。
struct StripEntry: Identifiable, Equatable {
    enum Kind: Equatable {
        case widget(UUID)
        case pinned(AppRef)
        case kept(AppRef)
        case group(UUID)
        case running(AppRef)
        case history, trash, settings, separator
        /// ページ送り（区画・いまのページ・ページ数）。ページ切り替えの方式で、収まらないときだけ付く。
        case pager(StripSection, Int, Int)
    }

    let id: String
    let kind: Kind
    let size: CGSize
    /// ページ切り替えの区画（ブロック）に属する項目の印。区画は `lanes` 本の列に並び、長さ `blockLength` で固定する
    /// （ページごとに帯の大きさが変わらない）。`blockLength` が 0 なら、ふつうの 1 列の項目。
    var blockLength: CGFloat = 0
    var lane: Int = 0
    var lanes: Int = 1
    var slot: Int = 0
}

/// 帯の枠（ウィンドウ内・左上原点）。
struct StripLayout: Equatable {
    struct Placed: Identifiable, Equatable {
        let entry: StripEntry
        let frame: CGRect
        var id: String { entry.id }
    }

    /// 仕切り線の太さ（見た目）と、線の両側に持たせる余白（右クリックの判定の広さ）。
    static let separatorThickness: CGFloat = 1
    static let separatorMargin: CGFloat = 6

    /// 影を描くためにウィンドウの縁に空ける余白。
    static let shadowMargin: CGFloat = 8

    let placed: [Placed]
    let size: CGSize

    var order: [String] { placed.map(\.id) }
    var frames: [String: CGRect] {
        Dictionary(placed.map { ($0.id, $0.frame) }, uniquingKeysWith: { first, _ in first })
    }

    /// `opening`: ドラッグ中、その相手の前（または後）に `extra` だけ隙間を空ける（周りが退くプレビュー）。
    /// `blockLength` が 0 より大きい項目は、ページ切り替えの区画（ブロック）。区画は `lanes` 本の列に分けて並べ、
    /// 区画の長さは `blockLength` で固定する（ページごとに帯の大きさが変わらない）。
    static func make(
        _ entries: [StripEntry], vertical: Bool, gap: CGFloat,
        opening: (id: String, after: Bool)? = nil, extra: CGFloat = 0, padding: CGFloat = 6
    ) -> StripLayout {
        let inset = shadowMargin + padding
        func crossOf(_ entry: StripEntry) -> CGFloat { vertical ? entry.size.width : entry.size.height }
        func mainOf(_ entry: StripEntry) -> CGFloat { vertical ? entry.size.height : entry.size.width }
        let blockEntries = entries.filter { $0.blockLength > 0 }
        let laneCross = blockEntries.map(crossOf).max() ?? 0
        let maxLanes = blockEntries.map(\.lanes).max() ?? 1
        let blockCross = blockEntries.isEmpty ? 0 : CGFloat(maxLanes) * laneCross + CGFloat(maxLanes - 1) * gap
        let cross = max(entries.filter { $0.blockLength == 0 }.map(crossOf).max() ?? 0, blockCross)

        var cursor = inset
        var placed: [Placed] = []
        var inBlock = false
        var laneCursors: [CGFloat] = []
        var blockEnd = cursor
        func closeBlock() {
            guard inBlock else { return }
            cursor = max(blockEnd, laneCursors.max() ?? blockEnd)
            inBlock = false
        }
        for entry in entries {
            if entry.blockLength > 0 {
                if !inBlock || (entry.slot == 0 && entry.lane == 0) {
                    closeBlock()
                    inBlock = true
                    laneCursors = [CGFloat](repeating: cursor, count: max(1, entry.lanes))
                    blockEnd = cursor + entry.blockLength
                }
                let lane = min(entry.lane, laneCursors.count - 1)
                if let opening, opening.id == entry.id, !opening.after { laneCursors[lane] += extra }
                let width = CGFloat(entry.lanes) * laneCross + CGFloat(entry.lanes - 1) * gap
                let crossStart = inset + (cross - width) / 2 + CGFloat(lane) * (laneCross + gap) + (laneCross - crossOf(entry)) / 2
                let frame = vertical
                    ? CGRect(x: crossStart, y: laneCursors[lane], width: entry.size.width, height: entry.size.height)
                    : CGRect(x: laneCursors[lane], y: crossStart, width: entry.size.width, height: entry.size.height)
                laneCursors[lane] += mainOf(entry) + gap
                if let opening, opening.id == entry.id, opening.after { laneCursors[lane] += extra }
                placed.append(Placed(entry: entry, frame: frame))
                continue
            }
            closeBlock()
            if let opening, opening.id == entry.id, !opening.after { cursor += extra }
            let frame: CGRect
            if vertical {
                frame = CGRect(
                    x: inset + (cross - entry.size.width) / 2, y: cursor,
                    width: entry.size.width, height: entry.size.height)
                cursor += entry.size.height + gap
            } else {
                frame = CGRect(
                    x: cursor, y: inset + (cross - entry.size.height) / 2,
                    width: entry.size.width, height: entry.size.height)
                cursor += entry.size.width + gap
            }
            placed.append(Placed(entry: entry, frame: frame))
            if let opening, opening.id == entry.id, opening.after { cursor += extra }
        }
        closeBlock()
        let main = max(0, cursor - gap - inset)
        let size = vertical
            ? CGSize(width: cross + inset * 2, height: main + inset * 2)
            : CGSize(width: main + inset * 2, height: cross + inset * 2)
        return StripLayout(placed: placed, size: size)
    }
}

/// はみ出すときの「ページ切り替え」（純粋関数）。FF14 のホットバーのように、収まらない分を次のページへ送る。
/// アプリとウィジェットは別々の区画で、別々にページを持つ。
enum StripPaging {
    /// ページ送りの長さ（帯の長さ方向）。
    static let pagerLength: CGFloat = 26

    /// 格子のページ分け。ページに入る項目は、ページごとに前から順に詰めて決める（1 本が `budget` に収まらなくなったら次の本、本が尽きたら次のページ）。
    /// そのうえで、ページの項目を `lanes` 本の連続した塊へ、いちばん長い本が最短になるよう均等に配り直す。
    /// これで、予算に余裕があっても、設定の本数どおりに分かれる（項目が本数より少ないときだけ、項目の数まで）。
    /// 全ページで同じ大きさにするため、`pageLength`（全ページでいちばん長い本の長さ）と `lanes` は、全ページ共通。
    struct Grid: Equatable {
        var pages: [[Int]]          // ページごとの項目の番号
        var lane: [Int]             // 項目ごとの本の番号
        var slot: [Int]             // 項目ごとの、本の中の位置
        var lanes: Int
        var pageLength: CGFloat
    }

    static func grid(lengths: [CGFloat], lines: Int, budget: CGFloat) -> Grid {
        let lines = max(1, lines)
        // 1. ページに入る項目を決める（本を順に埋める）。
        var pages: [[Int]] = []
        var current: [Int] = []
        var laneIndex = 0, slotIndex = 0
        var used: CGFloat = 0
        for (index, length) in lengths.enumerated() {
            // 1 本に 1 つも入らなくても、最低 1 つは置く（進まなくならない）。
            if slotIndex > 0, used + length > budget {
                laneIndex += 1
                used = 0
                slotIndex = 0
                if laneIndex >= lines {
                    pages.append(current)
                    current = []
                    laneIndex = 0
                }
            }
            current.append(index)
            used += length
            slotIndex += 1
        }
        pages.append(current)
        // 2. 本の数は、項目の数に関係なく設定どおり（空の本で幅を保つ）。全ページ共通で、ウィジェットとアプリで同じ。
        let lanes = lines
        // 3. 各ページを、lanes 本へ均等に配り直す。
        var lane = [Int](repeating: 0, count: lengths.count)
        var slot = [Int](repeating: 0, count: lengths.count)
        var longest: CGFloat = 0
        for page in pages where !page.isEmpty {
            let split = balanced(lengths: page.map { lengths[$0] }, lanes: min(lanes, page.count))
            for (offset, index) in page.enumerated() {
                lane[index] = split.lane[offset]
                slot[index] = split.slot[offset]
            }
            longest = max(longest, split.longest)
        }
        return Grid(pages: pages, lane: lane, slot: slot, lanes: lanes, pageLength: longest)
    }

    /// 連続した項目を `lanes` 本に、いちばん長い本が最短になるよう分ける。どの本にも最低 1 つは入る。
    static func balanced(lengths: [CGFloat], lanes: Int) -> (lane: [Int], slot: [Int], longest: CGFloat) {
        let n = lengths.count
        let lanes = max(1, min(lanes, n))
        func split(limit: CGFloat) -> (lane: [Int], slot: [Int], longest: CGFloat)? {
            var lane = [Int](repeating: 0, count: n)
            var slot = [Int](repeating: 0, count: n)
            var c = 0, s = 0
            var used: CGFloat = 0
            var longest: CGFloat = 0
            for i in 0..<n {
                // 残りの項目が残りの本と同じ数なら、1 項目ずつ別の本へ（どの本も空にしない）。
                let mustBreak = s > 0 && (n - i) <= (lanes - 1 - c)
                if s > 0, used + lengths[i] > limit || mustBreak {
                    c += 1
                    s = 0
                    used = 0
                }
                if c >= lanes { return nil }
                lane[i] = c
                slot[i] = s
                used += lengths[i]
                s += 1
                longest = max(longest, used)
            }
            return (lane, slot, longest)
        }
        // 上限を二分探索する（実数のまま。反復の回数を固定して、必ず終わる）。
        var low = lengths.max() ?? 0
        var high = lengths.reduce(0, +)
        var best = split(limit: high)
        for _ in 0..<40 {
            let mid = (low + high) / 2
            if let found = split(limit: mid) { best = found; high = mid } else { low = mid }
        }
        return best ?? (lane: [Int](repeating: 0, count: n), slot: Array(0..<n), longest: high)
    }

    /// ページを前後に送る（端は反対側へ戻る）。
    static func turned(page: Int, count: Int, by delta: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((page + delta) % count + count) % count
    }

    /// 1 ページの予算に収まる分だけ前から詰めて、ページに分ける。
    /// 1 つも入らなくても、1 ページに最低 1 つは置く（進まなくならない）。空なら、空の 1 ページ。
    static func pages(lengths: [CGFloat], budget: CGFloat) -> [Range<Int>] {
        guard !lengths.isEmpty else { return [0..<0] }
        var result: [Range<Int>] = []
        var start = 0
        var used: CGFloat = 0
        for (index, length) in lengths.enumerated() {
            if index > start, used + length > budget {
                result.append(start..<index)
                start = index
                used = 0
            }
            used += length
        }
        result.append(start..<lengths.count)
        return result
    }

    /// ページ番号を範囲に収める（項目が減っても落ちない）。
    static func clamp(_ page: Int, count: Int) -> Int { max(0, min(page, count - 1)) }

    /// ウィジェットとアプリで、残りの長さを分け合う。短い側は必要な分だけ取り、残りをもう一方へ回す。
    static func budgets(widgets: CGFloat, apps: CGFloat, available: CGFloat) -> (widgets: CGFloat, apps: CGFloat) {
        let half = available / 2
        if widgets <= half { return (widgets, available - widgets) }
        if apps <= half { return (available - apps, apps) }
        return (half, available - half)
    }
}

/// 自動で隠したときの帯の枠（純粋関数）。端の外へ出して細い帯だけ見せるが、
/// 出ていく先に別のディスプレイがあれば、そちらへはみ出さないよう、自分のディスプレイの端の細い帯にとどめる。
enum HiddenPlacement {
    static func frame(
        shown: NSRect, position: String, visible: NSRect, screen: NSRect, others: [NSRect], peek: CGFloat
    ) -> NSRect {
        var outside = shown
        switch position {
        case "left": outside.origin.x = visible.minX - shown.width + peek
        case "right": outside.origin.x = visible.maxX - peek
        default: outside.origin.y = visible.minY - shown.height + peek
        }
        guard others.contains(where: { $0.intersects(outside) }) else { return outside }
        switch position {
        case "left": return NSRect(x: visible.minX, y: shown.minY, width: peek, height: shown.height)
        case "right": return NSRect(x: visible.maxX - peek, y: shown.minY, width: peek, height: shown.height)
        default: return NSRect(x: shown.minX, y: visible.minY, width: shown.width, height: peek)
        }
    }
}

/// 隠れた帯を出す判定（純粋関数）。カーソルが、その帯のディスプレイ自身の端にあるときだけ「寄った」と見なす。
/// 隣のディスプレイ上では寄ったと見なさない（隣の画面にいるだけで出て、そのまま隠れなくなるのを防ぐ）。
enum EdgeReveal {
    static func nearEdge(mouse: NSPoint, position: String, visible: NSRect, screen: NSRect, peek: CGFloat) -> Bool {
        guard screen.contains(mouse) else { return false }
        switch position {
        case "left": return mouse.x <= visible.minX + peek + 2
        case "right": return mouse.x >= visible.maxX - peek - 2
        default: return mouse.y <= visible.minY + peek + 2
        }
    }
}

/// 帯の自動縮小（純粋関数）。標準 Dock と同じく、要素が多くて画面に収まらないときは、アイコンを縮めて収める。
/// 設定の大きさ（`Prefs.iconSize`）は書き換えない。縮めるのは、描くときと枠を計算するときだけ。
enum StripFit {
    /// これより小さくは縮めない（読めなくなるため）。収まらなくても、ここで止める。
    static let minimumIcon: CGFloat = 24

    /// 画面に収まる、一番大きいアイコン（`requested` 以下）。
    /// - `available`: 帯の長さ方向に使える長さ。
    /// - `length`: アイコンの大きさから、帯の長さを出す関数（アイコンが大きいほど長い）。
    static func iconSize(requested: CGFloat, available: CGFloat, length: (CGFloat) -> CGFloat) -> CGFloat {
        guard requested > minimumIcon, length(requested) > available else { return requested }
        // 収まる最大の整数を、整数だけで二分探索する（小数のまま探すと、切り捨てた中間が下限と同じになって終わらない）。
        guard length(minimumIcon) <= available else { return minimumIcon }
        var low = Int(minimumIcon)                       // 収まる
        var high = Int(requested.rounded(.up))           // 収まらない（requested は収まらないと分かっている）
        while high - low > 1 {
            let mid = (low + high) / 2
            if length(CGFloat(mid)) <= available { low = mid } else { high = mid }
        }
        return CGFloat(low)
    }
}

/// 未読バッジの寸法（描画と配置で同じ値を使う）。バッジはアイコンの上端に重ね、上へはみ出す。
enum BadgeMetrics {
    static let heightRatio: CGFloat = 0.34
    static let liftRatio: CGFloat = 0.22
    /// アイコンの上端から、バッジが上へはみ出す量。
    static func overhang(_ icon: CGFloat) -> CGFloat { ceil(icon * (heightRatio / 2 + liftRatio)) }
}

/// グループの吹き出しの枠（吹き出しの中・左上原点）。幅はアプリの数に合わせる（固定幅にしない）。
struct BubbleLayout: Equatable {
    static let pad: CGFloat = 12
    /// 1 行の最大幅（これを超えたら折り返す）。
    static let gridWidth: CGFloat = 380
    static let headerHeight: CGFloat = 24
    /// 見出し（名前・▶■×）が収まる最小の幅。
    static let headerMinWidth: CGFloat = 132
    /// 見せる行数の上限。超えたらスクロール（途中の行が少し見えるので、続きがあると分かる）。
    static let maxVisibleRows: CGFloat = 3.5
    /// 左右に置くとき：横は 3 列まで、縦に長く見せる。
    static let sideColumns = 3
    static let maxVisibleRowsSide: CGFloat = 6.5

    /// 1 行の最大幅（左右に置くときは 3 列分）。
    static func rowLimit(vertical: Bool, cellWidth: CGFloat, gap: CGFloat) -> CGFloat {
        vertical ? CGFloat(sideColumns) * cellWidth + CGFloat(sideColumns - 1) * gap : gridWidth
    }
    /// 見出しの右側（▶ ■ × と間隔）の幅。
    static let headerButtonsWidth: CGFloat = 84

    /// グループ名の幅（見出しの文字と同じ書体で測る）。
    static func titleWidth(_ name: String) -> CGFloat {
        let font = NSFont.preferredFont(forTextStyle: .headline)
        return ceil((name as NSString).size(withAttributes: [.font: font]).width)
    }

    /// アプリごとの枠（グループの並び順）。
    let tiles: [CGRect]
    /// 「＋」ボタンの枠。
    let plus: CGRect
    let size: CGSize
    /// 縁の余白（見出しの位置にも使う）。
    var padding: CGFloat = BubbleLayout.pad
    /// 余白を除いた中身の幅（見出しの幅）。
    var contentWidth: CGFloat = BubbleLayout.headerMinWidth
    /// アイコンの並びが始まる高さ（見出しの下）。
    var gridTop: CGFloat = 0
    /// アイコンの並びを見せる高さ（上限まで）。
    var viewportHeight: CGFloat = 0
    /// スクロールできる量（0 ならスクロールなし）。
    var maxScroll: CGFloat = 0
    /// 並びの上に空ける、バッジのはみ出し分。切り取る範囲はここから始める（最上段のバッジが見切れない）。
    var badgeInset: CGFloat = 0

    /// スクロール量を範囲に収める。
    func clampScroll(_ value: CGFloat) -> CGFloat { min(max(0, value), maxScroll) }

    /// スクロール後に、並びの見える範囲に入っているか（当たり判定に使う）。
    func isVisible(_ tile: CGRect, scroll: CGFloat) -> Bool {
        let top = tile.minY - scroll
        return top + tile.height > gridTop && top < gridTop + viewportHeight
    }

    /// 1 マスの大きさ（アイコン＋すき間。名前を出すときは下に名前の分）。
    static func cell(iconSize: CGFloat, showNames: Bool, tilePadding: CGFloat = StripLayout.defaultTilePadding) -> CGSize {
        StripLayout.cell(icon: iconSize, showNames: showNames, padding: tilePadding)
    }

    /// 列の数。件数ぶん並べ、最大幅で折り返す。
    static func columns(slots: Int, cellWidth: CGFloat, maxWidth: CGFloat = gridWidth, gap: CGFloat = 0) -> Int {
        max(1, min(max(1, slots), Int((maxWidth + gap) / (cellWidth + gap))))
    }

    /// `opening`: ドラッグ中、この番号に空きを作る（周りが退くプレビュー）。
    /// `padding`: 縁の余白（設定「グループの余白」）。
    /// `titleWidth`: グループ名の幅。名前が途切れないよう、見出しの幅を名前に合わせて広げる。
    static func make(
        count: Int, iconSize: CGFloat, opening: Int? = nil, showNames: Bool = false, padding: CGFloat = BubbleLayout.pad,
        titleWidth: CGFloat = 0, tilePadding: CGFloat = StripLayout.defaultTilePadding, gap: CGFloat = 0,
        vertical: Bool = false
    ) -> BubbleLayout {
        let pad = max(0, padding)
        let gap = max(0, gap)
        let cell = cell(iconSize: iconSize, showNames: showNames, tilePadding: tilePadding)
        let slots = count + (opening == nil ? 0 : 1)
        let limit = rowLimit(vertical: vertical, cellWidth: cell.width, gap: gap)
        let columns = columns(slots: slots + 1, cellWidth: cell.width, maxWidth: limit, gap: gap)     // 「＋」の分を含む
        let gridWidth = CGFloat(columns) * cell.width + CGFloat(columns - 1) * gap
        let contentWidth = max(gridWidth, headerMinWidth, ceil(titleWidth) + headerButtonsWidth)
        let badgeInset = BadgeMetrics.overhang(iconSize)
        let top = pad + headerHeight + max(8, badgeInset)
        func frame(_ index: Int) -> CGRect {
            CGRect(
                x: pad + CGFloat(index % columns) * (cell.width + gap),
                y: top + CGFloat(index / columns) * (cell.height + gap),
                width: cell.width, height: cell.height)
        }
        let rows = (slots + columns) / columns          // 「＋」の分を含む切り上げ
        let fullHeight = CGFloat(rows) * cell.height + CGFloat(rows - 1) * gap
        let viewport = min(fullHeight, (cell.height + gap) * (vertical ? maxVisibleRowsSide : maxVisibleRows))
        let height = top + viewport + pad
        // 空き（opening）以降のタイルは 1 つ後ろへ退く。
        var tiles: [CGRect] = []
        for index in 0..<count {
            var slot = index
            if let open = opening, index >= open { slot += 1 }
            tiles.append(frame(slot))
        }
        return BubbleLayout(
            tiles: tiles,
            plus: frame(slots),
            size: CGSize(width: contentWidth + pad * 2, height: height),
            padding: pad,
            contentWidth: contentWidth,
            gridTop: top,
            viewportHeight: viewport,
            maxScroll: max(0, fullHeight - viewport),
            badgeInset: badgeInset)
    }
}

/// アイコンの格子（履歴・インスタンス選択で共通）。原点は左上。幅は件数に合わせ、最大幅で折り返す。
enum GridMetrics {
    static func make(
        count: Int, iconSize: CGFloat, showNames: Bool, width: CGFloat = BubbleLayout.gridWidth,
        tilePadding: CGFloat = StripLayout.defaultTilePadding, gap: CGFloat = 0, vertical: Bool = false
    ) -> (tiles: [CGRect], size: CGSize) {
        let gap = max(0, gap)
        let cell = BubbleLayout.cell(iconSize: iconSize, showNames: showNames, tilePadding: tilePadding)
        let limit = vertical ? BubbleLayout.rowLimit(vertical: true, cellWidth: cell.width, gap: gap) : width
        let columns = BubbleLayout.columns(slots: count, cellWidth: cell.width, maxWidth: limit, gap: gap)
        let tiles = (0..<count).map { index in
            CGRect(
                x: CGFloat(index % columns) * (cell.width + gap), y: CGFloat(index / columns) * (cell.height + gap),
                width: cell.width, height: cell.height)
        }
        let rows = max(0, (count + columns - 1) / columns)
        return (tiles, CGSize(
            width: CGFloat(columns) * cell.width + CGFloat(max(0, columns - 1)) * gap,
            height: CGFloat(rows) * cell.height + CGFloat(max(0, rows - 1)) * gap))
    }
}

extension StripLayout {
    /// 選択枠の余白（アイコン画像と選択時の枠の間）の既定。設定「選択枠の余白」で 1pt まで狭められる。
    static let defaultTilePadding: CGFloat = 1
    /// 帯の縁の余白（固定）。
    static let stripPadding: CGFloat = 6
    static let minTilePadding: CGFloat = 1

    /// アイコン画像の一辺。帯・グループの中・履歴・インスタンス選択で同じ。
    static func imageSide(_ icon: CGFloat) -> CGFloat { icon - 6 }

    /// ボタン（履歴・ゴミ箱・設定）のセルの高さ。緑丸が要らないので、アイコン画像の部分だけ（名前を出すときは名前の分を足す）。
    static func buttonHeight(icon: CGFloat, showNames: Bool, padding: CGFloat = StripLayout.defaultTilePadding) -> CGFloat {
        imageSide(icon) + (showNames ? 17 : 0) + max(minTilePadding, padding) * 2
    }

    /// 名前の幅。
    static func nameWidth(_ icon: CGFloat) -> CGFloat { icon + 6 }

    /// アプリ 1 つ分のセル。帯・グループの中・履歴・インスタンス選択で共通。
    /// 画像（名前を出すときは名前の幅）の周りに `padding` ずつ、下に緑丸の分（8pt）、名前を出すときは 14pt を足す。
    /// 選択時の枠はこのセルいっぱいに描くので、`padding` がそのまま枠の余白になる。
    static func cell(icon: CGFloat, showNames: Bool, padding: CGFloat = StripLayout.defaultTilePadding) -> CGSize {
        let pad = max(minTilePadding, padding)
        return CGSize(
            width: (showNames ? nameWidth(icon) : imageSide(icon)) + pad * 2,
            height: imageSide(icon) + 8 + (showNames ? 14 : 0) + pad * 2)
    }
}

/// 縮小の計算を実際にした回数（テストで「描画のたびに作り直さない」ことを確かめる）。
nonisolated(unsafe) var stripFitComputations = 0

/// 帯の並びを決める入力。これが同じなら、並びも縮小後の大きさも同じ（結果を使い回す条件）。
struct StripFitInput: Equatable {
    var prefs: Prefs
    var groups: [Group]
    var kept: [AppRef]
    var running: [AppRef]
    var hiddenRunning: Set<String>
    var available: CGFloat
    var pages: [StripSection: Int]
}

extension Store {
    /// 要素が多くて画面に収まらないときの並び（`fittedStrip`）。方式は設定（縮める／ページ切り替え）。
    func stripEntries() -> [StripEntry] { fittedStrip().entries }

    /// 画面に収まるアイコンの大きさ（設定の値以下）。設定そのものは書き換えない。描画・当たり判定・枠の計算はすべてこれを使う。
    /// ページ切り替えの方式では、縮めないので、設定の大きさのまま。
    var effectiveIconSize: CGFloat { fittedStrip().icon }

    /// 帯の長さ方向に使える長さ。全ディスプレイに出すときは一番小さい画面に合わせる（どの画面でも収まる）。
    /// 画面が分からないとき（テストなど）は、制限しない。
    func stripAvailableLength() -> CGFloat {
        let screens = prefs.allDisplays ? NSScreen.screens : [NSScreen.main ?? NSScreen.screens.first].compactMap { $0 }
        guard !screens.isEmpty else { return .greatestFiniteMagnitude }
        let vertical = prefs.position != "bottom"
        return screens.map { vertical ? $0.visibleFrame.height : $0.visibleFrame.width }.min()! - 16
    }

    /// 収まらないときの並びを決める。入力（設定・グループ・残すアプリ・実行中・外したアプリ・画面の長さ・ページ）が同じ間は、前の結果を使い回す。
    /// 描画ではタイルごとに何度も呼ばれるので、毎回作り直すと固まる（実測：CPU 100%）。
    /// - 縮める（既定）：収まる最大の大きさまで、アイコンを縮める。
    /// - ページを切り替える：大きさを保ち、ウィジェットとアプリを別々のページに分ける（FF14 のホットバーのように）。
    func fittedStrip() -> (icon: CGFloat, entries: [StripEntry]) {
        let available = stripAvailableLength()
        let input = StripFitInput(
            prefs: prefs, groups: groups, kept: kept, running: running,
            hiddenRunning: hiddenRunning, available: available, pages: stripPages)
        if let cache = fitCache, cache.input == input { return cache.result }
        stripFitComputations += 1
        let vertical = prefs.position != "bottom"
        let gap = CGFloat(prefs.gap)
        let requested = CGFloat(prefs.iconSize)
        func length(_ entries: [StripEntry]) -> CGFloat {
            let size = StripLayout.make(entries, vertical: vertical, gap: gap, padding: StripLayout.stripPadding).size
            return vertical ? size.height : size.width
        }
        let first = stripEntries(icon: requested)
        let result: (icon: CGFloat, entries: [StripEntry])
        if prefs.overflow == "pages" {
            // ページ切り替えの方式：収まるときも、並べる数（本数）を必ず効かせる。
            result = (requested, pagedEntries(first, icon: requested, available: available))
        } else if length(first) <= available {
            result = (requested, first)
        } else {
            let fitted = StripFit.iconSize(requested: requested, available: available) { length(stripEntries(icon: $0)) }
            result = (fitted, stripEntries(icon: fitted))
        }
        fitCache = (input, result)
        return result
    }

    /// ページ切り替え：ウィジェットとアプリを別々の区画にし、それぞれ「並べる数」本の列の格子で、収まる分ずつのページに分ける。
    /// 区画の長さは全ページで同じ（ページを送っても帯の大きさが変わらない）。仕切り線とボタンは常に出す。
    /// ページ送りは、ページが 2 つ以上ある区画の末尾に付く。
    private func pagedEntries(_ all: [StripEntry], icon: CGFloat, available: CGFloat) -> [StripEntry] {
        let vertical = prefs.position != "bottom"
        let gap = CGFloat(prefs.gap)
        let lines = Prefs.clampLines(prefs.stripLines)
        func main(_ entry: StripEntry) -> CGFloat { (vertical ? entry.size.height : entry.size.width) + gap }
        func section(_ entry: StripEntry) -> StripSection? {
            switch entry.kind {
            case .widget: return .widgets
            case .pinned, .kept, .group, .running: return .apps
            default: return nil
            }
        }
        let widgets = all.filter { section($0) == .widgets }
        let apps = all.filter { section($0) == .apps }
        // アプリの区画の途中にある仕切り線（アプリ一覧と実行中の間）は、区画を 1 つにまとめるため外す。
        let appIndices = all.indices.filter { section(all[$0]) == .apps }
        var droppedSeparators = Set<Int>()
        if let first = appIndices.first, let last = appIndices.last {
            droppedSeparators = Set((first...last).filter { all[$0].kind == .separator })
        }
        let fixedLength = all.indices
            .filter { section(all[$0]) == nil && !droppedSeparators.contains($0) }
            .reduce(CGFloat(0)) { $0 + main(all[$1]) }
        let inset = StripLayout.shadowMargin + StripLayout.stripPadding
        // 使える中身の長さ：全体の長さ - 縁 - 固定の分 - ページ送り 2 つ分（付かなければ余るだけ）。
        let pagerLength = StripPaging.pagerLength + gap
        let content = available - inset * 2 + gap - fixedLength - pagerLength * 2
        func total(_ list: [StripEntry]) -> CGFloat { list.reduce(0) { $0 + main($1) } }
        // 1 本に必要な長さ（全体を並べる数で割った分）で、ウィジェットとアプリが残りを分け合う。
        let budgets = StripPaging.budgets(
            widgets: total(widgets) / CGFloat(lines), apps: total(apps) / CGFloat(lines), available: max(0, content))
        // 1 本の予算：割った長さに最長の 1 つ分の余裕を足せば、必ず並べる数の本に収まる。
        func laneBudget(_ list: [StripEntry], _ sectionBudget: CGFloat) -> CGFloat {
            let longest = list.map(main).max() ?? 0
            return min(sectionBudget, (total(list) / CGFloat(lines)).rounded(.up) + longest)
        }
        let widgetGrid = StripPaging.grid(lengths: widgets.map(main), lines: lines, budget: laneBudget(widgets, budgets.widgets))
        let appGrid = StripPaging.grid(lengths: apps.map(main), lines: lines, budget: laneBudget(apps, budgets.apps))
        let widgetPage = StripPaging.clamp(stripPages[.widgets] ?? 0, count: widgetGrid.pages.count)
        let appPage = StripPaging.clamp(stripPages[.apps] ?? 0, count: appGrid.pages.count)
        let cell = StripLayout.cell(icon: icon, showNames: prefs.showNames, padding: StripLayout.defaultTilePadding)
        func pager(_ section: StripSection, _ page: Int, _ count: Int) -> StripEntry {
            let size = vertical ? CGSize(width: cell.width, height: StripPaging.pagerLength)
                                : CGSize(width: StripPaging.pagerLength, height: cell.height)
            return StripEntry(id: "pager:\(section.rawValue)", kind: .pager(section, page, count), size: size)
        }
        func block(_ list: [StripEntry], _ grid: StripPaging.Grid, _ page: Int) -> [StripEntry] {
            grid.pages[page].map { index in
                var entry = list[index]
                entry.blockLength = grid.pageLength
                entry.lane = grid.lane[index]
                entry.lanes = grid.lanes
                entry.slot = grid.slot[index]
                return entry
            }
        }
        var result: [StripEntry] = []
        var emittedWidgets = false, emittedApps = false
        for (index, entry) in all.enumerated() {
            switch section(entry) {
            case .widgets?:
                guard !emittedWidgets else { continue }
                emittedWidgets = true
                result += block(widgets, widgetGrid, widgetPage)
                if widgetGrid.pages.count > 1 { result.append(pager(.widgets, widgetPage, widgetGrid.pages.count)) }
            case .apps?:
                guard !emittedApps else { continue }
                emittedApps = true
                result += block(apps, appGrid, appPage)
                if appGrid.pages.count > 1 { result.append(pager(.apps, appPage, appGrid.pages.count)) }
            case nil:
                if droppedSeparators.contains(index) { continue }
                result.append(entry)
            }
        }
        return result
    }

    /// 指定のアイコンの大きさで並べた帯の要素（縮小の計算とテストが使う入口）。
    func stripEntriesForTest(icon: CGFloat) -> [StripEntry] { stripEntries(icon: icon) }

    private func stripEntries(icon: CGFloat) -> [StripEntry] {
        let cellHeight = StripLayout.cell(icon: icon, showNames: prefs.showNames, padding: StripLayout.defaultTilePadding).height
        let cellWidth = StripLayout.cell(icon: icon, showNames: prefs.showNames, padding: StripLayout.defaultTilePadding).width
        let vertical = prefs.position != "bottom"
        var entries: [StripEntry] = []
        var seen = Set<String>()
        var separators = 0

        func add(_ id: String, _ kind: StripEntry.Kind, _ width: CGFloat, _ height: CGFloat? = nil) {
            guard seen.insert(id).inserted else { return }
            entries.append(StripEntry(id: id, kind: kind, size: CGSize(width: width, height: height ?? cellHeight)))
        }
        func separator() {
            separators += 1
            let length = icon - 6
            // 線は 1pt のまま、枠は両側に余白を持つ（右クリックを当てやすくする。隣のタイルとは重ならない）。
            let thickness = StripLayout.separatorThickness + StripLayout.separatorMargin * 2
            add("sep:\(separators)", .separator, vertical ? length : thickness, vertical ? thickness : length)
        }

        for widget in prefs.widgets {
            // 向きごとの見た目で大きさが変わる（左右は縦に伸び、下は横に伸びる）。名前は出すときだけ分を足す。
            let tile = widget.tileSize(icon: icon, vertical: vertical)
            let labelled = widget.showLabel && prefs.showNames
            add("widget:\(widget.id.uuidString)", .widget(widget.id), tile.width + 2, tile.height + (labelled ? 20 : 6))
        }
        if !prefs.widgets.isEmpty { separator() }

        let pinned = AppRef.pinnedPaths.map { AppRef(path: $0) }
        for ref in pinned { add("app:\(ref.id)", .pinned(ref), cellWidth) }
        for ref in kept { add("app:\(ref.id)", .kept(ref), cellWidth) }
        // グループは「残す」アプリと同じ区画に並べる（区切りを入れない）。グループは残す側にしか作れない。
        for group in groups { add("group:\(group.id.uuidString)", .group(group.id), cellWidth) }

        // 実行中だが、アプリ一覧にもグループにも入っていないアプリ。
        var listed = Set(pinned.map(\.path))
        listed.formUnion(kept.map(\.path))
        for group in groups { listed.formUnion(group.apps.map(\.path)) }
        let extra = runningApps.filter { !listed.contains($0.path) && !hiddenRunning.contains($0.path) }
        if !extra.isEmpty {
            separator()
            for ref in extra { add("app:\(ref.id)", .running(ref), cellWidth) }
        }

        separator()
        let buttonHeight = StripLayout.buttonHeight(icon: icon, showNames: prefs.showNames)
        add("button:history", .history, cellWidth, buttonHeight)
        add("button:trash", .trash, cellWidth, buttonHeight)
        add("button:settings", .settings, cellWidth, buttonHeight)
        return entries
    }

    /// グループの吹き出しの枠。描画・当たり判定・ウィンドウの大きさはすべてここを通す（同じ枠を使う）。
    func bubbleLayout(for group: Group, opening: Int? = nil) -> BubbleLayout {
        BubbleLayout.make(
            count: group.apps.count, iconSize: effectiveIconSize, opening: opening,
            showNames: prefs.showNames, padding: max(BubbleLayout.pad / 2, CGFloat(prefs.gap)),
            titleWidth: BubbleLayout.titleWidth(group.name), gap: CGFloat(prefs.gap),
            vertical: prefs.position != "bottom")
    }

    /// タイルの id から、ホバーで出す名前を引く（アプリ・グループ・ウィジェット・ボタン）。
    func hoverName(for id: String) -> String? {
        if id.hasPrefix("app:") {
            let appID = String(id.dropFirst(4))
            if let ref = appRef(id: appID) { return ref.arguments.isEmpty ? ref.name : "\(ref.name)（\(ref.arguments)）" }
            return AppRef.pinnedPaths.contains(appID) ? AppRef(path: appID).name : nil
        }
        if id.hasPrefix("group:"), let uuid = UUID(uuidString: String(id.dropFirst(6))) {
            return groups.first { $0.id == uuid }.map { "\($0.name)（\($0.apps.count) 個）" }
        }
        if id.hasPrefix("widget:"), let uuid = UUID(uuidString: String(id.dropFirst(7))) {
            return prefs.widgets.first { $0.id == uuid }?.title
        }
        switch id {
        case "button:history": return "履歴"
        case "button:trash": return "ゴミ箱"
        case "button:settings": return "設定"
        default: return nil
        }
    }

    func stripLayout() -> StripLayout {
        let vertical = prefs.position != "bottom"
        let gap = CGFloat(prefs.gap)
        let fitted = fittedStrip()
        let icon = fitted.icon
        // 空ける量は、タイル 1 つ分（縦置きは高さ、横置きは幅）と間隔。
        let cell = StripLayout.cell(icon: icon, showNames: prefs.showNames, padding: StripLayout.defaultTilePadding)
        let extra = (vertical ? cell.height : cell.width) + gap
        var opening: (id: String, after: Bool)?
        if let insertion { opening = (insertion.id, insertion.after) }
        return StripLayout.make(
            fitted.entries, vertical: vertical, gap: gap, opening: opening, extra: extra,
            padding: StripLayout.stripPadding)
    }

    /// 帯のウィンドウの大きさ。ドラッグ中は、道を空ける分を先に確保して固定する（途中で大きさを変えない）。
    func stripWindowSize() -> CGSize {
        let vertical = prefs.position != "bottom"
        let gap = CGFloat(prefs.gap)
        let fitted = fittedStrip()
        let icon = fitted.icon
        let base = StripLayout.make(fitted.entries, vertical: vertical, gap: gap, padding: StripLayout.stripPadding).size
        guard dragging else { return base }
        let cell = StripLayout.cell(icon: icon, showNames: prefs.showNames, padding: StripLayout.defaultTilePadding)
        let extra = (vertical ? cell.height : cell.width) + gap
        return vertical
            ? CGSize(width: base.width, height: base.height + extra)
            : CGSize(width: base.width + extra, height: base.height)
    }

    /// 開いているグループの中で、ドラッグ中のアプリを入れる番号（無ければ nil）。
    /// ドラッグ中で、入れる先がこのグループの外なら、末尾に 1 つ分の空きを確保して大きさを固定する。
    func bubbleOpening(groupID: Group.ID) -> Int? {
        guard dragging, let group = groups.first(where: { $0.id == groupID }) else { return nil }
        if let insertion, insertion.id.hasPrefix("app:"),
           let index = group.apps.firstIndex(where: { "app:\($0.id)" == insertion.id }) {
            return index + (insertion.after ? 1 : 0)
        }
        return group.apps.count
    }
}

/// 名前の札の置き場所（純粋関数）。帯の向きに合わせて出し、画面からはみ出さないよう寄せる。
enum HoverPlacement {
    static func frame(size: NSSize, tile: NSRect, position: String, screen area: NSRect) -> NSRect {
        var origin: NSPoint
        switch position {
        case "left": origin = NSPoint(x: tile.maxX + 8, y: tile.midY - size.height / 2)
        case "right": origin = NSPoint(x: tile.minX - size.width - 8, y: tile.midY - size.height / 2)
        default: origin = NSPoint(x: tile.midX - size.width / 2, y: tile.maxY + 6)
        }
        origin.x = min(max(origin.x, area.minX + 4), area.maxX - size.width - 4)
        origin.y = min(max(origin.y, area.minY + 4), area.maxY - size.height - 4)
        return NSRect(origin: origin, size: size)
    }
}

/// 再生中ウィジェットで、並べ替えのドラッグを始めてよい所（純粋関数）。
/// サムネだけを掴む所にし、つまみ・音量・ボタンのドラッグは操作に渡す。
enum NowPlayingGrab {
    /// 端のつかみ代（サムネの無い表示パターン用）。
    static let edge: CGFloat = 6

    /// `tile` は画面座標（左下原点）のタイルの枠、`icon` はアイコンの大きさ。
    static func allowsDrag(
        at point: CGPoint, tile: CGRect, layout: PlayerLayout, icon: CGFloat, vertical: Bool = false
    ) -> Bool {
        guard tile.contains(point) else { return false }
        if vertical {
            // 左右に置くときは縦に積むので、上のサムネの所（画面座標は左下原点）か、上下の端で掴む。
            switch layout {
            case .thumbnail: return true
            case .thumbnailPlay, .full: return point.y >= tile.maxY - icon
            case .transport: return point.y >= tile.maxY - edge || point.y <= tile.minY + edge
            }
        }
        switch layout {
        case .thumbnail:
            return true                                   // サムネだけなので、どこでも掴める
        case .thumbnailPlay, .full:
            return point.x <= tile.minX + icon            // 左のサムネの所だけ
        case .transport:
            return point.x <= tile.minX + edge || point.x >= tile.maxX - edge   // 左右の端だけ
        }
    }
}

/// サイズ変更のつまみ（純粋関数）。帯の内側の縁（画面の中央側）に置き、そちらへ引くと大きくなる。
enum GrabHandle {
    static let length: CGFloat = 120
    static let thickness: CGFloat = 16

    /// つまみの枠（帯のウィンドウの中・左下原点）。
    static func frame(in bounds: CGRect, position: String) -> CGRect {
        switch position {
        case "left":   // 帯は左端。内側は右の縁
            let w = min(thickness, bounds.width)
            return CGRect(x: bounds.maxX - w, y: bounds.midY - length / 2, width: w, height: length)
        case "right":  // 帯は右端。内側は左の縁
            let w = min(thickness, bounds.width)
            return CGRect(x: bounds.minX, y: bounds.midY - length / 2, width: w, height: length)
        default:       // 帯は下端。内側は上の縁
            let h = min(thickness, bounds.height)
            return CGRect(x: bounds.midX - length / 2, y: bounds.maxY - h, width: length, height: h)
        }
    }

    /// マウスの動き（画面座標の差）から、大きさの変化量へ。内側へ引くほど大きくなる。
    static func growth(dx: CGFloat, dy: CGFloat, position: String) -> CGFloat {
        switch position {
        case "left": return dx
        case "right": return -dx
        default: return dy
        }
    }

    static func isHorizontalDrag(position: String) -> Bool { position == "left" || position == "right" }
}

extension Store {
    /// ポップアップを出す向き。帯の内側（画面の中央側）へ出す。
    var popoverEdge: Edge {
        switch prefs.position {
        case "left": return .trailing
        case "right": return .leading
        default: return .top
        }
    }
}
