import CoreGraphics
import Foundation

/// タイルの当たり判定（UI から切り離してテストできるようにしてある）。
///
/// SwiftUI の `.global` は「そのウィンドウの左上原点」なので、
/// ウィンドウの枠を使って**画面座標**に直してから判定する。
/// こうすると帯とグループの吹き出し、どちらのアイコンも同じ規則で扱える。
enum TileHitTest {
    /// ウィンドウ内の矩形（左上原点）を、画面座標（左下原点）に直す。
    static func screenRect(_ rect: CGRect, windowFrame: NSRect, containerHeight: CGFloat) -> NSRect {
        NSRect(
            x: windowFrame.minX + rect.minX,
            y: windowFrame.minY + (containerHeight - rect.maxY),
            width: rect.width,
            height: rect.height
        )
    }

    /// 2 つの矩形集合がほぼ同じか（1pt 未満の差は無視する）。
    /// レイアウトのたびに状態を書き換えて再レイアウトになるのを防ぐ。
    static func sameRects(_ a: [String: CGRect], _ b: [String: CGRect], tolerance: CGFloat = 1) -> Bool {
        guard a.count == b.count else { return false }
        for (key, rect) in a {
            guard let other = b[key] else { return false }
            if abs(rect.minX - other.minX) > tolerance
                || abs(rect.minY - other.minY) > tolerance
                || abs(rect.width - other.width) > tolerance
                || abs(rect.height - other.height) > tolerance {
                return false
            }
        }
        return true
    }

    /// 点がどのタイルにも入らないとき、近くにある `prefix` 付きタイルの id（隙間への落とし込み用）。
    static func nearestID(
        to point: CGPoint, rects: [String: NSRect], prefix: String, excluding: String, within: CGFloat
    ) -> String? {
        var best: (id: String, distance: CGFloat)?
        for (id, rect) in rects where id.hasPrefix(prefix) && id != excluding {
            let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
            let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
            let distance = hypot(dx, dy)
            if distance <= within, distance < (best?.distance ?? .infinity) { best = (id, distance) }
        }
        return best?.id
    }

    /// 画面座標の点にあるタイルの id。重なりは面積の小さい（手前の）ものを優先する。
    static func id(atScreenPoint point: CGPoint, rects: [String: NSRect]) -> String? {
        rects
            .filter { $0.value.contains(point) }
            .sorted { $0.value.width * $0.value.height < $1.value.width * $1.value.height }
            .first?
            .key
    }

    /// ドラッグ中のアプリを入れる位置（相手の id と、その後ろか）。プレビューとドロップで同じ判定を使う。
    /// 相手タイルの端（外側 30%）か、タイルの隙間（近いタイル 24pt 以内）なら挿入。中央は「重ねる」なので nil。
    static func insertion(
        at point: CGPoint, rects: [String: NSRect], dragged: String, vertical: Bool, prefix: String = "app:"
    ) -> (id: String, after: Bool)? {
        func after(_ rect: NSRect) -> Bool { vertical ? point.y < rect.midY : point.x > rect.midX }
        if let hit = id(atScreenPoint: point, rects: rects) {
            guard hit.hasPrefix(prefix), hit != dragged, let rect = rects[hit] else { return nil }
            let fraction = vertical
                ? (rect.maxY - point.y) / max(1, rect.height)
                : (point.x - rect.minX) / max(1, rect.width)
            guard fraction < 0.3 || fraction > 0.7 else { return nil }
            return (hit, after(rect))
        }
        guard let near = nearestID(to: point, rects: rects, prefix: prefix, excluding: dragged, within: 24),
              let rect = rects[near] else { return nil }
        return (near, after(rect))
    }
}
