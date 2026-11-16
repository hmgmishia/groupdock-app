import AppKit
import CryptoKit

// ドラッグ＆ドロップのロジックだけを確かめる（UI は通さない）。
let store = Store()

// 既存の状態を消して、決まった並びにする。
store.groups = []
store.kept = []
let safari = AppRef(path: "/Applications/Safari.app")
let notes = AppRef(path: "/Applications/Notes.app")
let mail = AppRef(path: "/Applications/Mail.app")
store.kept = [safari, notes, mail]

var failures: [String] = []
func check(_ name: String, _ condition: Bool) {
    print((condition ? "PASS " : "FAIL ") + name)
    if !condition { failures.append(name) }
}

// 1) アイコンを重ねると新しいグループ（iPhone のフォルダ）
let before = store.groups.count
let madeID = store.createGroup(from: safari.id, with: notes.id)
check("重ねてフォルダができる", store.groups.count == before + 1)
check("フォルダに 2 つ入る", store.groups.last?.apps.count == 2)
check("元の並びから消える", !store.kept.contains { $0.id == safari.id } && store.kept.count == 1)

// 2) グループへアプリを入れる
if let groupID = madeID {
    store.move(appID: mail.id, intoGroup: groupID)
    check("グループへ移せる",
          store.groups.first(where: { $0.id == groupID })?.apps.contains { $0.id == mail.id } == true)
    check("移したアプリは一覧から消える", !store.kept.contains { $0.id == mail.id })
}

// 3) 並べ替え（同じ並びの中で順番が変わる）
store.groups = []
store.kept = [safari, notes, mail]
store.reorder(appID: mail.id, before: safari.id)
check("並べ替えが効く", store.kept.first?.id == mail.id)
do {
    let rects: [String: NSRect] = [
        "app:a": NSRect(x: 0, y: 0, width: 50, height: 50),
        "app:b": NSRect(x: 60, y: 0, width: 50, height: 50),
    ]
    check("隙間に落とすと近いタイルが返る",
          TileHitTest.nearestID(to: CGPoint(x: 55, y: 25), rects: rects, prefix: "app:", excluding: "app:a", within: 24) == "app:b")
    check("遠いなら返らない",
          TileHitTest.nearestID(to: CGPoint(x: 500, y: 25), rects: rects, prefix: "app:", excluding: "", within: 24) == nil)
}
store.kept = [safari, notes, mail]
store.reorder(appID: safari.id, before: notes.id, after: true)
check("対象の後ろへ挿入できる", store.kept.map(\.id) == [notes.id, safari.id, mail.id])
store.groups = [Group(name: "G", apps: [notes])]
store.kept = [safari]
store.reorder(appID: safari.id, before: notes.id, after: true)
check("グループの中へ挿入できる", store.groups[0].apps.map(\.id) == [notes.id, safari.id] && store.kept.isEmpty)
store.reorder(appID: safari.id, before: notes.id)
store.moveToEnd(appID: safari.id)
check("グループから外せる（一覧の末尾へ）", store.kept.last?.id == safari.id && store.groups[0].apps.map(\.id) == [notes.id])

// 4) グループ同士を重ねると統合
store.groups = [Group(name: "A", apps: [safari]), Group(name: "B", apps: [notes])]
if let a = store.groups.first?.id, let b = store.groups.last?.id {
    store.merge(groupID: a, into: b)
    check("グループが統合される", store.groups.count == 1 && store.groups[0].apps.count == 2)
}

// 5) 固定アプリは動かせない
store.groups = []
store.kept = [AppRef(path: "/System/Library/CoreServices/Finder.app")]
let finderID = store.kept[0].id
store.moveToEnd(appID: finderID)
check("固定アプリは並べ替えできない", store.kept.first?.id == finderID)

// 6) 当たり判定（ウィンドウ内の左上原点 → 画面座標の左下原点）
let windowFrame = NSRect(x: 1404, y: 2154, width: 1032, height: 94)
let containerHeight: CGFloat = 94
let screenRects: [String: NSRect] = [
    "app:/Applications/Safari.app": TileHitTest.screenRect(
        CGRect(x: 100, y: 25, width: 50, height: 44),
        windowFrame: windowFrame, containerHeight: containerHeight),
    "app:/Applications/Notes.app": TileHitTest.screenRect(
        CGRect(x: 160, y: 25, width: 50, height: 44),
        windowFrame: windowFrame, containerHeight: containerHeight),
    "group:AAAA": TileHitTest.screenRect(
        CGRect(x: 220, y: 18, width: 50, height: 58),
        windowFrame: windowFrame, containerHeight: containerHeight),
]
check("タイルの中心を当てられる",
      TileHitTest.id(atScreenPoint: CGPoint(x: 1529, y: 2201), rects: screenRects) == "app:/Applications/Safari.app")
check("隣のタイルと取り違えない",
      TileHitTest.id(atScreenPoint: CGPoint(x: 1589, y: 2201), rects: screenRects) == "app:/Applications/Notes.app")
check("グループにも当たる",
      TileHitTest.id(atScreenPoint: CGPoint(x: 1649, y: 2201), rects: screenRects) == "group:AAAA")
check("外は何も返さない",
      TileHitTest.id(atScreenPoint: CGPoint(x: 1420, y: 2201), rects: screenRects) == nil)
check("y の反転が効いている（上端の外は当たらない）",
      TileHitTest.id(atScreenPoint: CGPoint(x: 1529, y: 2240), rects: screenRects) == nil)

// 7) グループを消したら戻ってこない（保存して読み直す）
store.groups = [Group(name: "消す", apps: [safari])]
store.remove(store.groups[0])
check("消したグループは残らない", store.groups.isEmpty)

// 8) 起動時の自動追加で、グループが勝手に作られない
store.groups = []
store.kept = []
store.autoAdd("/Applications/Safari.app")
check("自動追加でグループは作られない", store.groups.isEmpty)
check("自動追加は何も足さない（起動しただけは残さない区分）", store.kept.isEmpty)
store.addToStrip(paths: ["/Applications/Safari.app"])
check("追加ボタンはアプリ一覧の末尾に残す＝オンで入る", store.kept.last?.path == "/Applications/Safari.app" && store.kept.last?.keepWhenQuit == true)

// 9) グループに入れたアプリは「実行中」に重複して出さない／外したアプリは戻らない
store.groups = [Group(name: "重複なし", apps: [safari, notes])]
store.kept = [mail]
let listedPaths = Set(
    store.kept.map(\.path)
    + store.groups.flatMap { $0.apps.map(\.path) }
)
check("グループに入れたアプリは一覧側の対象から外れる",
      listedPaths.contains(safari.path) && listedPaths.contains(notes.path))
check("外したアプリは hidden に入る（実行中に出ない）", store.hiddenRunning.isEmpty)

store.removeEverywhere(safari.path)
check("外すと hidden に入る", store.hiddenRunning.contains(safari.path))
store.keepOnStrip(safari.path)
check("もう一度置いたら hidden から外れる", !store.hiddenRunning.contains(safari.path))

// 10) 追加したアプリは再起動しても残る（保存して読み直す）
store.groups = []
store.kept = [safari, notes]
let reloaded = Store()
check("保存した並びが読み直せる",
      reloaded.kept.contains { $0.path == safari.path } && reloaded.kept.contains { $0.path == notes.path })

// 11) 横長グラフ（chart）
check("カンマ区切りを数値の並びにする",
      WidgetLibrary.parseSeries("12,18,25") == [12, 18, 25])
check("空白・改行区切りも読める",
      WidgetLibrary.parseSeries("12 18\n25\t30") == [12, 18, 25, 30])
check("数値でない混ざりは捨てる",
      WidgetLibrary.parseSeries("12, abc, 25") == [12, 25])

var wide = Widget(kind: .trend)
check("推移は既定で正方形", wide.shape == .square)
wide.shape = .wide
check("横長に切り替えられる", wide.shape == .wide)
check("推移は数値（グラフ用の点）を返す", WidgetValues.sample(wide) != nil)

let chartDefinition = WidgetDefinition(id: "test.chart", title: "テスト")
var chart = Widget(definition: chartDefinition)
check("ライブラリの text 型は正方形", chart.shape == .square)
var chartChart = WidgetDefinition(id: "test.chart2", title: "グラフ")
chartChart.type = "chart"
chart = Widget(definition: chartChart)
check("ライブラリの chart 型は横長になる", chart.shape == .wide)

