import AppKit
import CryptoKit
import Observation

/// UiTextTests（`tests/main.swift` から呼ぶ。`check` と `failures` は main.swift のものを使う）。
func runUiTextTests() {
    // 音量・マイク・明るさのポップアップ：文言を短くして改行し、幅を抑える（大きすぎた）。
    do {
        check("ポップアップの幅は 220 以下", PopupLayout.width <= 220)
        for subject in ["デバイス", "ディスプレイ"] {
            for pinned in [true, false] {
                let note = PopupLayout.pinnedNote(pinned: pinned, subject: subject)
                check("\(subject) の説明（固定 \(pinned)）は 1 行 24 文字以内", note.split(separator: "\n").allSatisfy { $0.count <= 24 })
                check("\(subject) の説明（固定 \(pinned)）は 3 行以内", note.split(separator: "\n").count <= 3)
            }
        }
        check("接続されていない説明も、改行されて短い",
              PopupLayout.unavailableNote(name: "とても長い名前の AirPods Pro").split(separator: "\n").allSatisfy { $0.count <= 24 })
    }

    // グループ名の確定：前後の空白を除き、空なら元の名前に戻す。長すぎる名前は切る。
    do {
        check("前後の空白を除く", GroupName.commit("  仕事  ", previous: "A") == "仕事")
        check("空にしたら元の名前に戻す", GroupName.commit("", previous: "仕事") == "仕事")
        check("空白だけでも元の名前に戻す", GroupName.commit("   \n", previous: "仕事") == "仕事")
        check("改行は空白にして 1 行にする", GroupName.commit("a\nb", previous: "x") == "a b")
        check("長すぎる名前は 40 文字で切る", GroupName.commit(String(repeating: "あ", count: 60), previous: "x").count == 40)
        check("そのままの名前はそのまま", GroupName.commit("開発", previous: "x") == "開発")
    }

    // 文字サイズの定義：直書き（.system(size: 数字)）を Typo に集める。値は変えない（見た目は同じ）。
    do {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: "Sources")) ?? []
        var raw: [String] = []
        for file in files where file.hasSuffix(".swift") && file != "Typo.swift" {
            guard let text = try? String(contentsOfFile: "Sources/\(file)", encoding: .utf8) else { continue }
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.range(of: "\\.system\\(size: [0-9]", options: .regularExpression) != nil {
                raw.append("\(file):\(index + 1)")
            }
        }
        check("文字サイズの直書きが残っていない（Typo を使う）: \(raw.prefix(3))", raw.isEmpty)
        let sizes = [Typo.tiny, Typo.caption, Typo.label, Typo.symbolSmall, Typo.symbol, Typo.glyph, Typo.glyphLarge, Typo.hero]
        check("Typo の大きさは小さい順", sizes == sizes.sorted())
    }

}
