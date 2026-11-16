import AppKit
import CryptoKit
import Observation

/// PersistenceTests（`tests/main.swift` から呼ぶ。`check` と `failures` は main.swift のものを使う）。
func runPersistenceTests() {
    // 保存と読み込みの集約（Persistence）：失敗の扱いを 1 か所にする。保存先はテスト用のフォルダ。
    do {
        struct Sample: Codable, Equatable { var name: String; var count: Int }
        let dir = Store.directory.appendingPathComponent("persistence-test", isDirectory: true)
        let url = dir.appendingPathComponent("sample.json")
        try? FileManager.default.removeItem(at: dir)

        check("まだ無いファイルは、読み込みで nil", Persistence.load(Sample.self, from: url) == nil)
        check("保存できる（フォルダも作る）", Persistence.save(Sample(name: "a", count: 1), to: url) == nil)
        check("保存したものを読み直せる", Persistence.load(Sample.self, from: url) == Sample(name: "a", count: 1))
        check("上書きできる", Persistence.save(Sample(name: "b", count: 2), to: url) == nil
              && Persistence.load(Sample.self, from: url) == Sample(name: "b", count: 2))
        try? Data("これは JSON ではない".utf8).write(to: url)
        check("壊れたファイルは、読み込みで nil（落ちない）", Persistence.load(Sample.self, from: url) == nil)
        // 書けない場所：ファイルの下にフォルダは作れない。
        let blocked = url.appendingPathComponent("child.json")
        check("書けない場所では、エラーを返す（落ちない）", Persistence.save(Sample(name: "c", count: 3), to: blocked) != nil)
        try? FileManager.default.removeItem(at: dir)

        // 失敗の記録：続けて失敗したときだけ、利用者に知らせる（1 回の失敗では騒がない）。
        var tracker = SaveFailureTracker()
        check("1 回目の失敗では知らせない", tracker.record(failed: true, key: "groups") == false)
        check("2 回目でも知らせない", tracker.record(failed: true, key: "groups") == false)
        check("3 回続けて失敗したら知らせる", tracker.record(failed: true, key: "groups") == true)
        check("知らせたあとは、続けて失敗しても繰り返さない", tracker.record(failed: true, key: "groups") == false)
        check("成功すれば数え直す", tracker.record(failed: false, key: "groups") == false)
        check("数え直したあとは、また 3 回続けば知らせる",
              [true, true, true].map { tracker.record(failed: $0, key: "groups") } == [false, false, true])
        check("保存先ごとに別々に数える",
              tracker.record(failed: true, key: "kept") == false && tracker.record(failed: true, key: "kept") == false
              && tracker.record(failed: true, key: "kept") == true)
    }

}