// 12) 外部ウィジェットの取り込み（再ビルド・再起動なし）
let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("groupdock-tests-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
WidgetLibrary.directoryOverride = temp

// 単体の JSON を取り込む
let incomingDir = temp.appendingPathComponent("incoming")
try? FileManager.default.createDirectory(at: incomingDir, withIntermediateDirectories: true)
let jsonSource = incomingDir.appendingPathComponent("source.json")
try? """
{ "id": "test.simple", "title": "取り込みテスト", "type": "text", "command": "echo 42", "interval": 30 }
""".write(to: jsonSource, atomically: true, encoding: .utf8)
do {
    let def = try WidgetLibrary.importItem(at: jsonSource)
    check("JSON を取り込める", def.id == "test.simple")
} catch {
    check("JSON を取り込める", false)
}
check("取り込んだ定義が一覧に出る", WidgetLibrary.definition(id: "test.simple") != nil)
check("取り込みはアプリの再起動を要さない", WidgetLibrary.definitions.contains { $0.id == "test.simple" })

// バンドル（.groupwidget）を取り込む
// 取り込み元は、取り込み先（ライブラリのフォルダ）の外に置く。
let incoming = temp.appendingPathComponent("incoming")
try? FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
let bundleSource = incoming.appendingPathComponent("sample.groupwidget")
try? FileManager.default.createDirectory(at: bundleSource, withIntermediateDirectories: true)
try? """
{ "id": "test.bundle", "title": "バンドル", "type": "chart", "command": "cat {bundle}/data.txt", "interval": 10 }
""".write(to: bundleSource.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
try? "10,20,30".write(to: bundleSource.appendingPathComponent("data.txt"), atomically: true, encoding: .utf8)
do {
    let def = try WidgetLibrary.importItem(at: bundleSource)
    check("バンドルを取り込める", def.id == "test.bundle")
    check("バンドルは横長グラフとして扱う", def.isChart)
    check("バンドルの場所が入る", def.bundlePath != nil)
    if let path = def.bundlePath {
        check("バンドルの中身がコピーされる",
              FileManager.default.fileExists(atPath: path + "/data.txt"))
        let expanded = CommandGuard.expand("cat {bundle}/data.txt", definition: def, values: [:])
        // シェルを通さないので、引用なしで素直にパスが入る。
        check("{bundle} が展開される",
              expanded.hasPrefix("cat /") && expanded.hasSuffix("/data.txt"))
    } else {
        check("バンドルの中身がコピーされる", false)
        check("{bundle} が展開される", false)
    }
} catch {
    check("バンドルを取り込める", false)
    check("バンドルは横長グラフとして扱う", false)
    check("バンドルの場所が入る", false)
}

// フォルダを直接見張る（置いただけで読み込まれる）
let watcherFile = temp.appendingPathComponent("watched.json")
try? """
{ "id": "test.watched", "title": "見張り", "type": "text", "command": "echo 1" }
""".write(to: watcherFile, atomically: true, encoding: .utf8)
check("置いただけで再読み込みされる", WidgetLibrary.reloadIfChanged())
check("見張りで見つかる", WidgetLibrary.definition(id: "test.watched") != nil)
check("変化が無ければ読み直さない", !WidgetLibrary.reloadIfChanged())

WidgetLibrary.directoryOverride = nil

// 13) 実行許可（アプリ内で範囲を絞る）
let def = WidgetDefinition(id: "test.exec", title: "実行テスト")
var policyDefinition = def
policyDefinition.command = "echo 42"
policyDefinition.parameters = [
    WidgetParameter(id: "value", label: "値", kind: "text", defaultValue: "abc"),
]

// 許可していない定義は実行しない
WidgetLibrary.policy = WidgetPolicy(approved: [])
check("未承認のウィジェットは実行しない", WidgetLibrary.run(policyDefinition, values: [:]) == nil)

// 承認すれば実行できる
WidgetLibrary.policy = WidgetPolicy(approved: ["test.exec"])
check("承認したウィジェットは実行できる", WidgetLibrary.run(policyDefinition, values: [:]) == "42")

// 許可はウィジェットごと：別のウィジェットを許可しても、このウィジェットは実行しない
WidgetLibrary.policy = WidgetPolicy(approved: ["another.widget"])
check("許可はウィジェットごと（別のものを許可しても実行しない）", WidgetLibrary.run(policyDefinition, values: [:]) == nil)
check("通信は許可したウィジェットだけ",
      WidgetPolicy(approved: ["a"], networkApproved: ["a"]).canUseNetwork("a")
      && !WidgetPolicy(approved: ["a"], networkApproved: ["a"]).canUseNetwork("b"))
check("通信の許可だけではコマンドを実行できない", !WidgetPolicy(approved: [], networkApproved: ["a"]).canRun("a"))

// 危険な文字を入れても追加のコマンドは動かない（引用される）
WidgetLibrary.policy = WidgetPolicy(approved: ["test.exec"])
var injection = WidgetDefinition(id: "test.inject", title: "注入テスト")
injection.command = "echo {value}"
injection.parameters = [WidgetParameter(id: "value", label: "値", defaultValue: "x")]
WidgetLibrary.policy.approved.insert("test.inject")
let injected = WidgetLibrary.run(injection, values: ["value": "$(touch /tmp/groupdock-pwned);whoami"])
check("パラメータ経由のコマンド追加は拒否される", injected == nil)
check("注入でファイルが作られない",
      !FileManager.default.fileExists(atPath: "/tmp/groupdock-pwned"))

// 改行は落とし、長さも制限する
check("改行は空白になる", WidgetLibrary.sanitize("a\nb") == "a b")
check("長すぎる値は切り詰める", WidgetLibrary.sanitize(String(repeating: "a", count: 500)).count == 200)
check("シェル引用が壊れない", WidgetLibrary.shellQuote("it's") == "'it'\\''s'")

// 環境変数でも渡している
let env = WidgetLibrary.environment(for: policyDefinition, values: ["value": "hello"])
check("値は環境変数でも渡る", env["GROUPWIDGET_VALUE"] == "hello")

// ネットワークは既定で拒否するプロファイルを使う
check("通信拒否のプロファイルがある", WidgetLibrary.noNetworkProfile.contains("(deny network*)"))

WidgetLibrary.policy = WidgetPolicy()

// 14) 検閲層（シェルを通さない・許可したプログラムだけ）
func rejected(_ command: String) -> Bool {
    (try? CommandGuard.parse(command, definition: nil, values: [:])) == nil
}

check("sh は拒否", rejected("sh -c 'echo hi'"))
check("bash は拒否", rejected("bash -c 'echo hi'"))
check("curl は拒否", rejected("curl https://example.com"))
check("wget は拒否", rejected("wget https://example.com"))
check("python は拒否", rejected("python3 -c 'print(1)'"))
check("パイプは拒否", rejected("ps aux | grep x"))
check("セミコロンは拒否", rejected("date; whoami"))
check("コマンド置換は拒否", rejected("echo $(whoami)"))
check("バッククォートは拒否", rejected("echo `whoami`"))
check("リダイレクトは拒否", rejected("echo hi > /tmp/x"))
check("括弧展開は拒否", rejected("echo {a,b}"))
check("許可した ps は通る", !rejected("ps -A -o %cpu"))
check("許可した date は通る", !rejected("date +%H:%M"))
check("許可した echo は通る", !rejected("echo hello"))

do {
    let parsed = try CommandGuard.parse("ps -A -o %cpu", definition: nil, values: [:])
    check("実行ファイルが絶対パスになる", parsed.executable.path == "/bin/ps")
    check("引数がそのまま渡る", parsed.arguments == ["-A", "-o", "%cpu"])
} catch {
    check("実行ファイルが絶対パスになる", false)
    check("引数がそのまま渡る", false)
}

// パラメータはトークンの中だけに展開され、シェル記号は拒否される
var tokenDefinition = WidgetDefinition(id: "test.token", title: "トークン")
tokenDefinition.parameters = [WidgetParameter(id: "name", label: "名前", defaultValue: "abc")]
do {
    let parsed = try CommandGuard.parse("echo {name}", definition: tokenDefinition, values: ["name": "hello"])
    check("パラメータが 1 つの引数として渡る", parsed.arguments == ["hello"])
} catch {
    check("パラメータが 1 つの引数として渡る", false)
}
let injectedToken = (try? CommandGuard.parse(
    "echo {name}", definition: tokenDefinition, values: ["name": "$(touch /tmp/x)"]))
check("パラメータにシェル記号を入れても拒否", injectedToken == nil)

// 15) 固まったときの見張り（ウォッチドッグ）
let now = Date()
check("1 秒止まっただけでは固まりとみなさない",
      !Watchdog.isStalled(lastBeat: now, now: now.addingTimeInterval(1)))
check("4 秒止まったら固まりとみなす",
      Watchdog.isStalled(lastBeat: now, now: now.addingTimeInterval(4)))
check("しきい値は 4 秒", Watchdog.stallThreshold == 4)
check("復旧を試す間隔は 15 秒", Watchdog.retryInterval == 15)

// 16) 吹き出しの位置（帯のすぐ外側に出る）
let strip = CGRect(x: 363, y: 8, width: 1074, height: 104)
let bubbleSize = CGSize(width: 404, height: 248)

let bottom = BubblePlacement.origin(anchor: strip, size: bubbleSize, position: "bottom")
check("下置きの吹き出しは帯の上（帯の上端 + 8）", bottom.y == strip.maxY + 8)
check("下置きの吹き出しは帯の中央に揃う", bottom.x == strip.midX - bubbleSize.width / 2)

let left = BubblePlacement.origin(anchor: CGRect(x: 8, y: 300, width: 88, height: 700), size: bubbleSize, position: "left")
check("左置きの吹き出しは帯の右", left.x == 8 + 88 + 8)

let right = BubblePlacement.origin(anchor: CGRect(x: 1704, y: 300, width: 88, height: 700), size: bubbleSize, position: "right")
check("右置きの吹き出しは帯の左", right.x == 1704 - bubbleSize.width - 8)

// 17) タイル位置の比較（毎回の再レイアウトを防ぐ）
let rectA: [String: CGRect] = ["app:a": CGRect(x: 10, y: 10, width: 50, height: 44)]
let rectSame: [String: CGRect] = ["app:a": CGRect(x: 10.4, y: 10.2, width: 50.3, height: 44.1)]
let rectMoved: [String: CGRect] = ["app:a": CGRect(x: 30, y: 10, width: 50, height: 44)]
check("ほぼ同じ位置は同じとみなす（再レイアウトしない）",
      TileHitTest.sameRects(rectA, rectSame))
check("動いたら違うとみなす", !TileHitTest.sameRects(rectA, rectMoved))
check("数が違えば違うとみなす", !TileHitTest.sameRects(rectA, [:]))

// 配置は状態から計算するだけ（SwiftUI の測定に頼らない）。
do {
    let a = StripEntry(id: "a", kind: .history, size: CGSize(width: 66, height: 76))
    let b = StripEntry(id: "b", kind: .trash, size: CGSize(width: 66, height: 76))
    let row = StripLayout.make([a, b], vertical: false, gap: 8)
    check("横置きは左から並ぶ", row.frames["a"]!.minX < row.frames["b"]!.minX && row.frames["a"]!.minY == row.frames["b"]!.minY)
    check("横置きの幅は並びの合計", row.size.width == 66 * 2 + 8 + (StripLayout.shadowMargin + 6) * 2)
    let column = StripLayout.make([a, b], vertical: true, gap: 8)
    check("縦置きは上から並ぶ", column.frames["a"]!.minY < column.frames["b"]!.minY && column.frames["a"]!.minX == column.frames["b"]!.minX)
    check("同じ入力なら同じ枠（純粋）", row == StripLayout.make([a, b], vertical: false, gap: 8))
    check("空でも落ちない", StripLayout.make([], vertical: false, gap: 8).placed.isEmpty)

    let bubble = BubbleLayout.make(count: 5, iconSize: 52)
    check("吹き出しのタイル数が件数と同じ", bubble.tiles.count == 5)
    check("吹き出しの枠が重ならない", bubble.tiles[0].intersection(bubble.tiles[1]).width <= 0.5)
    check("「＋」は最後のタイルの次", bubble.plus.minX > bubble.tiles[4].minX || bubble.plus.minY > bubble.tiles[4].minY)
    check("件数が増えると高くなる", BubbleLayout.make(count: 12, iconSize: 52).size.height > bubble.size.height)

    let s = Store()
    check("帯の並びに重複が無い", Set(s.stripLayout().order).count == s.stripLayout().order.count)
}

// 挿入プレビュー：入れる位置の判定と、周りが退く配置。
do {
    let rects: [String: NSRect] = [
        "app:a": NSRect(x: 0, y: 0, width: 60, height: 60),
        "app:b": NSRect(x: 70, y: 0, width: 60, height: 60),
        "group:g": NSRect(x: 140, y: 0, width: 60, height: 60),
    ]
    let left = TileHitTest.insertion(at: CGPoint(x: 75, y: 30), rects: rects, dragged: "app:a", vertical: false)
    check("相手の左端は前に挿入", left?.id == "app:b" && left?.after == false)
    let right = TileHitTest.insertion(at: CGPoint(x: 125, y: 30), rects: rects, dragged: "app:a", vertical: false)
    check("相手の右端は後ろに挿入", right?.id == "app:b" && right?.after == true)
    check("中央は重ねる（挿入しない）",
          TileHitTest.insertion(at: CGPoint(x: 100, y: 30), rects: rects, dragged: "app:a", vertical: false) == nil)
    let gap = TileHitTest.insertion(at: CGPoint(x: 65, y: 30), rects: rects, dragged: "app:z", vertical: false)
    check("隙間は近いタイルの前後に挿入", gap != nil)
    check("グループの上は挿入しない",
          TileHitTest.insertion(at: CGPoint(x: 142, y: 30), rects: rects, dragged: "app:a", vertical: false) == nil)

    let a = StripEntry(id: "a", kind: .history, size: CGSize(width: 66, height: 76))
    let b = StripEntry(id: "b", kind: .trash, size: CGSize(width: 66, height: 76))
    let c = StripEntry(id: "c", kind: .settings, size: CGSize(width: 66, height: 76))
    let base = StripLayout.make([a, b, c], vertical: false, gap: 8)
    let open = StripLayout.make([a, b, c], vertical: false, gap: 8, opening: (id: "b", after: false), extra: 74)
    check("挿入位置より前は動かない", open.frames["a"] == base.frames["a"])
    check("挿入位置以降は空き分だけ退く", open.frames["b"]!.minX == base.frames["b"]!.minX + 74
          && open.frames["c"]!.minX == base.frames["c"]!.minX + 74)
    let after = StripLayout.make([a, b, c], vertical: false, gap: 8, opening: (id: "b", after: true), extra: 74)
    check("後ろに挿入なら相手は動かない", after.frames["b"] == base.frames["b"] && after.frames["c"]!.minX == base.frames["c"]!.minX + 74)

    let plain = BubbleLayout.make(count: 4, iconSize: 52)
    let opened = BubbleLayout.make(count: 4, iconSize: 52, opening: 1)
    check("吹き出し：空きより前は動かない", opened.tiles[0] == plain.tiles[0])
    check("吹き出し：空き以降は 1 つ後ろへ退く", opened.tiles[1] == plain.tiles[2] && opened.tiles[3] == plain.tiles[4 > 3 ? 3 : 3] || opened.tiles[1].minX != plain.tiles[1].minX)
}

// 「残す」区分は終了しても消えない。区分けをまたぐ移動とグループ化はできない。
do {
    let s = Store()
    let a = AppRef(path: "/Applications/Safari.app")
    let b = AppRef(path: "/System/Applications/Notes.app")
    s.groups = [Group(name: "G", apps: [b])]
    s.kept = [a]
    s.removeOnQuit(a.path)
    s.removeOnQuit(b.path)
    check("残す区分（一覧）は終了しても残る", s.kept.contains { $0.path == a.path })
    check("残す区分（グループ）は終了しても残る", s.groups[0].apps.contains { $0.path == b.path })
    let stranger = "/Applications/Stranger.app"
    check("実行中だけのアプリは残さない区分", s.isInKeepZone(appID: stranger) == false)
    check("残す区分のアプリは残す区分", s.isInKeepZone(appID: a.id) && s.isInKeepZone(appID: b.id))
    check("残さない区分とはグループを作れない", s.createGroup(from: a.id, with: stranger) == nil)
    let before = s.kept.map(\.id)
    s.reorder(appID: a.id, before: stranger)
    check("区分けをまたぐ並べ替えはしない", s.kept.map(\.id) == before)
    s.move(appID: stranger, intoGroup: s.groups[0].id)
    check("残さない区分からグループへは入れない", s.groups[0].apps.count == 1)
}

// 滑らかに動かす：枠が変われば値が変わる（補間の合図）、ドラッグ中は大きさを固定する。
do {
    let a = StripEntry(id: "a", kind: .history, size: CGSize(width: 66, height: 76))
    let b = StripEntry(id: "b", kind: .trash, size: CGSize(width: 66, height: 76))
    let base = StripLayout.make([a, b], vertical: false, gap: 8)
    let open = StripLayout.make([a, b], vertical: false, gap: 8, opening: (id: "b", after: false), extra: 74)
    check("道を空けると配置の値が変わる（補間の合図）", base != open)
    let s = Store()
    s.groups = []
    s.kept = []
    let idle = s.stripWindowSize()
    s.dragging = true
    let during = s.stripWindowSize()
    check("ドラッグ中はウィンドウに空き 1 つ分を確保する", during.width > idle.width || during.height > idle.height)
    s.insertion = DropState.Insertion(id: "app:/System/Library/CoreServices/Finder.app", after: false)
    check("道を空けてもウィンドウの大きさは変わらない（飛ばない）", s.stripWindowSize() == during)
    s.dragging = false
    s.insertion = nil
    check("ドラッグが終わると元の大きさに戻る", s.stripWindowSize() == idle)
}

// ウィジェット整理：再生中の廃止、更新頻度の出し分け、日付の詳細、導線、余白。
do {
    check("再生中は種類にある（操作できるものとして作り直した）", WidgetKind(rawValue: "nowPlaying") == .nowPlaying)
    check("存在しない種類は無い", WidgetKind(rawValue: "removedKind") == nil)
    let json = """
    {"widgets":[{"kind":"clock"},{"kind":"removedKind"},{"kind":"cpu"}],"padding":2}
    """.data(using: .utf8)!
    let prefs = try? JSONDecoder().decode(Prefs.self, from: json)
    check("廃止した種類があっても他のウィジェットは読める", prefs?.widgets.map(\.kind) == [.clock, .cpu])
    check("古い設定の余白（padding）が残っていても読める", prefs != nil)
    check("時計は更新頻度の設定を出さない", Widget(kind: .clock).hasRefreshSetting == false)
    check("日付は更新頻度の設定を出さない", Widget(kind: .date).hasRefreshSetting == false)
    check("CPU は更新頻度の設定を出す", Widget(kind: .cpu).hasRefreshSetting)
    check("日付は秒まで出すとき 1 秒未満で更新", Widget(kind: .date).effectiveInterval < 1)
    var noSeconds = Widget(kind: .date)
    noSeconds.showSeconds = false
    check("日付は秒を出さないなら 1 秒", noSeconds.effectiveInterval == 1)
    check("日付を押すと時刻も出る", WidgetValues.detail(Widget(kind: .date)).contains(":"))
    check("ディスク・メモリには導線がある", WidgetKind.disk.destination != nil && WidgetKind.memory.destination != nil)
    let narrow = StripLayout.make([StripEntry(id: "a", kind: .history, size: CGSize(width: 66, height: 76))],
                                  vertical: false, gap: 0, padding: 0)
    let wide = StripLayout.make([StripEntry(id: "a", kind: .history, size: CGSize(width: 66, height: 76))],
                                vertical: false, gap: 0, padding: 12)
    check("余白を小さくすると帯が小さくなる", narrow.size.width < wide.size.width && narrow.size.height < wide.size.height)
}

// ポップアップの操作：上位プロセスの選別、音量の解釈、終了信号の安全装置。
do {
    let ps = """
      101  12.5  204800 Google Chrome Helper
      202  80.0   10240 node
        1   3.0    1024 launchd
      303   1.0  512000 Slack
    """
    let list = ProcessList.parse(ps)
    check("ps の出力を読める（名前に空白があっても）", list.count == 4 && list[0].name == "Google Chrome Helper")
    check("メモリは MB に直す", abs(list[0].memoryMB - 200) < 0.01)
    let byCPU = ProcessList.top(list, by: .cpu, count: 3, excluding: -1)
    check("CPU の多い順", byCPU.map(\.pid) == [202, 101, 303])
    let byMem = ProcessList.top(list, by: .memory, count: 2, excluding: -1)
    check("メモリの多い順（件数で切る）", byMem.map(\.pid) == [303, 101])
    check("pid 1 は対象に入れない", !byCPU.contains { $0.pid == 1 })
    check("自分自身は対象に入れない", !ProcessList.top(list, by: .cpu, count: 3, excluding: 202).contains { $0.pid == 202 })
    check("壊れた行は読み飛ばす", ProcessList.parse("abc\n  5 1.0 100 ok").map(\.pid) == [5])

    check("pid 1 には信号を送らない", ProcessList.signal(1, force: true) == false)
    check("自分自身には信号を送らない", ProcessList.signal(ProcessInfo.processInfo.processIdentifier, force: true) == false)

    let volume = SystemControls.parseVolume("output volume:68, input volume:44, alert volume:49, output muted:true")
    check("音量とミュートを読める", volume?.level == 68 && volume?.muted == true)
    check("音量が読めなければ nil", SystemControls.parseVolume("missing value") == nil)
    check("実際の ps を読める", !ProcessList.read().isEmpty)
}

// 再生中：解釈（ミュージック・ブラウザ）、AppleScript の組み立て、表示パターン。
do {
    let sep = NowPlayingParse.separator
    let music = NowPlayingParse.delimited("playing\(sep)曲名\(sep)歌手\(sep)45", source: .music)
    check("ミュージックの出力を読める", music?.title == "曲名" && music?.artist == "歌手" && music?.playing == true && music?.volume == 45)
    check("止まっていれば再生中ではない", NowPlayingParse.delimited("paused\(sep)曲\(sep)歌手\(sep)10", source: .music)?.playing == false)
    check("曲名が空なら読まない", NowPlayingParse.delimited("playing\(sep)\(sep)歌手", source: .music) == nil)

    let json = #"{"t":"動画の題","a":"チャンネル","p":true,"v":80,"img":"data:image/jpeg;base64,AAEC"}"#
    let web = NowPlayingParse.browser(json, source: .chrome)
    check("ブラウザの JSON を読める", web?.title == "動画の題" && web?.artist == "チャンネル" && web?.playing == true && web?.volume == 80)
    check("サムネの data URL を画像データにする", web?.artwork == Data([0, 1, 2]))
    check("壊れた JSON は読まない", NowPlayingParse.browser("not json", source: .chrome) == nil)
    check("音量は 0〜100 に収める", NowPlayingParse.browser(#"{"t":"a","v":150}"#, source: .safari)?.volume == 100)

    let a = PlaybackInfo(source: .music, title: "a", artist: "", playing: false, volume: nil, artwork: nil)
    let b = PlaybackInfo(source: .chrome, title: "b", artist: "", playing: true, volume: nil, artwork: nil)
    check("複数あれば再生中を優先", NowPlayingParse.pick([a, b])?.title == "b")
    check("再生中が無ければ先頭", NowPlayingParse.pick([a])?.title == "a")
    check("何も無ければ nil", NowPlayingParse.pick([]) == nil)

    check("再生・次・前の JavaScript が違う",
          Set([PlaybackAction.toggle, .next, .previous].map { NowPlayingScript.controlJS($0) }).count == 3)
    check("音量の JavaScript は 0〜100 に収める", NowPlayingScript.volumeJS(500).contains("100/100"))
    check("Chrome は execute、Safari は do JavaScript を使う",
          NowPlayingScript.browser(.chrome, js: "x").contains("execute t javascript")
          && NowPlayingScript.browser(.safari, js: "x").contains("do JavaScript"))
    // 別ウィンドウ（全画面・別の Space・別ディスプレイ）で再生中のタブを取りこぼさない。
    // 読み取りは 1 回の走査（再生中を見つけたら即返す）、上限はウィンドウごと、操作だけ再生中のタブを先に探す。
    let reader = NowPlayingScript.browser(.chrome, js: "READ")
    check("読み取りは窓の走査が 1 回（Apple Events の回数を増やさない）",
          reader.components(separatedBy: "repeat with w in windows").count == 2)
    check("タブの数の上限は、ウィンドウごとに数え直す（前の窓で締め出さない）",
          reader.contains("repeat with w in windows\nset n to 0") && !reader.contains("set n to 0\ntell application"))
    let actor = NowPlayingScript.browser(.chrome, js: "ACT", act: true)
    check("操作は、再生中のタブを先に探す（探る JavaScript を使う）", actor.contains(NowPlayingScript.playingProbeJS))
    check("読み取りには、探る JavaScript を使わない（費用が増えない）", !reader.contains(NowPlayingScript.playingProbeJS))

    // 実際の AppleScript を、見本の窓とタブで走らせる（Chrome が無くても、走査の順序と上限を確かめられる）。
    // 窓 1 は 45 タブ（4 番目だけ再生が途中で止まっている）、窓 2（別の Space を想定）に再生中のタブ。
    func scanned(_ probe: String?, windows: Int = 2) -> String {
        let setup = """
        on fakeRun(t, js)
        if started of t then return "{\\"t\\":\\"" & (name of t) & "\\",\\"p\\":" & ((playing of t) as text) & "}"
        return ""
        end fakeRun
        set win1 to {}
        repeat with i from 1 to 45
        set end of win1 to {started:(i = 4), playing:false, name:"paused-tab"}
        end repeat
        set win2 to {{started:true, playing:true, name:"playing-tab"}}
        set fakeWindows to {win1, win2}
        """
        let body = NowPlayingScript.scan(
            call: "my fakeRun(t, \"READ\")",
            probe: probe.map { _ in "my fakeProbe(t)" },
            windows: "fakeWindows", tabs: "w")
        let probeHandler = """
        on fakeProbe(t)
        if (playing of t) then return "1"
        return "0"
        end fakeProbe
        """
        return AppleScriptRunner.run(probeHandler + "\n" + setup + "\n" + body).text ?? "(失敗)"
    }
    check("別窓で再生中のタブがあれば、先の窓の止まったタブより、それを返す（読み取り）",
          scanned(nil).contains("playing-tab") && scanned(nil).contains("\"p\":true"))
    check("操作は、別窓の再生中のタブを選ぶ", scanned("probe").contains("playing-tab"))
    check("先の窓が 45 タブでも、別窓のタブを締め出さない（上限はウィンドウごと）",
          scanned(nil).contains("playing-tab"))
    check("ミュージックの操作は playpause", NowPlayingScript.playerControl(.music, .toggle).contains("playpause"))
    check("音量は 0〜100 に収める", NowPlayingScript.playerVolume(.spotify, -5).hasSuffix("to 0"))
    check("対象が自動なら操作を送らない（落ちない）", { NowPlayingControl.send(.toggle, to: .auto); return true }())

    check("表示パターンは幅が広がる順",
          PlayerLayout.thumbnail.width(icon: 50) < PlayerLayout.thumbnailPlay.width(icon: 50)
          && PlayerLayout.thumbnailPlay.width(icon: 50) < PlayerLayout.transport.width(icon: 50)
          && PlayerLayout.transport.width(icon: 50) < PlayerLayout.full.width(icon: 50))
    var widget = Widget(kind: .nowPlaying)
    widget.playerLayout = .thumbnail
    check("再生中の幅は表示パターンで決まる", widget.tileWidth(icon: 50) == 50)
    widget.playerLayout = .full
    check("フルは幅が広い", widget.tileWidth(icon: 50) > 150)
    let data = try? JSONEncoder().encode(widget)
    let back = data.flatMap { try? JSONDecoder().decode(Widget.self, from: $0) }
    check("表示パターンが保存される", back?.playerLayout == .full)
    check("古い設定に対象（playerSource）が残っていても読める",
          (try? JSONDecoder().decode(Widget.self, from: #"{"kind":"nowPlaying","playerSource":"chrome"}"#.data(using: .utf8)!))?.kind == .nowPlaying)
    check("古い設定（項目なし）でも既定で読める",
          (try? JSONDecoder().decode(Widget.self, from: #"{"kind":"nowPlaying"}"#.data(using: .utf8)!))?.playerLayout == .full)
}

// MediaRemote：辞書の解釈、命令番号、取れないときの安全な失敗、通信・書き込み API が無いこと。
do {
    let info: [String: Any] = [
        "kMRMediaRemoteNowPlayingInfoTitle": "曲名",
        "kMRMediaRemoteNowPlayingInfoArtist": "歌手",
        "kMRMediaRemoteNowPlayingInfoArtworkData": Data([1, 2, 3]),
    ]
    let parsed = MediaRemoteBridge.parse(info, playing: true, wantArtwork: true)
    check("MediaRemote の辞書を読める", parsed?.title == "曲名" && parsed?.artist == "歌手" && parsed?.playing == true)
    check("MediaRemote のサムネを取り出す", parsed?.artwork == Data([1, 2, 3]))
    check("サムネ不要なら取り出さない", MediaRemoteBridge.parse(info, playing: false, wantArtwork: false)?.artwork == nil)
    check("MediaRemote の出どころは system", parsed?.source == .system)
    check("題が無ければ nil", MediaRemoteBridge.parse([:], playing: true, wantArtwork: true) == nil)
    check("命令番号は再生/停止 2・次 4・前 5",
          MediaRemoteBridge.command(.toggle) == 2 && MediaRemoteBridge.command(.next) == 4
          && MediaRemoteBridge.command(.previous) == 5)
    check("取れなくても落ちない（空なら nil）", { _ = MediaRemoteBridge.read(wantArtwork: false); return true }())
    check("system には音量の操作を送らない（音量を読んだブラウザが無ければ書き込み先が無い）", {
        let system = PlaybackInfo(source: .system, title: "曲", artist: "", playing: true, volume: nil, artwork: nil)
        NowPlayingControl.setVolume(10, on: system)
        return NowPlayingParse.volumeTarget(for: system) == nil
    }())

    // 再生中のソースに、外部送信・ファイル書き込み・外部プロセス起動の API を入れない（AGENTS.md の条件）。
    let source = (try? String(contentsOfFile: "Sources/NowPlaying.swift", encoding: .utf8))
        ?? (try? String(contentsOfFile: "../Sources/NowPlaying.swift", encoding: .utf8)) ?? ""
    let forbidden = ["URLSession", "URLRequest", "NWConnection", "FileManager", "createFile", "removeItem", "moveItem",
                     "copyItem", "FileHandle", "Process()", "do shell script", "XMLHttpRequest", "sendBeacon",
                     "WebSocket", "localStorage", "document.cookie", ".write(to"]
    let found = forbidden.filter { source.contains($0) }
    check("再生中のソースを読めている", source.contains("MediaRemoteBridge"))
    check("再生中のソースに通信・書き込み API が無い \(found)", found.isEmpty)
}

// 履歴：重複しない、引数違いは別、新しいものが先頭、件数の上限。
do {
    let plain = AppRef(path: "/Applications/Safari.app")
    let withArgs = AppRef(path: "/Applications/Safari.app", arguments: "-x 1")
    let other = AppRef(path: "/System/Applications/Notes.app")
    var list: [AppRef] = []
    list = HistoryList.adding(plain, to: list)
    list = HistoryList.adding(other, to: list)
    list = HistoryList.adding(plain, to: list)
    check("同じアプリは重複しない", list.count == 2 && list.filter { $0.id == plain.id }.count == 1)
    check("新しく起動したものが先頭へ移る", list.first?.id == plain.id)
    list = HistoryList.adding(withArgs, to: list)
    check("引数違いは別の項目として残る", list.count == 3 && list.contains { $0.id == withArgs.id } && list.contains { $0.id == plain.id })
    list = HistoryList.adding(withArgs, to: list)
    check("同じ引数の再起動は重複しない", list.filter { $0.id == withArgs.id }.count == 1)
    var many: [AppRef] = []
    for n in 0..<30 { many = HistoryList.adding(AppRef(path: "/Applications/App\(n).app"), to: many) }
    check("件数は上限まで", many.count == HistoryList.limit && many.first?.path == "/Applications/App29.app")
    check("hover の情報に引数が出る", HistoryInfo.text(withArgs).contains("-x 1") && HistoryInfo.text(plain).contains("引数: なし"))
    check("hover の情報にパスが出る", HistoryInfo.text(plain).contains("/Applications/Safari.app"))
}

// 帯の構成：追加ボタンが無い、グループは「残す」アプリと同じ区画、名前の有無でセル高さが変わる。
do {
    let s = Store()
    s.groups = [Group(name: "G", apps: [])]
    s.kept = [AppRef(path: "/Applications/Safari.app")]
    let entries = s.stripEntries()
    check("追加ボタンは帯に無い", !entries.contains { $0.id == "button:plus" })
    let ids = entries.map(\.id)
    let keptAt = ids.firstIndex { $0.hasPrefix("app:/Applications/Safari.app") }
    let groupAt = ids.firstIndex { $0.hasPrefix("group:") }
    check("グループは残すアプリのすぐ後ろ（間に区切りが無い）",
          keptAt != nil && groupAt == keptAt.map { $0 + 1 })
    s.prefs.showNames = false
    let without = s.stripLayout().size.height
    s.prefs.showNames = true
    let with = s.stripLayout().size.height
    check("名前を出すと帯が高くなる", with > without)
    check("名前は基本オフ", Prefs().showNames == false)
    let loaded = try? JSONDecoder().decode(Prefs.self, from: #"{"iconSize":50}"#.data(using: .utf8)!)
    check("古い設定でも名前はオフ", loaded?.showNames == false)
}

// アイコンの格子（履歴・インスタンス選択）：件数から枠と全体の大きさが決まり、はみ出さない。
do {
    let one = GridMetrics.make(count: 1, iconSize: 50, showNames: false)
    check("1 件なら格子は 1 マスの幅（件数に合わせる）", one.size.width == one.tiles[0].width && one.tiles.count == 1)
    let many = GridMetrics.make(count: 20, iconSize: 50, showNames: false)
    check("タイルは全体の中に収まる", many.tiles.allSatisfy { $0.maxX <= many.size.width + 0.01 && $0.maxY <= many.size.height + 0.01 })
    check("タイルどうしは重ならない", many.tiles[0].intersection(many.tiles[1]).width <= 0.5)
    check("件数が増えると高くなる（履歴の崩れ防止）", many.size.height > one.size.height)
    check("0 件でも落ちない", GridMetrics.make(count: 0, iconSize: 50, showNames: true).tiles.isEmpty)
    check("名前を出すと 1 行が高くなる",
          GridMetrics.make(count: 5, iconSize: 50, showNames: true).size.height
          > GridMetrics.make(count: 5, iconSize: 50, showNames: false).size.height)
}

// インスタンス：引数違いも同じアプリとして数える、引数の取り出し、青丸の条件。
do {
    let exe = "/Applications/Unity.app/Contents/MacOS/Unity"
    check("引数なしを読める", AppInstances.arguments(fromCommandLine: exe, executablePath: exe) == "")
    check("引数を取り出す", AppInstances.arguments(fromCommandLine: "\(exe) -projectPath /Users/me/Game", executablePath: exe) == "-projectPath /Users/me/Game")
    check("実行ファイルが見つからなければ空", AppInstances.arguments(fromCommandLine: "other", executablePath: exe) == "")
    let output = "  101 \(exe) -projectPath /A\n  102 \(exe)\n  103 /x/y\n"
    let list = AppInstances.parse(output, executables: [101: exe, 102: exe])
    check("ps の出力から pid と引数を読む", list.map(\.pid) == [101, 102] && list[0].arguments == "-projectPath /A" && list[1].arguments == "")
    check("対象外の pid は読み飛ばす", list.count == 2)
    let counts = AppInstances.counts(paths: ["/a.app", "/a.app", "/b.app"])
    check("引数が違っても同じアプリとして数える", counts["/a.app"] == 2 && counts["/b.app"] == 1)
    check("2 つ以上で複数", AppInstances.isMultiple(2) && !AppInstances.isMultiple(1) && !AppInstances.isMultiple(0))
    check("説明に pid と引数が出る", AppInstances.info(list[0], name: "Unity").contains("pid 101") && AppInstances.info(list[0], name: "Unity").contains("-projectPath /A"))
    check("引数なしの説明", AppInstances.info(list[1], name: "Unity").contains("引数: なし"))
}

// アイコンの更新検知：更新日時が変わったときだけ読み直す。確認は一定間隔まで。
do {
    IconCache.entries = [:]
    let path = "/test/App.app"
    var loads = 0
    var stampValue = Date(timeIntervalSince1970: 1000)
    let load: (String) -> NSImage = { _ in loads += 1; return NSImage(size: NSSize(width: 1, height: 1)) }
    let start = Date(timeIntervalSince1970: 5000)
    _ = IconCache.image(for: path, now: start, stamp: { _ in stampValue }, load: load)
    check("最初は 1 回読む", loads == 1)
    _ = IconCache.image(for: path, now: start.addingTimeInterval(1), stamp: { _ in stampValue }, load: load)
    check("間隔内は確認も読み直しもしない", loads == 1)
    _ = IconCache.image(for: path, now: start.addingTimeInterval(10), stamp: { _ in stampValue }, load: load)
    check("更新日時が同じなら読み直さない", loads == 1)
    stampValue = Date(timeIntervalSince1970: 2000)
    _ = IconCache.image(for: path, now: start.addingTimeInterval(20), stamp: { _ in stampValue }, load: load)
    check("更新日時が変わったら読み直す", loads == 2)
    _ = IconCache.image(for: path, now: start.addingTimeInterval(30), stamp: { _ in stampValue }, load: load)
    check("読み直したあとは、また読み直さない", loads == 2)
    check("変化が無ければ描き直しの合図は出ない", IconCache.refreshChanged(now: start.addingTimeInterval(40), stamp: { _ in stampValue }, load: load) == false)
    stampValue = Date(timeIntervalSince1970: 3000)
    check("変化があれば描き直しの合図が出る", IconCache.refreshChanged(now: start.addingTimeInterval(50), stamp: { _ in stampValue }, load: load) == true)
    check("合図の後は読み直しが 1 回増える", loads == 3)
    check("存在しないパスの更新日時は nil（落ちない）", IconCache.bundleStamp("/no/such/app.app") == nil)
    check("実在するバンドルの更新日時を読める", IconCache.bundleStamp("/System/Applications/Notes.app") != nil)
    IconCache.entries = [:]
}

// 再生中の補助ライブラリ：JSON の解釈（アプリを問わない取得）と、呼べる関数の限定。
do {
    let line = #"{"playing":1,"kMRMediaRemoteNowPlayingInfoTitle":"動画の題","kMRMediaRemoteNowPlayingInfoArtist":"チャンネル","artwork":"AAEC"}"#
    let info = MediaRemoteBridge.parseHelper(line, wantArtwork: true)
    check("補助ライブラリの JSON を読める", info?.title == "動画の題" && info?.artist == "チャンネル" && info?.playing == true)
    check("補助ライブラリのサムネを画像データにする", info?.artwork == Data([0, 1, 2]))
    check("再生していなければ playing は false",
          MediaRemoteBridge.parseHelper(#"{"playing":0,"kMRMediaRemoteNowPlayingInfoTitle":"a"}"#, wantArtwork: false)?.playing == false)
    check("題が無い JSON は nil", MediaRemoteBridge.parseHelper("{}", wantArtwork: false) == nil)
    check("壊れた出力は nil", MediaRemoteBridge.parseHelper("not json", wantArtwork: false) == nil)
    check("呼べる関数は決まった 6 つだけ",
          [MediaRemoteHelper.Call.getWithArtwork, .getPlain, .toggle, .next, .previous, .seek].map(\.rawValue)
          == ["gd_get_artwork", "gd_get_plain", "gd_toggle", "gd_next", "gd_previous", "gd_seek"])
    check("位置の秒は数字だけで渡す（負は 0）", MediaRemoteHelper.seekValue(83.456) == "83.46" && MediaRemoteHelper.seekValue(-5) == "0.00")
    check("perl の台本に引数を埋め込まない（ARGV で渡す）", MediaRemoteHelper.script.contains("$ARGV[0]") && MediaRemoteHelper.script.contains("$ARGV[1]"))
    let helper = (try? String(contentsOfFile: "Helper/gdnowplaying.m", encoding: .utf8)) ?? ""
    let forbidden = ["NSURLSession", "NSURLConnection", "writeToFile", "writeToURL", "NSFileManager", "fopen", "socket"]
    check("補助ライブラリを読めている", helper.contains("MRMediaRemoteGetNowPlayingInfo"))
    check("補助ライブラリに通信・書き込みが無い", forbidden.allSatisfy { !helper.contains($0) })
}

// アプリ定義のメニュー：子メニュー・区切り・無効・チェックを AppKit の項目にそのまま写す。
do {
    let entries = [
        DockMenu.Entry(title: "新規ウインドウ", isSeparator: false, isEnabled: true, isChecked: false, children: []),
        DockMenu.Entry(title: "", isSeparator: true, isEnabled: false, isChecked: false, children: []),
        DockMenu.Entry(title: "オプション", isSeparator: false, isEnabled: true, isChecked: false, children: [
            DockMenu.Entry(title: "なし", isSeparator: false, isEnabled: true, isChecked: true, children: []),
        ]),
        DockMenu.Entry(title: "無効な項目", isSeparator: false, isEnabled: false, isChecked: false, children: []),
    ]
    var pressed: [String] = []
    let items = DockMenu.menuItems(entries) { pressed = $0 }
    check("項目の数と区切り線を保つ", items.count == 4 && items[1].isSeparatorItem)
    check("子メニューを保つ", items[2].submenu?.items.first?.title == "なし")
    check("チェックを保つ", items[2].submenu?.items.first?.state == .on)
    check("無効を保つ", items[3].isEnabled == false)
    if let sub = items[2].submenu?.items.first as? ClosureMenuItem {
        _ = sub.target?.perform(sub.action)
    }
    check("子メニューの項目は親からの題名の並びで押す", pressed == ["オプション", "なし"])
}

// 応答なしの判定：答えが返らなかったときだけ応答なし。自分自身は応答している。
do {
    check("答えが返らなければ応答なし", AppResponsiveness.isHung(.cannotComplete))
    check("成功は応答あり", AppResponsiveness.isHung(.success) == false)
    check("属性が無いだけなら応答あり", AppResponsiveness.isHung(.attributeUnsupported) == false)
    check("権限が無いだけなら応答あり", AppResponsiveness.isHung(.apiDisabled) == false)
    check("応答なしは基本は空", Store().hungPaths.isEmpty)
}

// ウィンドウ単位のインスタンス：2 つ以上のウィンドウを持つプロセスだけ、ウィンドウごとに分ける。
do {
    let a = AppInstance(pid: 10, arguments: "-x")
    let b = AppInstance(pid: 20, arguments: "")
    let expanded = AppInstances.expand([a, b], windows: [10: ["文書1", "文書2"], 20: ["一つだけ"]])
    check("ウィンドウが 2 つ以上なら分ける", expanded.count == 3 && expanded[0].windowTitle == "文書1" && expanded[1].window == 1)
    check("ウィンドウが 1 つならプロセスのまま", expanded[2].window == nil && expanded[2].pid == 20)
    check("分けても引数を保つ", expanded[0].arguments == "-x")
    check("id は重ならない", Set(expanded.map(\.id)).count == 3)
    check("選べる数はプロセスとウィンドウの多い方", AppInstances.choiceCount(processes: 1, windows: 3) == 3 && AppInstances.choiceCount(processes: 2, windows: 0) == 2)
    check("説明にウィンドウ名が出る", AppInstances.info(expanded[0], name: "Pages").contains("ウィンドウ: 文書1"))
    let s = Store()
    check("何も動いていなければ複数ではない", s.hasMultipleInstances("/no/such.app") == false)
}

// ウィジェットの見え方：時計・日付は横長の文字が既定、横長でもグラフとは限らない、幅は内容で決まる。
do {
    check("時計の既定は横長の文字", Widget(kind: .clock).resolvedFace == .wideText)
    check("日付の既定は横長の文字", Widget(kind: .date).resolvedFace == .wideText)
    check("CPU の既定はリング", Widget(kind: .cpu).resolvedFace == .ring)
    check("推移の既定はグラフ", Widget(kind: .trend).resolvedFace == .wideChart)
    check("時計にグラフは選べない", !WidgetKind.clock.availableFaces.contains(.wideChart))
    check("数値には横長の文字・バー・グラフが選べる",
          [.wideText, .wideBar, .wideChart].allSatisfy { WidgetKind.cpu.availableFaces.contains($0) })
    var clock = Widget(kind: .clock)
    clock.face = .wideChart
    check("選べない見え方は種類の既定に戻す", clock.resolvedFace == .wideText)
    var oldWide = Widget(kind: .cpu)
    oldWide.shape = .wide
    check("古い設定の横長はグラフとして読む", oldWide.resolvedFace == .wideChart)
    var cpuText = Widget(kind: .cpu)
    cpuText.face = .wideText
    check("横長でも文字だけにできる（グラフ固定ではない）", cpuText.resolvedFace == .wideText && cpuText.resolvedFace.isWide)

    let icon: CGFloat = 50
    var seconds = Widget(kind: .clock)
    seconds.showSeconds = true
    var noSeconds = Widget(kind: .clock)
    noSeconds.showSeconds = false
    check("時計は正方形より広い（時刻が切れない）", seconds.tileWidth(icon: icon) > icon)
    check("秒を出すと時計の幅が広がる（内容で決まる）", seconds.tileWidth(icon: icon) > noSeconds.tileWidth(icon: icon))
    var date = Widget(kind: .date)
    date.showTime = true
    check("日付＋時刻は時計より広い", date.tileWidth(icon: icon) > seconds.tileWidth(icon: icon))
    check("リングは正方形", Widget(kind: .cpu).tileWidth(icon: icon) == icon)
    check("全角は半角より広く見積もる",
          WidgetSizing.textWidth("あいう", fontSize: 10) > WidgetSizing.textWidth("abc", fontSize: 10))
    let saved = try? JSONEncoder().encode(cpuText)
    check("見え方が保存される", saved.flatMap { try? JSONDecoder().decode(Widget.self, from: $0) }?.face == .wideText)
    check("古い設定（見え方なし）でも読める",
          (try? JSONDecoder().decode(Widget.self, from: #"{"kind":"clock"}"#.data(using: .utf8)!))?.resolvedFace == .wideText)
}

// グループの余白：設定で吹き出しの縁が変わり、大きさは件数と余白から決まる。
do {
    let narrow = BubbleLayout.make(count: 3, iconSize: 50, padding: 4)
    let wide = BubbleLayout.make(count: 3, iconSize: 50, padding: 24)
    check("余白を広げると吹き出しが広がる", wide.size.width > narrow.size.width && wide.size.height > narrow.size.height)
    check("余白の分だけタイルが内側に寄る", wide.tiles[0].minX == 24 && narrow.tiles[0].minX == 4)
    check("余白は負にならない", BubbleLayout.make(count: 1, iconSize: 50, padding: -10).padding == 0)
    check("件数が増えると吹き出しが高くなる",
          BubbleLayout.make(count: 12, iconSize: 50, padding: 12).size.height > BubbleLayout.make(count: 3, iconSize: 50, padding: 12).size.height)
    check("古い設定にグループの余白が残っていても読める",
          (try? JSONDecoder().decode(Prefs.self, from: #"{"groupPadding":20,"tilePadding":4,"padding":3}"#.data(using: .utf8)!)) != nil)
}

// グループの吹き出しはアプリの数に合わせる（固定幅にしない）。
do {
    let two = BubbleLayout.make(count: 2, iconSize: 36, padding: 2)
    let five = BubbleLayout.make(count: 5, iconSize: 36, padding: 2)
    check("アプリが増えると吹き出しが広がる", five.size.width > two.size.width)
    check("少ないときは最大幅より狭い", two.contentWidth < BubbleLayout.gridWidth)
    check("見出しが入る幅は確保する", BubbleLayout.make(count: 0, iconSize: 36).contentWidth >= BubbleLayout.headerMinWidth)
    let many = BubbleLayout.make(count: 40, iconSize: 36, padding: 2)
    check("多いときは最大幅で折り返す", many.contentWidth <= BubbleLayout.gridWidth && many.size.height >= five.size.height)
    check("右の余白と左の余白が同じ（違和感のある空きを作らない）",
          abs((two.size.width - two.padding) - (two.plus.maxX)) < 0.5 || two.contentWidth == BubbleLayout.headerMinWidth)
}

// ホバーの名前、ウィジェットの並べ替え。
do {
    let s = Store()
    let safari = AppRef(path: "/Applications/Safari.app")
    let withArgs = AppRef(path: "/Applications/Unity.app", arguments: "-projectPath /A")
    s.kept = [safari, withArgs]
    s.groups = [Group(name: "仕事", apps: [AppRef(path: "/System/Applications/Notes.app")])]
    check("アプリの名前を出す", s.hoverName(for: "app:\(safari.id)") == "Safari")
    check("引数つきは引数も出す", s.hoverName(for: "app:\(withArgs.id)") == "Unity（-projectPath /A）")
    check("固定アプリの名前を出す", s.hoverName(for: "app:/System/Library/CoreServices/Finder.app") == "Finder")
    check("グループは名前と数", s.hoverName(for: "group:\(s.groups[0].id.uuidString)") == "仕事（1 個）")
    check("ボタンの名前", s.hoverName(for: "button:trash") == "ゴミ箱")
    check("知らない id は出さない", s.hoverName(for: "sep:1") == nil)

    let a = Widget(kind: .clock), b = Widget(kind: .cpu), c = Widget(kind: .memory)
    s.prefs.widgets = [a, b, c]
    s.reorderWidget(c.id, before: a.id)
    check("ウィジェットを前へ入れ替える", s.prefs.widgets.map(\.id) == [c.id, a.id, b.id])
    s.reorderWidget(c.id, before: b.id, after: true)
    check("ウィジェットを後ろへ入れ替える", s.prefs.widgets.map(\.id) == [a.id, b.id, c.id])
    s.reorderWidget(a.id, before: a.id)
    check("自分自身へは動かない", s.prefs.widgets.map(\.id) == [a.id, b.id, c.id])
    check("ホバーでウィジェットの名前", s.hoverName(for: "widget:\(b.id.uuidString)") == "CPU")

    let rects: [String: NSRect] = [
        "widget:A": NSRect(x: 0, y: 0, width: 60, height: 60),
        "widget:B": NSRect(x: 70, y: 0, width: 60, height: 60),
        "app:x": NSRect(x: 140, y: 0, width: 60, height: 60),
    ]
    let hit = TileHitTest.insertion(at: CGPoint(x: 125, y: 30), rects: rects, dragged: "widget:A", vertical: false, prefix: "widget:")
    check("ウィジェットはウィジェットの前後に入る", hit?.id == "widget:B" && hit?.after == true)
    check("ウィジェットはアプリの上には入らない",
          TileHitTest.insertion(at: CGPoint(x: 145, y: 30), rects: rects, dragged: "widget:A", vertical: false, prefix: "widget:") == nil)
}

// グループの吹き出しは一定の高さで止め、超えた分はスクロールする。
do {
    let few = BubbleLayout.make(count: 4, iconSize: 40, padding: 8)
    let many = BubbleLayout.make(count: 80, iconSize: 40, padding: 8)
    let cell = BubbleLayout.cell(iconSize: 40, showNames: false)
    check("少ないときはスクロールしない", few.maxScroll == 0)
    check("多いときは高さが上限で止まる", many.viewportHeight == cell.height * BubbleLayout.maxVisibleRows)
    check("多いときはスクロールできる", many.maxScroll > 0)
    check("全体の高さは上限 + 見出し + 余白", many.size.height == many.gridTop + many.viewportHeight + many.padding)
    check("スクロール量は範囲に収める", many.clampScroll(-10) == 0 && many.clampScroll(99999) == many.maxScroll)
    let last = many.tiles[many.tiles.count - 1]
    check("先頭では最後のタイルは見えない", many.isVisible(last, scroll: 0) == false)
    check("一番下までスクロールすると最後のタイルが見える", many.isVisible(last, scroll: many.maxScroll))
    check("先頭では最初のタイルが見える", many.isVisible(many.tiles[0], scroll: 0))
    check("一番下では最初のタイルは見えない", many.isVisible(many.tiles[0], scroll: many.maxScroll) == false)
    check("スクロール量は基本 0", DropState().bubbleScroll == 0)
}

// 右クリックメニュー：選ばずに一瞬で閉じたときだけ出し直す。
do {
    check("一瞬で閉じて何も選んでいなければ出し直す", MenuPresenter.shouldRetry(openFor: 0.02, chose: false, attempt: 1))
    check("選んで閉じたら出し直さない", MenuPresenter.shouldRetry(openFor: 0.02, chose: true, attempt: 1) == false)
    check("しばらく開いていたら出し直さない（自分で閉じた）", MenuPresenter.shouldRetry(openFor: 1.0, chose: false, attempt: 1) == false)
    check("出し直しは上限まで", MenuPresenter.shouldRetry(openFor: 0.02, chose: false, attempt: MenuPresenter.maximumAttempts) == false)
}

// グループ名とホバーの名前は途切れさせない。
do {
    let short = BubbleLayout.titleWidth("仕事")
    let long = BubbleLayout.titleWidth("とても長いグループの名前で途切れやすいもの")
    check("長い名前は幅が広い", long > short)
    let narrow = BubbleLayout.make(count: 1, iconSize: 36, titleWidth: short)
    let wide = BubbleLayout.make(count: 1, iconSize: 36, titleWidth: long)
    check("長い名前に合わせて吹き出しが広がる", wide.size.width > narrow.size.width)
    check("見出しに名前とボタンが収まる", wide.contentWidth >= long + BubbleLayout.headerButtonsWidth)
    let s = Store()
    let group = Group(name: "とても長いグループの名前で途切れやすいもの", apps: [AppRef(path: "/Applications/Safari.app")])
    check("Store の枠も名前の幅を入れる", s.bubbleLayout(for: group).contentWidth >= long + BubbleLayout.headerButtonsWidth)

    let area = NSRect(x: 0, y: 0, width: 1000, height: 800)
    let tile = NSRect(x: 980, y: 0, width: 40, height: 40)
    let f = HoverPlacement.frame(size: NSSize(width: 300, height: 24), tile: tile, position: "bottom", screen: area)
    check("札は画面の右端で内側に寄せる（切れない）", f.maxX <= area.maxX && f.width == 300)
    let g = HoverPlacement.frame(size: NSSize(width: 300, height: 24), tile: NSRect(x: 0, y: 0, width: 40, height: 40), position: "bottom", screen: area)
    check("札は画面の左端で内側に寄せる", g.minX >= area.minX)
    let c = HoverPlacement.frame(size: NSSize(width: 100, height: 24), tile: NSRect(x: 450, y: 100, width: 40, height: 40), position: "bottom", screen: area)
    check("札はタイルの真上の中央", abs(c.midX - 470) < 0.5 && c.minY == 146)
}

// 吹き出しは、開いたグループのタイルの位置から出す。
do {
    let strip = CGRect(x: 300, y: 8, width: 1200, height: 80)
    let size = CGSize(width: 200, height: 150)
    let tile = CGRect(x: 1300, y: 16, width: 44, height: 56)
    let p = BubblePlacement.origin(anchor: strip, size: size, position: "bottom", tile: tile)
    check("下置き：タイルの真上の中央に出す", p.x == tile.midX - size.width / 2 && p.y == strip.maxY + 8)
    let none = BubblePlacement.origin(anchor: strip, size: size, position: "bottom")
    check("タイルが分からなければ帯の中央", none.x == strip.midX - size.width / 2)
    let vstrip = CGRect(x: 8, y: 200, width: 80, height: 900)
    let vtile = CGRect(x: 16, y: 900, width: 56, height: 44)
    let l = BubblePlacement.origin(anchor: vstrip, size: size, position: "left", tile: vtile)
    check("左置き：帯の右、タイルと同じ高さ", l.x == vstrip.maxX + 8 && l.y == vtile.midY - size.height / 2)
}

// 再生位置・できる操作・掴める所。
do {
    let sep = NowPlayingParse.separator
    let music = NowPlayingParse.delimited("playing\(sep)曲\(sep)歌手\(sep)40\(sep)12.5\(sep)275.0", source: .music)
    check("ミュージックの位置と長さを読む", music?.position == 12.5 && music?.duration == 275)
    check("ミュージックは位置と音量を操作できる", music?.capabilities.seek == true && music?.capabilities.volume == true)
    let spotify = NowPlayingParse.delimited("paused\(sep)曲\(sep)歌手\(sep)40\(sep)3,5\(sep)200000", source: .spotify)
    check("Spotify の長さはミリ秒を秒に直す（小数点の「,」も読む）", spotify?.duration == 200 && spotify?.position == 3.5)
    let old = NowPlayingParse.delimited("playing\(sep)曲\(sep)歌手\(sep)40", source: .music)
    check("長さが無ければ位置は動かせない", old?.capabilities.seek == false && old?.position == nil)

    let yt = NowPlayingParse.browser(#"{"t":"動画","p":true,"v":50,"ct":30,"du":600,"nx":true}"#, source: .chrome)
    check("ブラウザの位置と長さを読む", yt?.position == 30 && yt?.duration == 600 && yt?.capabilities.seek == true)
    check("ブラウザは「次へ」があれば次へ進める", yt?.capabilities.next == true)
    let live = NowPlayingParse.browser(#"{"t":"ライブ","p":true,"v":50,"ct":30,"du":0,"nx":false}"#, source: .chrome)
    check("長さの無い配信は位置を動かせず、次へも無い", live?.capabilities.seek == false && live?.capabilities.next == false)
    check("位置を動かす JavaScript は数字だけ", NowPlayingScript.seekJS(42.5).contains("e.currentTime=42.50"))
    check("位置を動かす AppleScript", NowPlayingScript.playerSeek(.music, 9).hasSuffix("set player position to 9.00"))

    let sys = MediaRemoteBridge.parseHelper(#"{"playing":1,"kMRMediaRemoteNowPlayingInfoTitle":"a","elapsed":10,"duration":100}"#, wantArtwork: false)
    check("システムの位置と長さを読む", sys?.position == 10 && sys?.duration == 100 && sys?.capabilities.seek == true)
    check("システムは音量を変えられない（灰色にする）", sys?.capabilities.volume == false)

    var info = PlaybackInfo(source: .music, title: "a", artist: "", playing: true, volume: nil, artwork: nil,
                            position: 10, duration: 20, fetchedAt: Date(timeIntervalSince1970: 0))
    check("再生中は読んだ後の経過を足す", info.currentPosition(at: Date(timeIntervalSince1970: 3)) == 13)
    check("長さを超えない", info.currentPosition(at: Date(timeIntervalSince1970: 100)) == 20)
    info.playing = false
    check("止まっていれば進まない", info.currentPosition(at: Date(timeIntervalSince1970: 3)) == 10)
    check("時刻の書き方", PlaybackInfo.clock(75) == "1:15" && PlaybackInfo.clock(3725) == "1:02:05")
    check("何も再生していなければ全部できない", PlaybackCapabilities.none == PlaybackCapabilities(toggle: false, next: false, previous: false, seek: false, volume: false))

    let tile = CGRect(x: 100, y: 0, width: 200, height: 50)
    check("フル表示はサムネの所で掴める", NowPlayingGrab.allowsDrag(at: CGPoint(x: 120, y: 25), tile: tile, layout: .full, icon: 50))
    check("フル表示の操作部分では掴まない（つまみの操作を奪わない）",
          NowPlayingGrab.allowsDrag(at: CGPoint(x: 220, y: 25), tile: tile, layout: .full, icon: 50) == false)
    check("サムネだけの表示はどこでも掴める", NowPlayingGrab.allowsDrag(at: CGPoint(x: 290, y: 25), tile: tile, layout: .thumbnail, icon: 50))
    check("前・再生・次は端だけで掴む",
          NowPlayingGrab.allowsDrag(at: CGPoint(x: 102, y: 25), tile: tile, layout: .transport, icon: 50)
          && !NowPlayingGrab.allowsDrag(at: CGPoint(x: 200, y: 25), tile: tile, layout: .transport, icon: 50))
}

// 再生元が受け付ける命令から、できる操作を決める（できない前へ・次へは灰色）。
do {
    let one = MediaRemoteBridge.capabilities(enabled: [2, 24, 3], hasDuration: true)
    check("1 曲だけの再生は前へ・次へができない", one.next == false && one.previous == false)
    check("再生/停止と位置はできる", one.toggle && one.seek)
    let list = MediaRemoteBridge.capabilities(enabled: [2, 4, 5, 24], hasDuration: true)
    check("再生リストなら前へ・次へができる", list.next && list.previous)
    check("長さが無ければ位置は動かせない", MediaRemoteBridge.capabilities(enabled: [24], hasDuration: false).seek == false)
    check("再生 0 と一時停止 1 があれば切り替えられる", MediaRemoteBridge.capabilities(enabled: [0, 1], hasDuration: false).toggle)
    let line = #"{"playing":1,"kMRMediaRemoteNowPlayingInfoTitle":"a","elapsed":1,"duration":10,"commands":[2,24]}"#
    let info = MediaRemoteBridge.parseHelper(line, wantArtwork: false)
    check("補助ライブラリの命令一覧を読む", info?.capabilities.next == false && info?.capabilities.toggle == true)
    let old = MediaRemoteBridge.parseHelper(#"{"playing":1,"kMRMediaRemoteNowPlayingInfoTitle":"a"}"#, wantArtwork: false)
    check("命令一覧が無ければ今までどおり（前へ・次へを出す）", old?.capabilities.next == true)
}

// 緑丸：通常のアプリでなくても、動いていれば数える。終了済みと自分は数えない。
do {
    let ids = RunningMatch.bundleIDs([
        RunningMatch.Entry(id: "com.unity3d.UnityEditor5.x", terminated: false, isSelf: false),
        RunningMatch.Entry(id: "gone.app", terminated: true, isSelf: false),
        RunningMatch.Entry(id: "dev.hmgm.GroupDock", terminated: false, isSelf: true),
        RunningMatch.Entry(id: nil, terminated: false, isSelf: false),
    ])
    check("動いているアプリの識別子を数える", ids == ["com.unity3d.UnityEditor5.x"])
}

// 重い確認の間引き。
do {
    check("止まっている再生は再生中より間隔が長い", PollPolicy.nowPlayingInterval(playing: false) > PollPolicy.nowPlayingInterval(playing: true))
    check("再生中の取得は 1.5 秒より遅い（perl 起動を減らす）", PollPolicy.nowPlayingInterval(playing: true) > 1.5)
    let responsive = (1...30).filter { PollPolicy.checksResponsiveness(tick: $0) }.count
    check("帯が隠れている間はウィンドウ数を数えない", !PollPolicy.checksResponsiveness(tick: 2, hidden: true))
    let icons = (1...30).filter { PollPolicy.checksIcons(tick: $0) }.count
    check("帯が見えている間は毎回ウィンドウ数を数える（青丸を速く出す）", responsive == 30)
    check("アイコンの確認は 10 分の 1 に減る", icons == 3)
}

// 一時的なアプリ：2 秒続くまで枠と履歴に出さない。
do {
    let t0 = Date(timeIntervalSince1970: 1000)
    var seen = RunningSettle.update([:], current: ["/a.app"], now: t0)
    check("起動直後は安定していない", RunningSettle.settled(seen, current: ["/a.app"], now: t0).isEmpty)
    check("起動直後は確認が要る", RunningSettle.hasPending(seen, current: ["/a.app"], now: t0))
    check("2 秒続けば安定する", RunningSettle.settled(seen, current: ["/a.app"], now: t0.addingTimeInterval(2.1)) == ["/a.app"])
    check("安定したら確認は要らない", RunningSettle.hasPending(seen, current: ["/a.app"], now: t0.addingTimeInterval(2.1)) == false)
    seen = RunningSettle.update(seen, current: [], now: t0.addingTimeInterval(1))
    check("すぐ終わったものは忘れる", seen.isEmpty)
    seen = RunningSettle.update(seen, current: ["/a.app"], now: t0.addingTimeInterval(5))
    check("もう一度起動したら数え直す", RunningSettle.settled(seen, current: ["/a.app"], now: t0.addingTimeInterval(5)).isEmpty)
    let mixed = RunningSettle.update(["/old.app": t0], current: ["/old.app", "/new.app"], now: t0.addingTimeInterval(10))
    check("古いものだけ出し、新しいものは待つ",
          RunningSettle.settled(mixed, current: ["/old.app", "/new.app"], now: t0.addingTimeInterval(10)) == ["/old.app"])
}

// ウィジェットの判定タイマー：秒まで出す時計・日付があるときだけ速い。
do {
    var clock = Widget(kind: .clock); clock.showSeconds = true
    var calm = Widget(kind: .clock); calm.showSeconds = false
    check("秒を出す時計があれば 0.25 秒", PollPolicy.widgetTimerInterval([clock, Widget(kind: .cpu)]) == 0.25)
    check("秒を出さなければ 1 秒", PollPolicy.widgetTimerInterval([calm, Widget(kind: .cpu)]) == 1)
    check("数値だけなら 1 秒", PollPolicy.widgetTimerInterval([Widget(kind: .cpu)]) == 1)
    check("ウィジェットが無ければ 5 秒", PollPolicy.widgetTimerInterval([]) == 5)
}

// ホバー判定の間隔：帯の近く・自動で隠す設定のときだけ速い。
do {
    check("帯の近くは 0.2 秒", PollPolicy.hoverInterval(autoHide: false, mouseNear: true) == 0.2)
    check("自動で隠す設定は離れていても 0.2 秒", PollPolicy.hoverInterval(autoHide: true, mouseNear: false) == 0.2)
    check("離れていて自動で隠さなければ 0.5 秒", PollPolicy.hoverInterval(autoHide: false, mouseNear: false) == 0.5)
}

// 帯が隠れている間は更新を止める。
do {
    var clock = Widget(kind: .clock); clock.showSeconds = true
    check("隠れている間はウィジェットのタイマーが遅い", PollPolicy.widgetTimerInterval([clock], hidden: true) == 5)
    check("出ていれば秒の時計は 0.25 秒", PollPolicy.widgetTimerInterval([clock], hidden: false) == 0.25)
    let store = Store()
    store.prefs.widgets = [clock]
    store.stripHidden = true
    store.refreshNowPlaying()
    check("隠れている間は再生の取得を始めない", store.lastNowPlayingPoll == .distantPast)
    store.stripHidden = false
    check("出るとき、再生の取得の間隔をリセットする", store.lastNowPlayingPoll == .distantPast)
}

// アイコンの間隔は 1 つ。帯・グループの中・履歴・インスタンスで共有する。選択枠の余白は固定。
do {
    let icon: CGFloat = 40
    let cell = StripLayout.cell(icon: icon, showNames: false)
    check("選択枠の余白は固定で 1pt", StripLayout.defaultTilePadding == 1 && cell.width == StripLayout.imageSide(icon) + 2)
    check("名前を出すと高さが 14pt 増える", StripLayout.cell(icon: icon, showNames: true).height == cell.height + 14)
    check("グループの中のセルも同じ寸法", BubbleLayout.cell(iconSize: icon, showNames: false) == cell)

    let tight = BubbleLayout.make(count: 4, iconSize: icon, padding: 4, gap: 0)
    let loose = BubbleLayout.make(count: 4, iconSize: icon, padding: 4, gap: 10)
    check("間隔 0 ならタイルが隙間なく並ぶ", tight.tiles[1].minX == tight.tiles[0].maxX)
    check("間隔だけ離れる", loose.tiles[1].minX == loose.tiles[0].maxX + 10)
    check("間隔が広いとグループが広がる", loose.size.width > tight.size.width)
    let gridTight = GridMetrics.make(count: 3, iconSize: icon, showNames: false, gap: 0)
    let gridLoose = GridMetrics.make(count: 3, iconSize: icon, showNames: false, gap: 8)
    check("履歴・インスタンスの格子も間隔を共有する", gridLoose.tiles[1].minX == gridLoose.tiles[0].maxX + 8 && gridTight.tiles[1].minX == gridTight.tiles[0].maxX)
    let group = Group(name: "確認", apps: [AppRef(path: "/Applications/Safari.app"), AppRef(path: "/System/Applications/Notes.app")])
    let store = Store()
    store.prefs.gap = 0
    let a = store.bubbleLayout(for: group)
    store.prefs.gap = 20
    let b = store.bubbleLayout(for: group)
    check("設定の間隔がグループにも効く", b.tiles[1].minX - b.tiles[0].maxX == 20 && a.tiles[1].minX == a.tiles[0].maxX)
    check("帯の間隔も同じ設定", store.stripLayout().size.width > 0)
    check("古い設定の余白は読み飛ばす",
          (try? JSONDecoder().decode(Prefs.self, from: #"{"gap":7,"tilePadding":0}"#.data(using: .utf8)!))?.gap == 7)
}

// 仕切り線・空きの右クリックはウィジェットの追加。帯の仕切りの id は "sep:" で始まる。
do {
    let store = Store()
    store.prefs.widgets = [Widget(kind: .clock)]
    let ids = store.stripLayout().placed.map(\.entry.id)
    check("ウィジェットがあれば仕切り線が帯にある", ids.contains { $0.hasPrefix("sep:") })
    check("仕切り線の枠がある（右クリックを当てられる）",
          store.stripLayout().frames.keys.contains { $0.hasPrefix("sep:") })
}

// 仕切り線：線は細いまま、右クリックの判定（枠）は両側に余白を持つ。隣のタイルには重ならない。
do {
    let store = Store()
    store.prefs.widgets = [Widget(kind: .clock)]
    let placed = store.stripLayout().placed
    guard let index = placed.firstIndex(where: { $0.entry.id.hasPrefix("sep:") }) else {
        check("仕切り線がある", false); exit(1)
    }
    let sep = placed[index].frame
    let wanted = StripLayout.separatorThickness + StripLayout.separatorMargin * 2
    check("仕切り線の枠は余白つきで広い", sep.width == wanted)
    check("線の見た目は 1pt のまま", StripLayout.separatorThickness == 1)
    check("前のタイルと重ならない", placed[index - 1].frame.maxX <= sep.minX)
    check("次のタイルと重ならない", index + 1 >= placed.count || sep.maxX <= placed[index + 1].frame.minX)
    let middle = CGPoint(x: sep.midX + 4, y: sep.midY)
    check("線から少し離れた所でも仕切りに当たる",
          TileHitTest.id(atScreenPoint: middle, rects: store.stripLayout().frames) == placed[index].entry.id)
    store.prefs.position = "left"
    let vertical = store.stripLayout().placed.first { $0.entry.id.hasPrefix("sep:") }!.frame
    check("縦置きでも枠は余白つき", vertical.height == wanted)
}

// 帯のボタン（履歴・ゴミ箱・設定）の選択枠は、アイコンの部分だけ。下に伸びない。
do {
    let store = Store()
    store.prefs.iconSize = 44
    let placed = store.stripLayout().placed
    let app = placed.first { $0.entry.id.hasPrefix("app:") }!.frame
    let button = placed.first { $0.entry.id == "button:settings" }!.frame
    let icon: CGFloat = 44
    check("ボタンの高さはアイコン画像 + 余白だけ",
          button.height == StripLayout.imageSide(icon) + StripLayout.defaultTilePadding * 2)
    check("ボタンはアプリのタイルより緑丸の分だけ低い", app.height - button.height == 8)
    check("ボタンの幅はアプリのタイルと同じ", button.width == app.width)
    check("ボタンは帯の縦の中央に置く", abs(button.midY - app.midY) < 0.5)
    check("ボタンはアプリのタイルの枠の中に収まる", button.minY >= app.minY && button.maxY <= app.maxY)
    store.prefs.showNames = true
    check("名前を出すとボタンも名前の分だけ高くなる",
          StripLayout.buttonHeight(icon: icon, showNames: true) > StripLayout.buttonHeight(icon: icon, showNames: false))
}

// グループの最上段の未読バッジが見切れない：切り取る範囲がバッジの上端より上から始まり、見出しには重ならない。
do {
    for icon in [CGFloat(36), 52, 88] {
        let layout = BubbleLayout.make(count: 5, iconSize: icon, padding: 6)
        let first = layout.tiles[0]
        let imageTop = first.minY + StripLayout.defaultTilePadding
        let badgeTop = imageTop - icon * (BadgeMetrics.heightRatio / 2 + BadgeMetrics.liftRatio)
        let clipTop = layout.gridTop - layout.badgeInset
        check("アイコン \(Int(icon))pt：最上段のバッジが切り取り範囲に入る", badgeTop >= clipTop)
        check("アイコン \(Int(icon))pt：切り取り範囲は見出しに重ならない", clipTop >= layout.padding + BubbleLayout.headerHeight)
    }
}

// ポップアップは外のクリックで閉じ、中のクリックでは閉じない。
do {
    check("他のアプリのクリックで閉じる", PopoverDismissal.shouldDismiss(clickedWindowClass: nil))
    check("帯のクリックで閉じる", PopoverDismissal.shouldDismiss(clickedWindowClass: "DockPanel"))
    check("ポップアップの中のクリックでは閉じない", !PopoverDismissal.shouldDismiss(clickedWindowClass: "_NSPopoverWindow"))
}

// グループの並べ替え（グループの設定から使う）。
do {
    let a = AppRef(path: "/Applications/Safari.app")
    let b = AppRef(path: "/System/Applications/Notes.app")
    let c = AppRef(path: "/System/Applications/Calendar.app")
    check("後ろへ動かす", GroupOrder.move([a, b, c], index: 0, by: 1).map(\.id) == [b, a, c].map(\.id))
    check("前へ動かす", GroupOrder.move([a, b, c], index: 2, by: -1).map(\.id) == [a, c, b].map(\.id))
    check("先頭より前へは動かない", GroupOrder.move([a, b, c], index: 0, by: -1).map(\.id) == [a, b, c].map(\.id))
    check("末尾より後ろへは動かない", GroupOrder.move([a, b, c], index: 2, by: 1).map(\.id) == [a, b, c].map(\.id))
    check("範囲外は何もしない", GroupOrder.move([a], index: 5, by: 1).count == 1)
    check("名前順に並べる", GroupOrder.byName([a, b, c]).map(\.name) == ["Calendar", "Notes", "Safari"])
    let a2 = AppRef(path: "/Applications/Safari.app", arguments: "-x")
    check("同じ名前は引数で並べる", GroupOrder.byName([a2, a]).map(\.arguments) == ["", "-x"])
}

// サイズ変更のつまみ：左右でも内側の縁に出て、内側へ引くと大きくなる。
do {
    let bounds = CGRect(x: 0, y: 0, width: 80, height: 900)
    let left = GrabHandle.frame(in: bounds, position: "left")
    let right = GrabHandle.frame(in: bounds, position: "right")
    let bottom = GrabHandle.frame(in: CGRect(x: 0, y: 0, width: 900, height: 80), position: "bottom")
    check("左置き：つまみは右の縁", left.maxX == bounds.maxX && left.height == GrabHandle.length)
    check("右置き：つまみは左の縁", right.minX == bounds.minX && right.height == GrabHandle.length)
    check("下置き：つまみは上の縁", bottom.maxY == 80 && bottom.width == GrabHandle.length)
    check("左置き：右へ引くと大きくなる", GrabHandle.growth(dx: 10, dy: 0, position: "left") == 10)
    check("右置き：左へ引くと大きくなる", GrabHandle.growth(dx: -10, dy: 0, position: "right") == 10)
    check("下置き：上へ引くと大きくなる", GrabHandle.growth(dx: 0, dy: 10, position: "bottom") == 10)
    check("左右は横に引く", GrabHandle.isHorizontalDrag(position: "left") && !GrabHandle.isHorizontalDrag(position: "bottom"))
}

// 左右に置くときの見た目：下置きとは別に持ち、縦に伸びる。グループ・格子は縦長。
do {
    let icon: CGFloat = 50
    var clock = Widget(kind: .clock); clock.showSeconds = true
    check("左右の時計の既定は縦長の文字", clock.resolvedSideFace == .tallText)
    check("下置きの時計は横長のまま", clock.resolvedFace == .wideText)
    let side = clock.tileSize(icon: icon, vertical: true)
    check("左右の時計は幅がアイコン、縦に伸びる", side.width == icon && side.height > icon)
    check("下置きの時計は高さがアイコン、横に伸びる", clock.tileSize(icon: icon, vertical: false).height == icon)
    check("左右では横長の見え方を選べない", !WidgetKind.clock.sideFaces.contains(.wideText))
    check("下置きでは縦長の見え方を選べない", !WidgetKind.clock.availableFaces.contains(.tallText))
    clock.sideFace = .text
    check("左右の見え方は下置きと別に保存できる", clock.resolvedSideFace == .text && clock.resolvedFace == .wideText)
    var cpu = Widget(kind: .cpu); cpu.face = .ring
    check("下置きで正方形なら左右にも引き継ぐ", cpu.resolvedSideFace == .ring)
    cpu.face = .wideChart
    check("下置きが横長なら左右は既定（リング）", cpu.resolvedSideFace == .ring)
    check("時刻は時:分と:秒に分けて積む", TallText.lines("12:34:56") == ["12:34", ":56"])
    check("日付と時刻は空白で行を分ける", TallText.lines("11/15(日) 9:05") == ["11/15(日)", "9:05"])

    var music = Widget(kind: .nowPlaying)
    music.playerLayout = .full; music.sidePlayerLayout = .thumbnail
    check("再生中は向きごとに表示パターンを持つ", music.playerLook(vertical: true) == .thumbnail && music.playerLook(vertical: false) == .full)
    music.sidePlayerLayout = .full
    let ms = music.tileSize(icon: icon, vertical: true)
    check("左右の再生中（フル）は幅がアイコンで縦に長い", ms.width == icon && ms.height > icon * 2)
    let back = (try? JSONEncoder().encode(clock)).flatMap { try? JSONDecoder().decode(Widget.self, from: $0) }
    check("左右の見え方が保存される", back?.sideFace == .text)

    let store = Store()
    store.prefs.widgets = [Widget(kind: .clock)]
    let bottomWidth = store.stripLayout().placed.first { $0.entry.id.hasPrefix("widget:") }!.frame.width
    store.prefs.position = "left"
    let w = store.stripLayout().placed.first { $0.entry.id.hasPrefix("widget:") }!.frame
    let iconSize = CGFloat(store.prefs.iconSize)
    check("左置きの帯ではウィジェットが横に伸びない（幅はアイコン 1 つ分）", w.width == iconSize + 2 && w.width < bottomWidth)
    check("左置きの帯ではウィジェットが縦に伸びる", w.height > iconSize)

    let wide = BubbleLayout.make(count: 12, iconSize: icon, gap: 4)
    let tall = BubbleLayout.make(count: 12, iconSize: icon, gap: 4, vertical: true)
    check("左右のグループは 3 列まで", Set(tall.tiles.map(\.minX)).count == BubbleLayout.sideColumns)
    check("左右のグループは縦長", tall.size.height > wide.size.height && tall.size.width < wide.size.width)
    let grid = GridMetrics.make(count: 9, iconSize: icon, showNames: false, gap: 4, vertical: true)
    check("左右の履歴・インスタンスも 3 列", Set(grid.tiles.map(\.minX)).count == 3)
    store.prefs.position = "right"
    check("右置きのポップアップは左へ出す", store.popoverEdge == .leading)
    store.prefs.position = "bottom"
    check("下置きのポップアップは上へ出す", store.popoverEdge == .top)
}

// 帯の右クリックメニュー：自動で隠す・表示する場所を、設定画面を開かずに切り替える。
do {
    check("自動で隠すがオンならチェックが付く", StripMenuSpec.autoHideItem(autoHide: true).checked)
    check("自動で隠すがオフならチェックが付かない", !StripMenuSpec.autoHideItem(autoHide: false).checked)
    let places = StripMenuSpec.placeItems(position: "left")
    check("表示する場所は下・左・右", places.map(\.title) == ["下", "左", "右"])
    check("いまの位置にだけチェックが付く", places.map(\.checked) == [false, true, false])
    let toggled = StripMenuSpec.apply(.toggleAutoHide, autoHide: true, position: "bottom")
    check("自動で隠すを切り替える（位置は変えない）", toggled.autoHide == false && toggled.position == "bottom")
    let moved = StripMenuSpec.apply(.place("right"), autoHide: true, position: "bottom")
    check("表示する場所を変える（自動で隠すは変えない）", moved.position == "right" && moved.autoHide == true)
    check("知らない場所は無視する", StripMenuSpec.apply(.place("top"), autoHide: false, position: "left").position == "left")
    check("追加は設定を変えない", StripMenuSpec.apply(.addWidget, autoHide: true, position: "left") == (true, "left"))
    // 設定画面と同じ値を書くので、保存される設定にそのまま反映される。
    let store = Store()
    let before = store.prefs.autoHide
    let next = StripMenuSpec.apply(.toggleAutoHide, autoHide: store.prefs.autoHide, position: store.prefs.position)
    store.prefs.autoHide = next.autoHide
    check("メニューの結果が Prefs に入る", store.prefs.autoHide == !before)
}

// 開いているグループは、帯の別の要素を押したら閉じる。同じ要素の中は閉じない。
do {
    let open = UUID()
    let other = UUID()
    check("ウィジェットを押したら閉じる", GroupDismissal.closesOnMouseDown(target: "widget:\(UUID().uuidString)", expanded: open))
    check("ボタン（履歴・設定）を押したら閉じる", GroupDismissal.closesOnMouseDown(target: "button:history", expanded: open))
    check("仕切り線を押したら閉じる", GroupDismissal.closesOnMouseDown(target: "sep:1", expanded: open))
    check("帯の空きを押したら閉じる", GroupDismissal.closesOnMouseDown(target: nil, expanded: open))
    check("開いているグループ自身のタイルでは閉じない（タイルが開閉する）",
          !GroupDismissal.closesOnMouseDown(target: "group:\(open.uuidString)", expanded: open))
    check("別のグループのタイルでは閉じない（そのタイルが切り替える）",
          !GroupDismissal.closesOnMouseDown(target: "group:\(other.uuidString)", expanded: open))
    check("帯のアプリは押した瞬間には閉じない（グループへドラッグして入れる起点）",
          !GroupDismissal.closesOnMouseDown(target: "app:/Applications/Safari.app", expanded: open))
    check("帯のアプリをドラッグせずに離したら閉じる", GroupDismissal.closesOnClick(target: "app:/Applications/Safari.app"))
    check("ウィジェットは離したときの判定の対象ではない", !GroupDismissal.closesOnClick(target: "widget:\(UUID().uuidString)"))
}

// クリップボード履歴：重複は 1 件、固定は消さない、上限で古いものから消す、機密は保存しない。
do {
    func text(_ s: String) -> ClipEntry { ClipboardParse.text(s)! }
    var list: [ClipEntry] = []
    list = ClipboardHistory.adding(text("a"), to: list)
    list = ClipboardHistory.adding(text("b"), to: list)
    check("新しいものが先頭", list.map(\.text) == ["b", "a"])
    list = ClipboardHistory.adding(text("a"), to: list)
    check("同じ内容は 1 件にまとめて先頭へ", list.map(\.text) == ["a", "b"])
    let pinnedID = list[1].id
    list = ClipboardHistory.togglingPin(pinnedID, in: list)
    check("固定を切り替えられる", list[1].pinned)
    var many = list
    for i in 0..<10 { many = ClipboardHistory.adding(text("x\(i)"), to: many, limit: 3) }
    check("上限を超えたら古いものから消える（固定以外は 3 件）", many.filter { !$0.pinned }.count == 3)
    check("固定は上限で消えない", many.contains { $0.id == pinnedID })
    check("固定は同じ内容を足し直しても保たれる",
          ClipboardHistory.adding(text("b"), to: many, limit: 3).first { $0.text == "b" }?.pinned == true)

    check("パスワード管理アプリの印があれば保存しない", !ClipboardPolicy.shouldRecord(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]))
    check("一時の印があれば保存しない", !ClipboardPolicy.shouldRecord(types: ["org.nspasteboard.TransientType"]))
    check("普通の内容は保存する", ClipboardPolicy.shouldRecord(types: ["public.utf8-plain-text"]))
    check("空白だけのテキストは保存しない", ClipboardParse.text("  \n ") == nil)
    check("長すぎるテキストは保存しない", ClipboardParse.text(String(repeating: "a", count: ClipboardPolicy.maxTextLength + 1)) == nil)
    check("大きすぎる画像は保存しない", ClipboardParse.image(Data(count: ClipboardPolicy.maxImageBytes + 1), name: "a.png") == nil)
    check("空の画像は保存しない", ClipboardParse.image(Data(), name: "a.png") == nil)

    let one = Data([1, 2, 3, 4]), two = Data([1, 2, 3, 5])
    check("同じ画像は同じ印", ClipboardParse.imageFingerprint(one) == ClipboardParse.imageFingerprint(Data([1, 2, 3, 4])))
    check("違う画像は違う印", ClipboardParse.imageFingerprint(one) != ClipboardParse.imageFingerprint(two))
    let imageA = ClipboardParse.image(one, name: "a.png")!
    let imageB = ClipboardParse.image(one, name: "b.png")!
    let merged = ClipboardHistory.adding(imageB, to: ClipboardHistory.adding(imageA, to: []))
    check("同じ画像は 1 件にまとまり、最初の画像ファイルを使う", merged.count == 1 && merged[0].imageName == "a.png")
    check("消えた画像のファイル名が分かる",
          ClipboardHistory.droppedImages(before: [imageA], after: []) == ["a.png"])
    check("残っている画像は消さない", ClipboardHistory.droppedImages(before: [imageA], after: [imageA]).isEmpty)

    let files = ClipboardParse.files(["/a/b/報告書.pdf", "/a/b/図.png", "/a/b/表.csv"])!
    check("ファイルの見出し（3 件）", files.title == "報告書.pdf、図.png ほか 1 件")
    check("テキストの見出しは 1 行目", text("1 行目\n2 行目").title == "1 行目")
    check("ファイルが空なら作らない", ClipboardParse.files([""]) == nil)

    // 保存と読み込み（保存先をテスト用の場所に、鍵を固定の鍵に変える。キーチェーンには触れない）
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("groupdock-clip-\(UUID().uuidString)")
    ClipboardStore.directoryOverride = dir
    let testKey = ClipboardCrypto.newMasterKey()
    let provider = FixedKeyProvider(key: testKey)
    let secret = "合言葉ではないが、読まれたくない内容 XYZ123"
    let thumbData = Data([9, 8, 7])
    let imageWithThumb = ClipboardParse.image(one, name: "a.gdc", thumbnail: thumbData)!
    let saved = ClipboardStore(keys: provider)
    saved.add(text(secret), imageData: nil)
    saved.add(imageWithThumb, imageData: one)
    let reloaded = ClipboardStore(keys: provider)
    check("履歴が保存されて読み直せる", reloaded.entries.count == 2 && reloaded.entries.contains { $0.text == secret })
    let indexBytes = (try? Data(contentsOf: ClipboardStore.indexURL)) ?? Data()
    check("索引は暗号化されている", ClipboardCrypto.isSealed(indexBytes))
    check("索引に本文が平文で残らない", indexBytes.range(of: Data("XYZ123".utf8)) == nil)
    check("索引に縮小画像が平文で残らない", indexBytes.range(of: Data(base64Encoded: "CQgH")!) == nil)
    let imageBytes = (try? Data(contentsOf: ClipboardStore.imageDirectory.appendingPathComponent("a.gdc"))) ?? Data()
    check("画像のファイルは暗号化されている", ClipboardCrypto.isSealed(imageBytes) && imageBytes != one)
    let imageEntry = reloaded.entries.first { $0.kind == .image }!
    check("一覧用の縮小画像が索引に入っている", imageEntry.thumbnail == thumbData)
    check("元の画像は復号して取り出せる", reloaded.originalImage(for: imageEntry) == one)
    let otherKeyStore = ClipboardStore(keys: FixedKeyProvider(key: ClipboardCrypto.newMasterKey()))
    check("鍵が違うと履歴は開けない（空になる）", otherKeyStore.entries.isEmpty)
    let noKeyStore = ClipboardStore(keys: FixedKeyProvider(key: nil))
    noKeyStore.add(text("鍵が無いと保存しない"), imageData: nil)
    check("鍵が取れないときは記録しない（平文で残さない）", noKeyStore.entries.isEmpty)
    let mode = (try? FileManager.default.attributesOfItem(atPath: ClipboardStore.indexURL.path))?[.posixPermissions] as? Int
    check("履歴ファイルは自分だけが読める", mode == 0o600)
    let dirMode = (try? FileManager.default.attributesOfItem(atPath: ClipboardStore.directory.path))?[.posixPermissions] as? Int
    check("保存フォルダは自分だけが入れる", dirMode == 0o700)
    reloaded.remove(imageEntry.id)
    check("履歴から消すと画像のファイルも消える",
          !FileManager.default.fileExists(atPath: ClipboardStore.imageDirectory.appendingPathComponent("a.gdc").path))
    check("件数の表示が履歴と同じ", ClipboardCount.current == reloaded.entries.count)
    reloaded.clear(keepPinned: false)
    check("すべて消せる", reloaded.entries.isEmpty)
    try? FileManager.default.removeItem(at: dir)

    // 平文だった旧い履歴は、開いたときに暗号化し直す（画像は縮小画像も作る）。
    let oldDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("groupdock-clip-old-\(UUID().uuidString)")
    ClipboardStore.directoryOverride = oldDir
    try? FileManager.default.createDirectory(at: ClipboardStore.imageDirectory, withIntermediateDirectories: true)
    let tiny = NSImage(size: NSSize(width: 200, height: 100), flipped: false) { rect in
        NSColor.systemTeal.setFill(); rect.fill(); return true
    }
    let tinyPNG = NSBitmapImageRep(data: tiny.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    try? tinyPNG.write(to: ClipboardStore.imageDirectory.appendingPathComponent("old.png"))
    let oldEntries = [ClipEntry(kind: .text, text: "旧い平文のメモ", fingerprint: "text:旧い平文のメモ"),
                      ClipEntry(kind: .image, imageName: "old.png", fingerprint: ClipboardParse.imageFingerprint(tinyPNG))]
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try? encoder.encode(oldEntries).write(to: ClipboardStore.indexURL)
    check("移行前の索引は平文", !ClipboardCrypto.isSealed((try? Data(contentsOf: ClipboardStore.indexURL)) ?? Data()))
    let migrated = ClipboardStore(keys: provider)
    check("旧い履歴が読める", migrated.entries.count == 2 && migrated.entries.contains { $0.text == "旧い平文のメモ" })
    let migratedIndex = (try? Data(contentsOf: ClipboardStore.indexURL)) ?? Data()
    check("移行したら索引が暗号化される", ClipboardCrypto.isSealed(migratedIndex))
    check("移行したら本文が平文で残らない", migratedIndex.range(of: Data("旧い平文のメモ".utf8)) == nil)
    let oldImage = migrated.entries.first { $0.kind == .image }!
    let migratedImage = (try? Data(contentsOf: ClipboardStore.imageDirectory.appendingPathComponent("old.png"))) ?? Data()
    check("移行したら画像のファイルも暗号化される", ClipboardCrypto.isSealed(migratedImage))
    check("移行したら縮小画像が作られる", oldImage.thumbnail != nil)
    check("移行しても元の画像を復号できる", migrated.originalImage(for: oldImage) == tinyPNG)
    try? FileManager.default.removeItem(at: oldDir)

    // 索引が開けないとき（鍵が違う・一時的に取れない）は、次の保存で既存の索引を上書きしない（履歴を失わない）。
    let guardDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("groupdock-clip-guard-\(UUID().uuidString)")
    ClipboardStore.directoryOverride = guardDir
    let keyA = ClipboardCrypto.newMasterKey()
    let original = ClipboardStore(keys: FixedKeyProvider(key: keyA))
    original.add(text("失ってはいけない履歴 1"), imageData: nil)
    original.add(text("失ってはいけない履歴 2"), imageData: nil)
    let before = (try? Data(contentsOf: ClipboardStore.indexURL)) ?? Data()
    let wrongKey = ClipboardStore(keys: FixedKeyProvider(key: ClipboardCrypto.newMasterKey()))
    check("鍵が違うと履歴は空に見える", wrongKey.entries.isEmpty)
    wrongKey.add(text("別の鍵で足した内容"), imageData: nil)
    wrongKey.togglePin(UUID())
    wrongKey.clear(keepPinned: false)
    let after = (try? Data(contentsOf: ClipboardStore.indexURL)) ?? Data()
    check("開けなかった索引は上書きされない", after == before)
    let back = ClipboardStore(keys: FixedKeyProvider(key: keyA))
    check("正しい鍵に戻れば、履歴がそのまま読める", back.entries.count == 2 && back.entries.contains { $0.text == "失ってはいけない履歴 1" })

    // 起動時に鍵が一時的に取れなかった場合：あとで鍵が取れても、履歴を読み直してから足す（上書きしない）。
    final class FlakyKey: ClipboardKeyProvider {
        var key: SymmetricKey?
        init(_ key: SymmetricKey?) { self.key = key }
        func masterKey() -> SymmetricKey? { key }
    }
    let flaky = FlakyKey(nil)
    let delayed = ClipboardStore(keys: flaky)
    check("鍵が取れないときは履歴を読めない", delayed.entries.isEmpty)
    flaky.key = keyA
    delayed.add(text("鍵が戻ってから足した内容"), imageData: nil)
    check("鍵が戻ったら、読み直した履歴に足される（既存の 2 件が消えない）",
          delayed.entries.count == 3 && delayed.entries.contains { $0.text == "失ってはいけない履歴 2" })
    let reopened = ClipboardStore(keys: FixedKeyProvider(key: keyA))
    check("保存し直した索引にも 3 件残っている", reopened.entries.count == 3)
    try? FileManager.default.removeItem(at: guardDir)

    // 画像の書き出し：暗号化された元画像を復号して PNG で書く。画像以外・読めない画像は書かない。
    let exportDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("groupdock-clip-export-\(UUID().uuidString)")
    ClipboardStore.directoryOverride = exportDir
    let exportKey = ClipboardCrypto.newMasterKey()
    let exporter = ClipboardStore(keys: FixedKeyProvider(key: exportKey))
    let exportPNG = NSBitmapImageRep(data: NSImage(size: NSSize(width: 120, height: 80), flipped: false) { rect in
        NSColor.systemPink.setFill(); rect.fill(); return true
    }.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    exporter.add(ClipboardParse.image(exportPNG, name: "export.gdc", thumbnail: ClipboardStore.thumbnail(of: exportPNG))!, imageData: exportPNG)
    exporter.add(text("画像ではない"), imageData: nil)
    let exportedImage = exporter.entries.first { $0.kind == .image }!
    let textEntry = exporter.entries.first { $0.kind == .text }!
    let outURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("groupdock-out-\(UUID().uuidString).png")
    check("暗号化された画像を、元の PNG として書き出せる", exporter.exportImage(exportedImage, to: outURL))
    check("書き出したファイルは元の画像と同じ", (try? Data(contentsOf: outURL)) == exportPNG)
    check("書き出したファイルは暗号化されていない（普通の PNG）",
          !ClipboardCrypto.isSealed((try? Data(contentsOf: outURL)) ?? Data()) && NSImage(contentsOf: outURL) != nil)
    let stored = (try? Data(contentsOf: ClipboardStore.imageDirectory.appendingPathComponent("export.gdc"))) ?? Data()
    check("履歴の中の画像は暗号化されたまま", ClipboardCrypto.isSealed(stored) && stored != exportPNG)
    let textOut = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("groupdock-out-\(UUID().uuidString).txt")
    check("画像以外は書き出さない", !exporter.exportImage(textEntry, to: textOut)
          && !FileManager.default.fileExists(atPath: textOut.path))
    let wrongExporter = ClipboardStore(keys: FixedKeyProvider(key: ClipboardCrypto.newMasterKey()))
    let wrongOut = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("groupdock-out-\(UUID().uuidString).png")
    check("鍵が違えば書き出せない（ファイルも作らない）", !wrongExporter.exportImage(exportedImage, to: wrongOut)
          && !FileManager.default.fileExists(atPath: wrongOut.path))
    let unwritable = URL(fileURLWithPath: "/nonexistent-dir-\(UUID().uuidString)/x.png")
    check("書き込めない場所では false を返す", !exporter.exportImage(exportedImage, to: unwritable))
    try? FileManager.default.removeItem(at: outURL)
    try? FileManager.default.removeItem(at: exportDir)

    // 書き出すときのファイル名：使えない文字を含まず、PNG の名前になる。
    let stamp = Date(timeIntervalSince1970: 1_700_000_000)
    let name = ClipboardExport.suggestedName(date: stamp, timeZone: TimeZone(identifier: "Asia/Tokyo")!)
    check("書き出しの名前は日時つきの PNG", name == "クリップボード 2023-11-15 07.13.20.png")
    check("書き出しの名前に : と / が入らない", !name.contains(":") && !name.contains("/"))
    // 縮小画像の大きさ（長辺 64px、縦横比を保つ、小さい画像は拡大しない）
    let wide = ClipboardThumbnail.size(for: CGSize(width: 1920, height: 1080))
    check("縮小画像は長辺が 64px", wide.width == 64 && wide.height == 36)
    let tall = ClipboardThumbnail.size(for: CGSize(width: 500, height: 1000))
    check("縦長も縦横比を保つ", tall.height == 64 && tall.width == 32)
    check("小さい画像は拡大しない", ClipboardThumbnail.size(for: CGSize(width: 20, height: 10)) == CGSize(width: 20, height: 10))
    check("大きさが 0 なら 0", ClipboardThumbnail.size(for: .zero) == .zero)
    // 細かい模様のある画像（一色だと PNG がどちらも極小になり、大きさを比べられない）。
    let busy = NSImage(size: NSSize(width: 800, height: 600), flipped: false) { rect in
        for y in stride(from: 0, to: 600, by: 6) {
            for x in stride(from: 0, to: 800, by: 6) {
                NSColor(calibratedHue: CGFloat((x * 7 + y * 13) % 100) / 100, saturation: 0.8, brightness: 0.9, alpha: 1).setFill()
                NSRect(x: x, y: y, width: 6, height: 6).fill()
            }
        }
        return true
    }
    let busyPNG = NSBitmapImageRep(data: busy.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    let thumbPNG = ClipboardStore.thumbnail(of: busyPNG)
    check("縮小画像を作れる", thumbPNG != nil && (thumbPNG.flatMap { NSImage(data: $0) }?.size.width ?? 999) <= 64)
    check("縮小画像は元画像より小さい（半分未満）", (thumbPNG?.count ?? Int.max) * 2 < busyPNG.count)

    ClipboardStore.directoryOverride = nil
    ClipboardCount.current = 0

    let widgetStore = Store()
    widgetStore.prefs.widgets = [Widget(kind: .clock)]
    check("クリップボードのウィジェットが無ければ監視しない（履歴も作らない＝キーチェーンに触れない）", !widgetStore.clipboardIsRunning)
}

// クリップボード履歴の暗号化：件ごとに別の鍵、改ざん・違う鍵では開けない。
do {
    let master = ClipboardCrypto.newMasterKey()
    let plain = Data("パスワードではない、ただのメモ".utf8)
    let sealed = try! ClipboardCrypto.seal(plain, master: master)
    check("暗号化した印が付く", ClipboardCrypto.isSealed(sealed))
    check("平文は暗号化した印が付かない", !ClipboardCrypto.isSealed(plain))
    check("暗号文に元の文字が含まれない", sealed.range(of: Data("メモ".utf8)) == nil)
    check("鍵が同じなら元に戻る", (try? ClipboardCrypto.open(sealed, master: master)) == plain)
    let again = try! ClipboardCrypto.seal(plain, master: master)
    check("同じ内容でも暗号文は毎回変わる（件ごとにソルトが違う）", sealed != again)
    check("どちらも元に戻る", (try? ClipboardCrypto.open(again, master: master)) == plain)
    check("鍵が違えば開けない", (try? ClipboardCrypto.open(sealed, master: ClipboardCrypto.newMasterKey())) == nil)
    var tampered = sealed
    tampered[tampered.count - 1] ^= 0xFF
    check("改ざんされたら開けない", (try? ClipboardCrypto.open(tampered, master: master)) == nil)
    check("途中で切れていたら開けない", (try? ClipboardCrypto.open(sealed.prefix(10), master: master)) == nil)
    check("平文を開こうとすると失敗する", (try? ClipboardCrypto.open(plain, master: master)) == nil)
    let salt = Data(repeating: 7, count: ClipboardCrypto.saltLength)
    let keyA = ClipboardCrypto.itemKey(master: master, salt: salt)
    let keyB = ClipboardCrypto.itemKey(master: master, salt: Data(repeating: 8, count: ClipboardCrypto.saltLength))
    check("ソルトが違えば導かれる鍵も違う",
          keyA.withUnsafeBytes { Data($0) } != keyB.withUnsafeBytes { Data($0) })
    check("同じソルトなら同じ鍵", keyA.withUnsafeBytes { Data($0) }
          == ClipboardCrypto.itemKey(master: master, salt: salt).withUnsafeBytes { Data($0) })
    check("鍵の供給は差し替えられる", FixedKeyProvider(key: master).masterKey() != nil && FixedKeyProvider(key: nil).masterKey() == nil)
}

// システムの再生にブラウザの音量を付ける：再生中で題名が一致するものだけ。書き込み先は音量を読んだブラウザ。
do {
    let system = PlaybackInfo(source: .system, title: "曲 A", artist: "x", playing: true, volume: nil, artwork: nil)
    func browser(_ source: PlaybackSource, title: String, playing: Bool = true, volume: Int? = 40) -> PlaybackInfo {
        PlaybackInfo(source: source, title: title, artist: "", playing: playing, volume: volume, artwork: nil,
                     capabilities: PlaybackCapabilities(volume: volume != nil))
    }
    let merged = NowPlayingParse.merging(browsers: [browser(.chrome, title: "曲 A - YouTube")], into: system)
    check("再生中で題名が一致すれば、ブラウザの音量が付く", merged.volume == 40 && merged.capabilities.volume)
    check("音量を読んだブラウザを覚える", merged.volumeBrowser == .chrome)
    check("操作の元はシステムのまま", merged.source == .system && merged.title == "曲 A")
    check("止まっているタブの音量は付けない",
          NowPlayingParse.merging(browsers: [browser(.chrome, title: "曲 A", playing: false)], into: system) == system)
    check("題名が違うタブの音量は付けない（別の曲のタブの音量を出さない）",
          NowPlayingParse.merging(browsers: [browser(.chrome, title: "別の動画")], into: system) == system)
    check("音量が読めないタブは付けない",
          NowPlayingParse.merging(browsers: [browser(.safari, title: "曲 A", volume: nil)], into: system) == system)
    check("題名が空なら一致とみなさない",
          NowPlayingParse.merging(browsers: [browser(.chrome, title: "")],
                                  into: PlaybackInfo(source: .system, title: "", artist: "", playing: true, volume: nil, artwork: nil))
          .volume == nil)
    let music = PlaybackInfo(source: .music, title: "曲 A", artist: "", playing: true, volume: 70, artwork: nil)
    check("システム以外の再生には何も付けない",
          NowPlayingParse.merging(browsers: [browser(.chrome, title: "曲 A")], into: music) == music)
    let twoTabs = NowPlayingParse.merging(
        browsers: [browser(.chrome, title: "別の動画"), browser(.safari, title: "曲 A", volume: 25)], into: system)
    check("複数のブラウザから、一致したものを選ぶ", twoTabs.volume == 25 && twoTabs.volumeBrowser == .safari)

    check("システムの音量は、音量を読んだブラウザへ書く", NowPlayingParse.volumeTarget(for: merged) == .chrome)
    check("ブラウザの音量が無いシステムの再生は、書き込み先が無い", NowPlayingParse.volumeTarget(for: system) == nil)
    check("ミュージックの音量は、ミュージックへ書く", NowPlayingParse.volumeTarget(for: music) == .music)
}

// 音声デバイス：固定は UID を覚え、消えても指す先は変えない（使えなくなるだけ）。
do {
    let speaker = AudioDeviceInfo(id: 1, uid: "BuiltInSpeaker", name: "MacBook のスピーカー")
    let headset = AudioDeviceInfo(id: 2, uid: "AA-BB-CC", name: "AirPods")
    let monitor = AudioDeviceInfo(id: 3, uid: "HDMI-1", name: "ディスプレイのスピーカー", hasVolume: false)
    let all = [speaker, headset, monitor]

    check("固定しなければ、既定のデバイスに従う",
          AudioDevices.resolve(.followDefault, devices: all, defaultUID: "AA-BB-CC") == .device(headset))
    check("既定が切り替わったら、従うデバイスも変わる",
          AudioDevices.resolve(.followDefault, devices: all, defaultUID: "BuiltInSpeaker") == .device(speaker))
    check("デバイスが無ければ「デバイスなし」", AudioDevices.resolve(.followDefault, devices: [], defaultUID: nil) == .noDevice)
    check("既定が一覧に無ければ「デバイスなし」",
          AudioDevices.resolve(.followDefault, devices: all, defaultUID: "unknown") == .noDevice)

    let pinned = AudioTarget.pinned(uid: "AA-BB-CC", name: "AirPods")
    check("固定したデバイスは、既定が別でもそれを指す",
          AudioDevices.resolve(pinned, devices: all, defaultUID: "BuiltInSpeaker") == .device(headset))
    check("固定したデバイスが消えたら「使えない」。指す先は変わらない",
          AudioDevices.resolve(pinned, devices: [speaker, monitor], defaultUID: "BuiltInSpeaker")
          == .unavailable(uid: "AA-BB-CC", name: "AirPods"))
    check("消えても、既定のデバイスを代わりにしない",
          AudioDevices.resolve(pinned, devices: [speaker], defaultUID: "BuiltInSpeaker") != .device(speaker))
    check("つなぎ直したら、同じ UID のまま使える（番号が変わっていても）",
          AudioDevices.resolve(pinned, devices: [speaker, AudioDeviceInfo(id: 99, uid: "AA-BB-CC", name: "AirPods")],
                               defaultUID: "BuiltInSpeaker")
          == .device(AudioDeviceInfo(id: 99, uid: "AA-BB-CC", name: "AirPods")))
    check("名前が変わっても UID で見つける",
          AudioDevices.resolve(pinned, devices: [AudioDeviceInfo(id: 5, uid: "AA-BB-CC", name: "AirPods Pro")],
                               defaultUID: nil) == .device(AudioDeviceInfo(id: 5, uid: "AA-BB-CC", name: "AirPods Pro")))

    check("いま使えるデバイスを固定できる",
          AudioDevices.pin(.device(headset)) == .pinned(uid: "AA-BB-CC", name: "AirPods"))
    check("使えないデバイスは新しく固定できない",
          AudioDevices.pin(.unavailable(uid: "x", name: "y")) == nil && AudioDevices.pin(.noDevice) == nil)

    check("保存した UID から、固定を組み立てられる",
          AudioDevices.target(pinnedUID: "AA-BB-CC", pinnedName: "AirPods") == pinned)
    check("UID が空なら固定なし", AudioDevices.target(pinnedUID: "", pinnedName: "x") == .followDefault)
    check("UID が無ければ固定なし", AudioDevices.target(pinnedUID: nil, pinnedName: nil) == .followDefault)
    check("名前が無くても UID は残る（指す先は変わらない）",
          AudioDevices.target(pinnedUID: "AA-BB-CC", pinnedName: nil) == .pinned(uid: "AA-BB-CC", name: "AA-BB-CC"))

    check("使えないときの表示は、名前を変えずに「接続されていません」を足す",
          AudioDevices.label(for: .unavailable(uid: "AA-BB-CC", name: "AirPods")) == "AirPods（接続されていません）")
    check("使えるときの表示は名前そのまま", AudioDevices.label(for: .device(headset)) == "AirPods")

    let list = AudioDevices.choices(devices: [speaker, headset], target: pinned)
    check("切り替え先は名前順", list.map(\.name) == ["AirPods", "MacBook のスピーカー"])
    let missing = AudioDevices.choices(devices: [speaker], target: pinned)
    check("固定した消えたデバイスも、使えない項目として残る（指す先が見える）",
          missing.last?.uid == "AA-BB-CC" && missing.last?.available == false && missing.first?.available == true)
    check("固定していなければ、消えたデバイスの項目は出ない",
          AudioDevices.choices(devices: [speaker], target: .followDefault).count == 1)

    // 切り替え：固定していなければ既定を切り替え、固定していれば固定先を付け替える。使えない項目は選べない。
    let toSpeaker = AudioDevices.select(uid: "BuiltInSpeaker", name: "MacBook のスピーカー", available: true, target: .followDefault)
    check("固定なしで選ぶと、システムの既定を切り替える（固定はしない）",
          toSpeaker?.target == .followDefault && toSpeaker?.setDefaultUID == "BuiltInSpeaker")
    let repin = AudioDevices.select(uid: "BuiltInSpeaker", name: "MacBook のスピーカー", available: true, target: pinned)
    check("固定中に選ぶと、固定先を付け替え、システムの既定もそのデバイスへ切り替える（固定は既定まで固定する）",
          repin?.target == .pinned(uid: "BuiltInSpeaker", name: "MacBook のスピーカー") && repin?.setDefaultUID == "BuiltInSpeaker")

    // 固定は、システムの既定まで固定する：macOS が既定を勝手に切り替えたら（AirPods の接続など）、固定先へ戻す。
    let builtinMic = AudioDeviceInfo(id: 10, uid: "BuiltInMicrophoneDevice", name: "MacBook Proのマイク")
    let pods = AudioDeviceInfo(id: 11, uid: "AA-BB:input", name: "AirPods")
    let pinMic = AudioTarget.pinned(uid: "BuiltInMicrophoneDevice", name: "MacBook Proのマイク")
    check("固定先が既定でなければ、固定先へ戻す",
          AudioPinning.desiredDefault(targets: [pinMic], devices: [builtinMic, pods], defaultUID: "AA-BB:input") == "BuiltInMicrophoneDevice")
    check("固定先がすでに既定なら、何もしない（戻す処理が繰り返されない）",
          AudioPinning.desiredDefault(targets: [pinMic], devices: [builtinMic, pods], defaultUID: "BuiltInMicrophoneDevice") == nil)
    check("固定していなければ、既定は触らない",
          AudioPinning.desiredDefault(targets: [.followDefault], devices: [builtinMic, pods], defaultUID: "AA-BB:input") == nil)
    check("固定先が接続されていなければ、別のデバイスを既定にしない（使えないだけ）",
          AudioPinning.desiredDefault(targets: [pinMic], devices: [pods], defaultUID: "AA-BB:input") == nil)
    check("つなぎ直したら、固定先へ戻す",
          AudioPinning.desiredDefault(targets: [pinMic], devices: [pods, builtinMic], defaultUID: "AA-BB:input") == "BuiltInMicrophoneDevice")
    let pinPods = AudioTarget.pinned(uid: "AA-BB:input", name: "AirPods")
    check("固定が複数あれば最初のものに従う（互いに戻し合って止まらなくならない）",
          AudioPinning.desiredDefault(targets: [.followDefault, pinMic, pinPods], devices: [builtinMic, pods], defaultUID: "AA-BB:input")
          == "BuiltInMicrophoneDevice")
    check("固定が無ければ何もしない", AudioPinning.desiredDefault(targets: [], devices: [builtinMic], defaultUID: nil) == nil)

    // 向きが混在：出力はスピーカー固定、入力はマイク固定。入力の判定で、出力の固定に引きずられない。
    let builtinSpeaker = AudioTarget.pinned(uid: "BuiltInSpeakerDevice", name: "MacBook Proのスピーカー")
    let mixed: [(direction: AudioDirection, target: AudioTarget)] = [(.output, builtinSpeaker), (.input, pinMic)]
    check("入力の判定は、入力の固定（マイク）を見る",
          AudioPinning.desiredDefault(pins: mixed, direction: .input, devices: [builtinMic, pods], defaultUID: "AA-BB:input")
          == "BuiltInMicrophoneDevice")
    let speakerInfo = AudioDeviceInfo(id: 20, uid: "BuiltInSpeakerDevice", name: "MacBook Proのスピーカー")
    check("出力の判定は、出力の固定（スピーカー）を見る",
          AudioPinning.desiredDefault(pins: mixed, direction: .output, devices: [speakerInfo], defaultUID: "AirPods:output")
          == "BuiltInSpeakerDevice")
    check("入力に固定が無ければ、出力の固定があっても入力は触らない",
          AudioPinning.desiredDefault(pins: [(.output, builtinSpeaker)], direction: .input,
                                      devices: [builtinMic, pods], defaultUID: "AA-BB:input") == nil)
    check("使えない項目は選べない",
          AudioDevices.select(uid: "AA-BB-CC", name: "AirPods", available: false, target: pinned) == nil)

    // 固定の入り切り
    check("固定していなければ、いま使えるデバイスに固定する",
          AudioDevices.togglingPin(resolution: .device(headset), target: .followDefault) == pinned)
    check("固定中なら外す", AudioDevices.togglingPin(resolution: .device(headset), target: pinned) == .followDefault)
    check("使えるデバイスが無ければ固定しない",
          AudioDevices.togglingPin(resolution: .noDevice, target: .followDefault) == .followDefault)
    check("固定中で消えていても外せる（外すまで指す先は変わらない）",
          AudioDevices.togglingPin(resolution: .unavailable(uid: "AA-BB-CC", name: "AirPods"), target: pinned) == .followDefault)

    // 表示の整形
    let shown = AudioDisplay.reading(resolution: .device(headset), volume: 40, muted: false, direction: .output)
    check("音量の表示", shown.big == "40%" && shown.fraction == 0.4 && shown.detail == "AirPods：出力音量 40%")
    let mic = AudioDisplay.reading(resolution: .device(headset), volume: 70, muted: false, direction: .input)
    check("マイクは入力音量と書く", mic.detail == "AirPods：入力音量 70%")
    let muted = AudioDisplay.reading(resolution: .device(headset), volume: 40, muted: true, direction: .output)
    check("ミュート中は消音と出す", muted.big == "消音" && muted.fraction == 0 && muted.detail.contains("ミュート中"))
    let gone = AudioDisplay.reading(resolution: .unavailable(uid: "AA-BB-CC", name: "AirPods"), volume: nil, muted: nil, direction: .output)
    check("固定した機器が無いときは、名前を残して使えない表示", gone.big == "—" && gone.detail == "AirPods（接続されていません）" && gone.fraction == nil)
    let fixed = AudioDisplay.reading(resolution: .device(monitor), volume: nil, muted: nil, direction: .output)
    check("音量を持たないデバイスの表示", fixed.big == "—" && fixed.detail.contains("変えられない"))

    // ウィジェットへの保存：UID を残し、消えても変えない
    var widget = Widget(kind: .volume)
    check("新しい音量ウィジェットは固定なし", widget.audioTarget == .followDefault && widget.audioDirection == .output)
    widget.setAudioTarget(pinned)
    let stored = (try? JSONEncoder().encode(widget)).flatMap { try? JSONDecoder().decode(Widget.self, from: $0) }
    check("固定した UID と名前が保存される", stored?.audioTarget == pinned)
    check("固定が消えたあとも、保存した指す先は同じ",
          AudioDevices.resolve(stored!.audioTarget, devices: [speaker], defaultUID: "BuiltInSpeaker")
          == .unavailable(uid: "AA-BB-CC", name: "AirPods") && stored?.pinnedDeviceUID == "AA-BB-CC")
    widget.setAudioTarget(.followDefault)
    check("固定を外すと UID が消える", widget.pinnedDeviceUID == nil && widget.pinnedDeviceName == nil)
    check("古い設定（固定の項目なし）でも読める",
          (try? JSONDecoder().decode(Widget.self, from: #"{"kind":"volume"}"#.data(using: .utf8)!))?.audioTarget == .followDefault)
    check("マイクのウィジェットは入力を向く", Widget(kind: .microphone).audioDirection == .input)
    check("マイクは数値のウィジェット", WidgetKind.microphone.isNumeric && WidgetKind.microphone.availableFaces.contains(.ring))
}

// つないでいないデバイス（AirPods など）も、固定の候補に出す：見た機器を覚える + ペアリング済み。
do {
    let pods = AudioDeviceInfo(id: 1, uid: "AA-BB-CC-DD-EE-FF:input", name: "AirPods")
    let builtin = AudioDeviceInfo(id: 2, uid: "BuiltInMicrophoneDevice", name: "MacBook Proのマイク")

    // 覚える：見た機器を足し、名前が変わっていれば更新する。いま無い機器は消さない。
    var known = AudioKnown.remembering(known: [], devices: [pods, builtin], direction: .input)
    check("見た機器を覚える", known.map(\.uid).sorted() == ["AA-BB-CC-DD-EE-FF:input", "BuiltInMicrophoneDevice"])
    check("覚えた機器に向きが付く", known.allSatisfy { $0.direction == .input })
    known = AudioKnown.remembering(known: known, devices: [builtin], direction: .input)
    check("いま無くなった機器も、覚えたまま消さない", known.contains { $0.uid == "AA-BB-CC-DD-EE-FF:input" })
    let renamed = AudioDeviceInfo(id: 9, uid: "AA-BB-CC-DD-EE-FF:input", name: "ご主人様の AirPods")
    known = AudioKnown.remembering(known: known, devices: [renamed], direction: .input)
    check("名前が変わったら更新する（重複させない）",
          known.filter { $0.uid == "AA-BB-CC-DD-EE-FF:input" }.count == 1
          && known.first { $0.uid == "AA-BB-CC-DD-EE-FF:input" }?.name == "ご主人様の AirPods")
    let outKnown = AudioKnown.remembering(
        known: known, devices: [AudioDeviceInfo(id: 5, uid: "BuiltInSpeakerDevice", name: "スピーカー")], direction: .output)
    check("出力と入力は別々に覚える", outKnown.filter { $0.direction == .output }.count == 1 && outKnown.filter { $0.direction == .input }.count == 2)

    // ペアリング済みの機器の UID：CoreAudio の UID は「アドレス:向き」。
    check("ペアリング済みの機器から、向きごとの UID を作る",
          AudioKnown.bluetoothUID(address: "aa-bb-cc-dd-ee-ff", direction: .input) == "AA-BB-CC-DD-EE-FF:input"
          && AudioKnown.bluetoothUID(address: "aa-bb-cc-dd-ee-ff", direction: .output) == "AA-BB-CC-DD-EE-FF:output")
    check("コロン区切りのアドレスも、ダッシュ区切りに直す",
          AudioKnown.bluetoothUID(address: "aa:bb:cc:dd:ee:ff", direction: .input) == "AA-BB-CC-DD-EE-FF:input")

    // 候補：覚えた機器 + ペアリング済みのうち、いま無いものだけ。同じ機器は 1 つにまとめる。
    let extra = AudioKnown.candidates(
        known: [KnownAudioDevice(uid: "AA-BB-CC-DD-EE-FF:input", name: "AirPods", direction: .input),
                KnownAudioDevice(uid: "XX:output", name: "別の出力", direction: .output)],
        paired: [(address: "aa-bb-cc-dd-ee-ff", name: "AirPods"), (address: "11-22-33-44-55-66", name: "ヘッドセット")],
        devices: [builtin], direction: .input)
    check("いま無い機器が候補に出る（覚えた + ペアリング済み、同じ機器は 1 つ）",
          extra.map(\.uid).sorted() == ["11-22-33-44-55-66:input", "AA-BB-CC-DD-EE-FF:input"])
    check("向きが違う機器は候補に出ない", !extra.contains { $0.uid == "XX:output" })
    let connectedExtra = AudioKnown.candidates(
        known: [], paired: [(address: "aa-bb-cc-dd-ee-ff", name: "AirPods")], devices: [pods], direction: .input)
    check("いま接続中の機器は、候補に重ねて出さない", connectedExtra.isEmpty)
    check("名前が無い機器は、アドレスを名前にする",
          AudioKnown.candidates(known: [], paired: [(address: "11-22-33-44-55-66", name: "")], devices: [], direction: .input)
              .first?.name == "11-22-33-44-55-66")

    // 切り替え先の並びに、使えない候補として加わる。固定中の機器は、重ねて出さない。
    let pairedOnly = [KnownAudioDevice(uid: "AA-BB-CC-DD-EE-FF:input", name: "AirPods", direction: .input)]
    let withExtra = AudioDevices.choices(devices: [builtin], target: .followDefault, extra: pairedOnly)
    check("いま無い機器は、使えない項目として並ぶ",
          withExtra.map(\.uid) == ["BuiltInMicrophoneDevice", "AA-BB-CC-DD-EE-FF:input"] && withExtra.last?.available == false)
    let pinnedPods = AudioTarget.pinned(uid: "AA-BB-CC-DD-EE-FF:input", name: "AirPods")
    check("固定中の機器が候補にもあるときは、1 つだけ出す",
          AudioDevices.choices(devices: [builtin], target: pinnedPods, extra: pairedOnly)
              .filter { $0.uid == "AA-BB-CC-DD-EE-FF:input" }.count == 1)
    check("候補が無ければ、これまでと同じ並び",
          AudioDevices.choices(devices: [builtin], target: .followDefault, extra: []).count == 1)

    // 候補を指して固定できる：つないでいなくても、指す先（UID）を決める。つないだら、固定先へ既定を戻す（AudioPinning）。
    check("使えない候補は、そのまま選んで切り替えることはできない",
          AudioDevices.select(uid: "AA-BB-CC-DD-EE-FF:input", name: "AirPods", available: false, target: .followDefault) == nil)
    check("候補を指して固定できる",
          AudioDevices.pinCandidate(uid: "AA-BB-CC-DD-EE-FF:input", name: "AirPods")
          == .pinned(uid: "AA-BB-CC-DD-EE-FF:input", name: "AirPods"))
    // CoreAudio の UID の表記ゆれ（大文字小文字）は、同じ機器とみなす。
    check("UID の大文字小文字が違っても、同じ機器を見つける",
          AudioDevices.resolve(.pinned(uid: "aa-bb-cc-dd-ee-ff:input", name: "AirPods"), devices: [pods], defaultUID: nil) == .device(pods))
    check("既定の UID の大文字小文字が違っても、固定先が既定なら戻さない",
          AudioPinning.desiredDefault(targets: [.pinned(uid: "aa-bb-cc-dd-ee-ff:input", name: "AirPods")],
                                      devices: [pods], defaultUID: "AA-BB-CC-DD-EE-FF:INPUT") == nil)
    // 修正前は失敗するケース：固定先は小文字、接続中の機器は大文字、既定は別の機器。機器の側の UID を返して、固定先へ戻す。
    let otherMic = AudioDeviceInfo(id: 30, uid: "BuiltInMicrophoneDevice", name: "MacBook Proのマイク")
    check("固定先の表記が小文字でも、接続中の機器を見つけて、その機器の UID へ戻す",
          AudioPinning.desiredDefault(targets: [.pinned(uid: "aa-bb-cc-dd-ee-ff:input", name: "AirPods")],
                                      devices: [pods, otherMic], defaultUID: "BuiltInMicrophoneDevice")
          == "AA-BB-CC-DD-EE-FF:input")
    check("固定先の表記が違っても、機器が接続されていなければ戻さない（別の機器を既定にしない）",
          AudioPinning.desiredDefault(targets: [.pinned(uid: "aa-bb-cc-dd-ee-ff:input", name: "AirPods")],
                                      devices: [otherMic], defaultUID: "BuiltInMicrophoneDevice") == nil)
    check("固定先が小文字で、機器が大文字のまま既定なら、戻さない（機器が存在する場合）",
          AudioPinning.desiredDefault(targets: [.pinned(uid: "aa-bb-cc-dd-ee-ff:input", name: "AirPods")],
                                      devices: [pods, otherMic], defaultUID: "aa-bb-cc-dd-ee-ff:input") == nil)
}

// ディスプレイの明るさ：対象の選び方と表示。固定したディスプレイが消えても、指す先は変えない。
do {
    let main = AudioDeviceInfo(id: 2, uid: "DISPLAY-MAIN", name: "メインのディスプレイ")
    let sub = AudioDeviceInfo(id: 3, uid: "DISPLAY-SUB", name: "サブのディスプレイ")
    let fixedDisplay = AudioDeviceInfo(id: 4, uid: "DISPLAY-NOBRIGHT", name: "明るさを変えられないディスプレイ", hasVolume: false)
    let all = [main, sub, fixedDisplay]

    check("固定しなければ、メインのディスプレイを対象にする",
          AudioDevices.resolve(.followDefault, devices: all, defaultUID: "DISPLAY-MAIN") == .device(main))
    let pinnedSub = AudioTarget.pinned(uid: "DISPLAY-SUB", name: "サブのディスプレイ")
    check("固定したディスプレイは、メインが別でもそれを指す",
          AudioDevices.resolve(pinnedSub, devices: all, defaultUID: "DISPLAY-MAIN") == .device(sub))
    check("固定したディスプレイを外したら、使えない。指す先は変わらない",
          AudioDevices.resolve(pinnedSub, devices: [main], defaultUID: "DISPLAY-MAIN")
          == .unavailable(uid: "DISPLAY-SUB", name: "サブのディスプレイ"))
    check("外しても、メインを代わりにしない",
          AudioDevices.resolve(pinnedSub, devices: [main], defaultUID: "DISPLAY-MAIN") != .device(main))
    check("つなぎ直したら、同じ UID で使える（番号が変わっていても）",
          AudioDevices.resolve(pinnedSub, devices: [AudioDeviceInfo(id: 77, uid: "DISPLAY-SUB", name: "サブのディスプレイ")],
                               defaultUID: nil) == .device(AudioDeviceInfo(id: 77, uid: "DISPLAY-SUB", name: "サブのディスプレイ")))

    check("ディスプレイを選ぶと、そのディスプレイに固定する（既定を切り替える手段が無い）",
          DisplayChoice.select(uid: "DISPLAY-SUB", name: "サブのディスプレイ", available: true) == pinnedSub)
    check("使えない項目は選べない",
          DisplayChoice.select(uid: "DISPLAY-SUB", name: "サブのディスプレイ", available: false) == nil)

    let shown = DisplayChoice.reading(resolution: .device(sub), brightness: 40)
    check("明るさの表示", shown.big == "40%" && shown.fraction == 0.4 && shown.detail == "サブのディスプレイ：明るさ 40%")
    let noBright = DisplayChoice.reading(resolution: .device(fixedDisplay), brightness: nil)
    check("明るさを変えられないディスプレイの表示", noBright.big == "—" && noBright.detail.contains("変えられない"))
    let gone = DisplayChoice.reading(resolution: .unavailable(uid: "DISPLAY-SUB", name: "サブのディスプレイ"), brightness: nil)
    check("固定したディスプレイが無いときは、名前を残して使えない表示",
          gone.big == "—" && gone.detail == "サブのディスプレイ（接続されていません）" && gone.fraction == nil)
    check("ディスプレイが無いときの表示", DisplayChoice.reading(resolution: .noDevice, brightness: nil).detail == "ディスプレイがありません")
    check("この macOS で扱えないときの表示",
          DisplayChoice.reading(resolution: .device(main), brightness: nil, isAvailable: false).detail.contains("扱えません"))

    var widget = Widget(kind: .brightness)
    check("新しい輝度ウィジェットは固定なし", widget.audioTarget == .followDefault)
    widget.setAudioTarget(pinnedSub)
    let stored = (try? JSONEncoder().encode(widget)).flatMap { try? JSONDecoder().decode(Widget.self, from: $0) }
    check("固定したディスプレイの UID が保存される", stored?.audioTarget == pinnedSub)
    check("輝度は数値のウィジェット", WidgetKind.brightness.isNumeric && WidgetKind.brightness.availableFaces.contains(.ring))
    check("輝度の見本の値は読み込みなしで決まる（落ちない）", { _ = DisplayHardware.isAvailable; return true }())
}

// 帯の自動縮小：要素が多くて画面に収まらないとき、標準 Dock のようにアイコンを縮める（設定の値は変えない）。
do {
    // 長さ = 要素 12 個 × (アイコン + 余白 6)。アイコンが大きいほど長い（単調）。
    let length: (CGFloat) -> CGFloat = { icon in 12 * (icon + 6) }
    check("収まるなら、設定の大きさのまま", StripFit.iconSize(requested: 50, available: 800, length: length) == 50)
    let fitted = StripFit.iconSize(requested: 80, available: 600, length: length)
    check("収まらなければ縮める", fitted < 80)
    check("縮めた結果は画面に収まる", length(fitted) <= 600)
    check("収まる中で一番大きい（1 つ大きいと収まらない）", length(fitted + 1) > 600)
    check("画面が極端に狭くても、下限より小さくしない",
          StripFit.iconSize(requested: 80, available: 10, length: length) == StripFit.minimumIcon)
    check("設定が下限より小さければ、設定のまま（拡大も縮小もしない）",
          StripFit.iconSize(requested: 12, available: 10, length: length) == 12)
    check("ちょうど収まる大きさは縮めない", StripFit.iconSize(requested: 44, available: 12 * 50, length: length) == 44)
    // フリーズの再現：つまみのドラッグで変えた小数の大きさ（80.5 など）でも、探索が終わる。
    let fractional = StripFit.iconSize(requested: 80.5, available: 600, length: length)
    check("小数の大きさでも探索が終わり、画面に収まる", length(fractional) <= 600 && fractional < 80.5)
    check("小数の大きさでも、収まる中で一番大きい（整数）", length(fractional + 1) > 600 && fractional == fractional.rounded())
    check("小数でも、収まるなら設定のまま", StripFit.iconSize(requested: 44.5, available: 800, length: length) == 44.5)
    check("下限ちょうどの小数（24.5）でも終わる", StripFit.iconSize(requested: 24.5, available: 12 * 30, length: length) == 24)
    // フリーズの本命：下限の近くで、整数は収まるが小数の設定は収まらない（25 は収まり 25.5 は収まらない）。
    check("下限の近くの小数でも探索が終わる（無限ループしない）",
          StripFit.iconSize(requested: 25.5, available: 375, length: length) == 25)

    // 実際の帯の計算に通っているか：要素が多くて画面に収まらないときは、縮んだ大きさで並ぶ（設定の値は変えない）。
    let fitStore = Store()
    fitStore.prefs.overflow = "shrink"      // 縮める方式を確かめる（既定はページ切り替え）
    fitStore.prefs.position = "left"
    fitStore.prefs.iconSize = 80
    fitStore.prefs.widgets = []
    fitStore.groups = (0..<20).map { Group(name: "グループ \($0)") }
    let available = fitStore.stripAvailableLength()
    check("縮める前は、帯が画面より長い（このテストの前提）",
          available < 1_000_000 && StripLayout.make(fitStore.stripEntriesForTest(icon: 80), vertical: true, gap: CGFloat(fitStore.prefs.gap),
                                                    padding: StripLayout.stripPadding).size.height > available)
    check("要素が多いと、アイコンが設定より縮む", fitStore.effectiveIconSize < 80)
    check("設定の大きさは書き換えない", fitStore.prefs.iconSize == 80)
    check("帯のウィンドウが画面に収まる", fitStore.stripWindowSize().height <= available + 1)
    check("帯の枠（描画・当たり判定）も収まる", fitStore.stripLayout().size.height <= available + 1)
    fitStore.groups = []
    check("要素が少なければ、設定の大きさのまま", fitStore.effectiveIconSize == 80)

    // フリーズの再現：描画ではタイルごとに何度も呼ばれる。状態が変わらない間は、計算は 1 回だけ。
    fitStore.groups = (0..<20).map { Group(name: "グループ \($0)") }
    let before = stripFitComputations
    for _ in 0..<50 { _ = fitStore.effectiveIconSize; _ = fitStore.stripLayout(); _ = fitStore.stripWindowSize() }
    check("状態が変わらない間は、縮小の計算を 1 回しかしない（描画のたびに作り直さない）",
          stripFitComputations - before <= 1)
    fitStore.groups.append(Group(name: "増えた"))
    let afterChange = stripFitComputations
    _ = fitStore.effectiveIconSize
    check("状態が変わったら、計算し直す", stripFitComputations - afterChange == 1)
    fitStore.prefs.iconSize = 60
    _ = fitStore.effectiveIconSize
    check("設定を変えても計算し直す", fitStore.effectiveIconSize <= 60)
}

// はみ出すときの方式：「縮める」（既定）と「ページを切り替える」（FF14 のホットバーのように、アプリとウィジェットを別々のページに分ける）。
do {
    // ページ分け：1 ページに収まる分だけ前から詰める。1 つも入らなくても、最低 1 つは置く（進まなくならない）。
    let lens: [CGFloat] = [40, 40, 40, 40, 40, 40, 40]
    let pages = StripPaging.pages(lengths: lens, budget: 100)
    check("収まる分ずつページに分ける", pages == [0..<2, 2..<4, 4..<6, 6..<7])
    check("全部収まれば 1 ページ", StripPaging.pages(lengths: lens, budget: 1000) == [0..<7])
    check("1 つも入らない予算でも、1 ページに最低 1 つは置く", StripPaging.pages(lengths: [80, 80], budget: 10) == [0..<1, 1..<2])
    check("空なら 1 ページ（空）", StripPaging.pages(lengths: [], budget: 100) == [0..<0])
    check("ページ番号は範囲に収める（項目が減っても落ちない）",
          StripPaging.clamp(5, count: 3) == 2 && StripPaging.clamp(-1, count: 3) == 0 && StripPaging.clamp(0, count: 0) == 0)

    // 予算：アプリとウィジェットで、残りの長さを分け合う。短い側は、必要な分だけ取る。
    let both = StripPaging.budgets(widgets: 900, apps: 900, available: 600)
    check("どちらも長ければ半分ずつ", both.widgets == 300 && both.apps == 300)
    let smallW = StripPaging.budgets(widgets: 100, apps: 900, available: 600)
    check("ウィジェットが短ければ、その分だけ取り、残りをアプリへ", smallW.widgets == 100 && smallW.apps == 500)
    let smallA = StripPaging.budgets(widgets: 900, apps: 100, available: 600)
    check("アプリが短ければ、その分だけ取り、残りをウィジェットへ", smallA.apps == 100 && smallA.widgets == 500)

    // 実際の帯：ご主人様の設定（左置き・ウィジェット多数）で、大きさを保ったまま収まる。
    let pagedStore = Store()
    pagedStore.prefs.position = "left"
    pagedStore.prefs.overflow = "pages"
    pagedStore.prefs.iconSize = 60
    pagedStore.prefs.widgets = [.date, .nowPlaying, .cpu, .memory, .disk, .volume, .brightness, .microphone, .battery, .trend, .calendar]
        .map { Widget(kind: $0) }
    pagedStore.groups = (0..<12).map { Group(name: "グループ \($0)") }
    let pagedAvailable = pagedStore.stripAvailableLength()
    check("ページ切り替えでは、アイコンを縮めない（設定の大きさのまま）", pagedStore.effectiveIconSize == 60)
    let pagedEntries = pagedStore.stripEntriesForTest(icon: 60)
    check("縮めると収まらない前提", StripLayout.make(pagedEntries, vertical: true, gap: CGFloat(pagedStore.prefs.gap),
                                                    padding: StripLayout.stripPadding).size.height > pagedAvailable)
    let pagedLayout = pagedStore.stripLayout()
    check("帯が画面に収まる（大きさを保ったまま）", pagedLayout.size.height <= pagedAvailable + 1)
    let pagers = pagedStore.stripEntries().compactMap { entry -> (StripSection, Int, Int)? in
        if case .pager(let section, let page, let count) = entry.kind { return (section, page, count) }
        return nil
    }
    check("ウィジェットとアプリに、それぞれページ送りが付く", pagers.contains { $0.0 == .widgets } && pagers.contains { $0.0 == .apps })
    check("ページは 2 つ以上", pagers.allSatisfy { $0.2 >= 2 })
    let widgetIDs: ([StripEntry]) -> [String] = { $0.filter { if case .widget = $0.kind { return true } else { return false } }.map(\.id) }
    let page0 = widgetIDs(pagedStore.stripEntries())
    pagedStore.setPage(.widgets, 1)
    let page1 = widgetIDs(pagedStore.stripEntries())
    check("ウィジェットのページを送ると、別のウィジェットが出る", !page0.isEmpty && !page1.isEmpty && page0 != page1)
    check("ウィジェットを送っても、アプリのページは変わらない",
          pagedStore.stripEntries().contains { if case .group = $0.kind { return true } else { return false } })
    pagedStore.setPage(.widgets, 99)
    check("範囲を超えたページ番号は、最後のページに収める（落ちない）", !widgetIDs(pagedStore.stripEntries()).isEmpty)
    check("設定の大きさは書き換えない", pagedStore.prefs.iconSize == 60)
    pagedStore.prefs.widgets = [Widget(kind: .clock)]
    pagedStore.groups = []
    check("要素が少なければ、ページ送りは付かない",
          !pagedStore.stripEntries().contains { if case .pager = $0.kind { return true } else { return false } })

    // 縮める方式（既定）：従来どおり縮む。
    pagedStore.prefs.overflow = "shrink"
    pagedStore.prefs.widgets = [.date, .nowPlaying, .cpu, .memory, .disk, .volume, .brightness, .microphone, .battery, .trend, .calendar]
        .map { Widget(kind: $0) }
    pagedStore.groups = (0..<12).map { Group(name: "グループ \($0)") }
    check("縮める方式では、収まるまで縮む", pagedStore.effectiveIconSize < 60)
    check("縮める方式では、ページ送りは付かない",
          !pagedStore.stripEntries().contains { if case .pager = $0.kind { return true } else { return false } })
    check("古い設定（方式なし）は、既定のページ切り替え（大きさを保つ）", (try? JSONDecoder().decode(Prefs.self, from: "{}".data(using: .utf8)!))?.overflow == "pages")
}

// 自動で隠したとき、隣のディスプレイへはみ出さない：隠す側に別のディスプレイがあれば、端の細い帯だけにする。
do {
    let left = NSRect(x: 0, y: 0, width: 1800, height: 1169)           // 左のディスプレイ
    let right = NSRect(x: 1800, y: 89, width: 1920, height: 1080)      // 右のディスプレイ
    let shown = NSRect(x: 1808, y: 300, width: 70, height: 700)        // 右のディスプレイの左端に出した帯
    // 右のディスプレイで「左置き」を隠すと、左へ出ていく。左には別のディスプレイがある。
    let hidden = HiddenPlacement.frame(
        shown: shown, position: "left", visible: right, screen: right, others: [left], peek: 6)
    check("隣のディスプレイがある側へは、はみ出さない（端の細い帯だけ）",
          hidden.minX >= right.minX && hidden.width == 6)
    check("細い帯は、自分のディスプレイの内側に収まる", right.contains(hidden))
    // 隣が無い側（左のディスプレイの左端）は、従来どおり画面の外へ隠す。
    let shownLeft = NSRect(x: 8, y: 300, width: 70, height: 700)
    let outside = HiddenPlacement.frame(
        shown: shownLeft, position: "left", visible: left, screen: left, others: [right], peek: 6)
    check("隣が無い側は、従来どおり画面の外へ隠す", outside.minX == left.minX - 70 + 6 && outside.width == 70)
    // 右置きで、右に別のディスプレイがある場合。
    let shownRight = NSRect(x: 1722, y: 300, width: 70, height: 700)
    let hiddenRight = HiddenPlacement.frame(
        shown: shownRight, position: "right", visible: left, screen: left, others: [right], peek: 6)
    check("右置きで右に隣があれば、細い帯だけ", hiddenRight.maxX <= left.maxX && hiddenRight.width == 6)
    // 下置きで、下に別のディスプレイがある場合。
    let below = NSRect(x: 0, y: -1080, width: 1920, height: 1080)
    let shownBottom = NSRect(x: 300, y: 8, width: 900, height: 80)
    let hiddenBottom = HiddenPlacement.frame(
        shown: shownBottom, position: "bottom", visible: NSRect(x: 0, y: 0, width: 1920, height: 1080),
        screen: NSRect(x: 0, y: 0, width: 1920, height: 1080), others: [below], peek: 6)
    check("下置きで下に隣があれば、細い帯だけ", hiddenBottom.minY >= 0 && hiddenBottom.height == 6)
    // 隣のディスプレイと重ならないことを、すべての向きで確かめる。
    check("隠した帯は、隣のディスプレイと重ならない",
          !hidden.intersects(left) && !hiddenRight.intersects(right) && !hiddenBottom.intersects(below))

    // 出す判定：カーソルが、その帯のディスプレイ自身の端にあるときだけ。隣のディスプレイ上では出さない。
    let onLeftDisplay = NSPoint(x: 900, y: 500)           // 左のディスプレイの真ん中
    let atRightEdge = NSPoint(x: 1803, y: 500)            // 右のディスプレイの左端
    check("隣のディスプレイ上では、端に寄ったと見なさない（出しっぱなしにならない）",
          !EdgeReveal.nearEdge(mouse: onLeftDisplay, position: "left", visible: right, screen: right, peek: 6))
    check("そのディスプレイの端なら、寄ったと見なす",
          EdgeReveal.nearEdge(mouse: atRightEdge, position: "left", visible: right, screen: right, peek: 6))
    check("端から離れていれば、寄っていない",
          !EdgeReveal.nearEdge(mouse: NSPoint(x: 2400, y: 500), position: "left", visible: right, screen: right, peek: 6))
    check("右置きは、右端のとき寄ったと見なす",
          EdgeReveal.nearEdge(mouse: NSPoint(x: 1797, y: 500), position: "right", visible: left, screen: left, peek: 6)
          && !EdgeReveal.nearEdge(mouse: NSPoint(x: 2000, y: 500), position: "right", visible: left, screen: left, peek: 6))
    check("下置きは、下端のとき寄ったと見なし、上のディスプレイ上では見なさない",
          EdgeReveal.nearEdge(mouse: NSPoint(x: 300, y: 3), position: "bottom", visible: NSRect(x: 0, y: 0, width: 1920, height: 1080),
                              screen: NSRect(x: 0, y: 0, width: 1920, height: 1080), peek: 6)
          && !EdgeReveal.nearEdge(mouse: NSPoint(x: 300, y: -500), position: "bottom", visible: NSRect(x: 0, y: 0, width: 1920, height: 1080),
                                  screen: NSRect(x: 0, y: 0, width: 1920, height: 1080), peek: 6))
}

// サイズを変えても変わらない（原因）：左置き・ウィジェット多数では、36pt でも収まらず、縮める方式だと常に同じ大きさに縮む。
// 既定はページ切り替え（大きさを保つ）にして、スライダーの値が見た目に届くようにする。
do {
    let sizeStore = Store()
    sizeStore.prefs.position = "left"
    sizeStore.prefs.gap = 0
    sizeStore.prefs.widgets = [.date, .nowPlaying, .cpu, .memory, .disk, .volume, .brightness, .microphone, .battery].map { Widget(kind: $0) }
    check("既定は、大きさを保つページ切り替え", Prefs().overflow == "pages")
    var seen = Set<CGFloat>()
    for size in [40.0, 52.0, 64.0, 80.0] {
        sizeStore.prefs.iconSize = size
        seen.insert(sizeStore.effectiveIconSize)
        check("既定のまま、設定の大きさ（\(Int(size))）がそのまま使われる", sizeStore.effectiveIconSize == CGFloat(size))
    }
    check("サイズを変えると、実際の大きさも変わる", seen.count == 4)
    sizeStore.prefs.overflow = "shrink"
    // どの画面でも、下限（24pt）でも収まらない量にする（画面の実寸に結果が左右されないように）。
    sizeStore.groups = (0..<100).map { Group(name: "グループ \($0)") }
    seen = []
    for size in [40.0, 52.0, 64.0, 80.0] {
        sizeStore.prefs.iconSize = size
        seen.insert(sizeStore.effectiveIconSize)
    }
    check("縮める方式では、収まらないほど多いと、サイズを変えても同じに縮む（これが以前の症状）", seen.count == 1)
}

// ゴミ箱の右クリックメニュー：項目は純粋関数で決める。空にするのは、中身があるときだけ押せる（確認つき）。
do {
    let full = TrashMenuSpec.items(isEmpty: false)
    check("ゴミ箱を開く・空にする・Finder で表示の項目が並ぶ",
          full.map(\.action) == [.open, .empty])
    check("中身があれば、空にするを押せる", full.first { $0.action == .empty }?.enabled == true)
    let empty = TrashMenuSpec.items(isEmpty: true)
    check("空のときは、空にするを押せない（開くは押せる）",
          empty.first { $0.action == .empty }?.enabled == false && empty.first { $0.action == .open }?.enabled == true)
    check("空にするは、確認を挟む（壊す操作）", TrashMenuSpec.needsConfirmation(.empty) && !TrashMenuSpec.needsConfirmation(.open))
    check("確認の文に、件数が入る", TrashMenuSpec.confirmationMessage(count: 3).contains("3"))
    check("項目名は動詞で終わる", full.map(\.title) == ["ゴミ箱を開く", "ゴミ箱を空にする…"])
    // Finder への問い合わせの失敗は、0 件として扱わない（黙って何も起きなくならない）。
    check("件数が読めれば、その数", TrashMenuSpec.count(text: "3", failed: false) == 3)
    check("問い合わせが失敗したら、件数なし（0 件にしない）", TrashMenuSpec.count(text: nil, failed: true) == nil)
    check("失敗フラグが立っていれば、文字があっても件数なし", TrashMenuSpec.count(text: "3", failed: true) == nil)
    check("数字でなければ、件数なし", TrashMenuSpec.count(text: "abc", failed: false) == nil)
    check("本当に 0 件なら 0", TrashMenuSpec.count(text: "0", failed: false) == 0)
}

// ページ送りの見直し：「並べる数」（既定 1。左右置きは列数・下置きは段数）と、全ページの大きさの固定。
do {
    check("並べる数の既定は 1", Prefs().stripLines == 1)
    check("古い設定（項目なし）も 1", (try? JSONDecoder().decode(Prefs.self, from: "{}".data(using: .utf8)!))?.stripLines == 1)
    check("並べる数は 1〜6 に収める", Prefs.clampLines(0) == 1 && Prefs.clampLines(99) == 6 && Prefs.clampLines(3) == 3)

    // 格子：N 本の列に、順番に配る（列が先に埋まる向きではなく、各ページは先頭から行ごとに並べる）。
    let sizes = [CGFloat](repeating: 40, count: 10)
    let grid = StripPaging.grid(lengths: sizes, lines: 3, budget: 100)
    check("1 ページは「並べる数 × 1 本の長さに収まる数」までの項目",
          grid.pages.first.map { $0.count } == 6)             // 3 本 × 長さ 100 に 2 個ずつ
    check("全ページを通して、すべての項目がちょうど 1 回ずつ出る",
          grid.pages.flatMap { $0 }.sorted() == Array(0..<10))
    check("1 本あたりの長さが、すべてのページで同じ（大きさを固定）",
          Set(grid.pages.map { _ in grid.pageLength }).count == 1)
    check("ページの長さは、最大のページで決まる（小さいページも同じ長さで確保）",
          grid.pageLength >= 80)
    check("並べる数が 1 なら、従来どおり 1 本", StripPaging.grid(lengths: sizes, lines: 1, budget: 100).pages.map { $0.count } == [2, 2, 2, 2, 2])

    // 設定した本数に必ずなる：項目が少なくても、長さの予算に余裕があっても、ページの本数は設定どおり。
    for lines in 1...4 {
        let few = StripPaging.grid(lengths: [CGFloat](repeating: 40, count: 9), lines: lines, budget: 10_000)
        check("予算に余裕があっても、\(lines) 本に分ける（全部が 1 本に入らない）", few.lanes == lines)
        let lanesUsed = Set(few.pages.first?.map { few.lane[$0] } ?? [])
        check("1 ページ目で、\(lines) 本すべてに項目が入る", lanesUsed == Set(0..<lines))
    }
    let evenly = StripPaging.grid(lengths: [CGFloat](repeating: 40, count: 9), lines: 3, budget: 10_000)
    check("本ごとの項目数は、ほぼ均等（9 個を 3 本 → 3・3・3）",
          (0..<3).map { lane in evenly.pages[0].filter { evenly.lane[$0] == lane }.count } == [3, 3, 3])
    check("項目が本数より少なくても、本の数は設定どおり（空の本で幅を保つ）",
          StripPaging.grid(lengths: [40, 40], lines: 5, budget: 10_000).lanes == 5)
    check("最終ページが少なくても、本の数は全ページ共通",
          { let g = StripPaging.grid(lengths: [CGFloat](repeating: 40, count: 7), lines: 3, budget: 40)
            return g.lanes == 3 && g.pages.count == 3 }())
    check("本ごとの長さの差は、最大でも項目 1 つ分",
          { let g = StripPaging.grid(lengths: [30, 50, 40, 60, 20, 45, 35], lines: 3, budget: 10_000)
            let totals = (0..<g.lanes).map { lane in g.pages[0].filter { g.lane[$0] == lane }.reduce(CGFloat(0)) { $0 + [30, 50, 40, 60, 20, 45, 35][$1] } }
            return (totals.max() ?? 0) - (totals.min() ?? 0) <= 60 }())

    // 実際の帯：ページを送っても、帯全体の大きさが変わらない。
    let fixedStore = Store()
    fixedStore.prefs.position = "left"
    fixedStore.prefs.overflow = "pages"
    fixedStore.prefs.iconSize = 60
    fixedStore.prefs.widgets = [.date, .nowPlaying, .cpu, .memory, .disk, .volume, .brightness, .microphone, .battery, .trend, .calendar]
        .map { Widget(kind: $0) }
    fixedStore.groups = (0..<12).map { Group(name: "グループ \($0)") }
    var windowSizes = Set<String>()
    for page in 0..<3 {
        fixedStore.setPage(.widgets, page)
        fixedStore.setPage(.apps, page)
        let size = fixedStore.stripWindowSize()
        windowSizes.insert("\(Int(size.width))x\(Int(size.height))")
    }
    check("ページを送っても、帯の大きさが変わらない", windowSizes.count == 1)
    fixedStore.prefs.stripLines = 3
    let threeCols = fixedStore.stripWindowSize()
    check("並べる数を増やすと、帯が横（左右置きは幅）へ広がる", threeCols.width > 100)
    check("並べる数を増やしても、画面に収まる", threeCols.height <= fixedStore.stripAvailableLength() + 1)

    // 収まるときも、設定した数になる（ページ切り替えの方式では、並べる数は常に効く）。
    let fitsStore = Store()
    fitsStore.prefs.overflow = "pages"
    fitsStore.prefs.position = "left"
    fitsStore.prefs.widgets = []
    fitsStore.groups = []
    let oneCol = fitsStore.stripWindowSize().width
    fitsStore.prefs.stripLines = 3
    let appEntries = fitsStore.stripEntries().filter { if case .pinned = $0.kind { return true } else { return false } }
    check("収まるときも、アプリの区画は設定の 3 列", !appEntries.isEmpty && appEntries.allSatisfy { $0.lanes == 3 })
    check("収まるときも、帯の幅が 3 列分に広がる", fitsStore.stripWindowSize().width > oneCol * 2)
    fitsStore.prefs.stripLines = 1
    check("並べる数が 1 なら、これまでどおり 1 列", fitsStore.stripWindowSize().width == oneCol)
    fitsStore.prefs.widgets = [.date, .cpu, .memory].map { Widget(kind: $0) }
    fitsStore.prefs.stripLines = 2
    let sections = fitsStore.stripEntries().filter { $0.blockLength > 0 }
    check("ウィジェットとアプリで、列の数が同じ（設定どおり）", !sections.isEmpty && Set(sections.map(\.lanes)) == [2])
}

// バージョン表示：ビルドごとに上がる番号（Info.plist の CFBundleShortVersionString / CFBundleVersion）を、設定の一般に出す。
do {
    check("バージョンと番号があれば、両方出す", AppVersion.text(short: "0.2.37", build: "37") == "バージョン 0.2.37（ビルド 37）")
    check("番号が無ければ、バージョンだけ", AppVersion.text(short: "0.2.37", build: nil) == "バージョン 0.2.37")
    check("どちらも無ければ（開発中の実行ファイルなど）、開発版", AppVersion.text(short: nil, build: nil) == "開発版（バージョン情報なし）")
    check("空の文字は、無いものとして扱う", AppVersion.text(short: "", build: "") == "開発版（バージョン情報なし）")
    check("次のビルド番号は 1 つ増える", AppVersion.nextBuild(current: "36") == 37)
    check("番号ファイルが空・壊れていれば、1 から", AppVersion.nextBuild(current: "") == 1 && AppVersion.nextBuild(current: "abc") == 1)
    check("バージョンは、VERSION と番号をつなぐ", AppVersion.shortVersion(version: "0.2", build: 37) == "0.2.37")
}

print(failures.isEmpty ? "ALL OK" : "FAILED: \(failures)")
exit(failures.isEmpty ? 0 : 1)
