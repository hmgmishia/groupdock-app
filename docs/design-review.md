# 設計レビュー（土台の評価と直す順番）

GroupDock の土台が、Swift の標準的な作りと、このアプリの思想（計算は純粋関数、描画と分ける）に合っているかの評価。
数値は 2026-11 時点の実測（`wc -l`・`search`）。

## 良い点（思想に合っている）

- **配置・判定・ページ分け・縮小・固定の解決が純粋関数**（`StripLayout`・`StripPaging`・`StripFit`・`HiddenPlacement`・`EdgeReveal`・`AudioDevices`・`FinderOpen`・`TrashMenuSpec`）。テストが 700 件超あり、不具合の再現と修正がテスト先行で回せている。
- **private API が 2 つだけで、`dlopen`・失敗時は「使えない」**。通信なし。
- **権限のダイアログを勝手に出さない**（Bluetooth）。

## 問題点（重い順）

| # | 問題 | 実測 | 影響 | 直し方 |
| --- | --- | --- | --- | --- |
| 1 | **`Store` が何でも屋**（神オブジェクト） | `Model.swift` 1182 行。保存 6 種（groups・kept・hidden・history・prefs・widgets）、実行中アプリ、バッジ、ウィジェットの更新タイマー 4 本、クリップボード、再生中、音声の固定、並べ替えの操作、帯の縮小/ページ分けを 1 つの型が持つ | どこを直しても全体に波及する。`@Published` が 25 個あり、1 つ変わると画面全体が描き直される | 責務ごとに分ける：`Persistence`（保存）、`RunningApps`、`WidgetRefresher`、`GroupEditing`。`Store` は束ねる薄い窓口にする |
| 2 | **`DockWindowController` が巨大** | `DockWindow.swift` 1276 行。ウィンドウ、マウス、ドラッグ、右クリックメニュー、自動で隠す判定、レイアウトを 1 つの型が持つ | 同上。メニューの項目は純粋関数に出せているが、組み立ては混在 | メニュー（`appMenu`・`stripMenu`）、ドラッグ、自動で隠すを別の型へ |
| 3 | **並行性の作りが場当たり** | `@MainActor` が 0 件。`DispatchQueue` の呼び出しが約 60 か所、専用の直列キューが 7 本。`nonisolated(unsafe)` のグローバルが 2 つ、ロック付きの `static var` のキャッシュが 4 つ | 「どのスレッドで触るか」が型で示されず、`Binding` を裏のスレッドで読むなどの不具合が起きた。Swift 6 の言語モードでは通らない（`-warn-concurrency` で警告が大量に出る） | UI に触る型に `@MainActor` を付ける。裏の処理は `actor` か直列キュー 1 本に集約する。`nonisolated(unsafe)` を、`@MainActor` の値へ |
| 4 | **状態管理が古い仕組み** | `ObservableObject`＋`@Published`＋`@ObservedObject` が 26 か所。対象は macOS 14 以降 | `@Observable`（Observation）なら、使った値だけで再描画され、描画が軽くなる | `@Observable` へ移行（`Store`・`NowPlayingState`・`ClipboardStore`）。1 の分割と同時にやるのが安全 |
| 5 | **エラーを握りつぶす `try?`** | 約 60 か所。保存の失敗は `NSLog` するが、利用者には出ない。`NSLog` は構造化されない | 保存に失敗しても気づけない | 保存の失敗は 1 か所で `Logger`（`os`）に記録し、続けて失敗するときだけ画面に出す |
| 6 | **グローバルな状態** | `WidgetLibrary`（`static var` 6 個）、`IconCache`、`AppRef` のキャッシュ | テストで差し替えが要る。保存先の差し替えに、`tests/run.sh` が **python でソースを書き換える**（脆い） | 保存先を `directoryOverride` で注入し、書き換えをやめる（`ClipboardStore` と同じ形） |
| 7 | **テストの作り** | `tests/main.swift` が 2184 行の 1 ファイル。自前の `check`。`Package.swift` なし | 失敗の場所が探しにくい。`swift test` が使えない | 機能ごとのファイルに分ける。`Package.swift` を足して、`swift test` と `./tests/run.sh` の両方を通す |
| 8 | **UI の一貫性** | ① `ウインドウ`／`ウィンドウ`の表記ゆれ。② 同じ動作（`Launcher.open`）のボタン名が「開く」「前面に出す」「起動」と 3 通り。③ `.font(.system(size: n))` の固定サイズが 24 か所（文字サイズの設定に追従しない）。④ 廃止した「詳細モード」の `Prefs.advanced` が残る。⑤ README の一部が古い | 見た目と言葉が画面ごとに違う | ①②④⑤は文言と死んだ項目の整理。③は役割ごとの文字の大きさを 1 か所に定義する |
| 9 | **公開版の更新手順が無い** | `.build/publish.sh` は新規 1 commit のみ | 更新のたびに履歴が作り直せない | 差分を載せる更新用スクリプトにする |

## 直す順番（リスクの低い順・各段でテストと実機確認）

1. **文言と死んだ項目**（8 の①②④⑤）：済。
2. **保存先の注入**（6）：済（`Store.directoryOverride`）。
3. **保存を `Persistence` へ**（1 の一部、5）：済。失敗は記録し、続けて 3 回失敗したときだけ画面に出す。
4. **メニュー・ドラッグを `DockWindowController` から分ける**（2）：済（`DockMenus.swift`・`DockDrag.swift`）。自動で隠す判定は未分離。
5. **`@MainActor` の付与**（3）：一部済。`DockWindowController` と `AppDelegate` に付けた（警告 0）。他の UI 型と、裏の処理の集約は未着手。
6. **`@Observable` への移行**（4）：`NowPlayingState` と `ClipboardStore` は済。`Store` は**見送りと決定**（オーナーの回答）。効果は再描画の削減だけで、壊れると帯の再配置とドラッグが止まるため。理由：帯の再配置（`relayout`）が `store.objectWillChange`「何か 1 つでも変わったら」を拍にしていて、`@Observable` には同じ拍が無い。移すには、再配置の入力を明示して `withObservationTracking` で購読し直す設計変更になり、ビュー 20 か所超も書き換わる。
7. **テストの分割**（7）：済。`tests/main.swift` から 4 ファイル（`GaugeTests`・`UiTextTests`・`ClipboardSecurityTests`・`PersistenceTests`）へ分けた（PASS 838 件のまま不変）。`Package.swift`（`swift test`）は未着手：`main.swift` が最上位の共有変数を使うため、残りの分割に関数化が要る。
8. **文字サイズの定義**（8 の③）：済（`Typo`）。
9. **公開版の更新手順**（9）：済（`.build/publish.sh`）。

4〜6 は影響が広く、実機でしか確かめられない見た目や操作（ドラッグ、右クリック、自動で隠す）に触れる。1 段ごとに、反映して使ってから次へ進む。
