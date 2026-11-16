import Foundation

/// 保存と読み込みの集約。保存先のフォルダ作成・JSON の書き出し・原子的な書き込み・失敗の返し方を 1 か所にする。
/// 呼び出し側（`Store`）は、型と保存先を渡すだけ。失敗は握りつぶさず、エラーで返す（記録と通知は `SaveFailureTracker` と呼び出し側）。
enum Persistence {
    /// 読み込む。ファイルが無いとき・壊れているときは nil（落ちない）。
    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// 保存する（フォルダが無ければ作る。書き込みは原子的）。成功したら nil、失敗したらそのエラー。
    @discardableResult
    static func save<T: Encodable>(_ value: T, to url: URL, pretty: Bool = true) -> Error? {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            if pretty { encoder.outputFormatting = [.prettyPrinted, .sortedKeys] }
            try encoder.encode(value).write(to: url, options: .atomic)
            return nil
        } catch {
            return error
        }
    }
}

/// 保存の失敗を、保存先ごとに数える（純粋な値）。
/// 1 回の失敗では騒がず、続けて `threshold` 回失敗したときに、1 度だけ知らせる。成功すると数え直す。
struct SaveFailureTracker {
    static let threshold = 3
    private var streak: [String: Int] = [:]

    /// 結果を記録する。利用者に知らせるべきとき（続けて `threshold` 回目の失敗）だけ true。
    mutating func record(failed: Bool, key: String) -> Bool {
        guard failed else { streak[key] = 0; return false }
        let next = (streak[key] ?? 0) + 1
        streak[key] = next
        return next == Self.threshold
    }
}
