# ガジェット（ウィジェット）を作る

GroupDock のウィジェットは、**JSON を 1 枚置くだけ**で追加できる。アプリの再ビルドも更新も要らない。

## 取り込み（再ビルド・再起動は不要）

設定 → ウィジェット →「ギャラリー…」→「**取り込む…**」で、`.json` または `.groupwidget` を選ぶ。
取り込んだ瞬間に読み込まれて帯に追加される。アプリの更新も再起動も要らない。

- フォルダ（`~/Library/Application Support/GroupDock/Widgets`）に直接置いてもよい。
  **1.5 秒ごとに見張っていて、置いた / 消した / 書き換えたら自動で反映**する
- 同じ `id` の定義は上書きされる

## 置き場所

```
~/Library/Application Support/GroupDock/Widgets/*.json
```

設定 → ウィジェット →「ギャラリー…」→「フォルダを開く」で開ける。
追加・変更したら「再読み込み」を押す（起動時にも自動で読む）。

## 定義（JSON）

```json
{
  "id": "com.example.weather",
  "title": "天気",
  "symbol": "cloud.sun",
  "type": "ring",
  "command": "date +%H:%M",
  "interval": 60,
  "tint": "blue",
  "parameters": [
    { "id": "city", "label": "都市", "kind": "text", "defaultValue": "Tokyo" },
    { "id": "unit", "label": "単位", "kind": "choice", "defaultValue": "C", "choices": ["C", "F"] },
    { "id": "detail", "label": "詳細も出す", "kind": "toggle", "defaultValue": "false" }
  ]
}
```

| 項目 | 意味 |
| --- | --- |
| `id` | 一意な ID（逆ドメイン風） |
| `title` | 帯に出る名前 |
| `symbol` | SF Symbols の名前 |
| `type` | `text`（文字）／`ring`（数値をリング）／`chart`（**横長のグラフ**）／`clock`／`date` |
| `command` | `/bin/sh -c` で実行するコマンド。**標準出力の 1 行目**を表示 |
| `interval` | 既定の更新間隔（秒）。外部コマンドは最短 10 秒 |
| `tint` | accent / red / orange / yellow / green / blue / purple / pink / gray |
| `parameters` | 自由な設定項目（下記） |

## 横長のグラフ（chart）

`"type": "chart"` にすると、コマンドの出力を**数値の並び**として読み、横長のエリアチャートで描く。

```json
{
  "id": "com.example.cpu",
  "title": "負荷の推移",
  "type": "chart",
  "command": "ps -A -o %cpu",
  "interval": 5
}
```

- 出力はカンマ・空白・改行のどれで区切ってもよい（例 `12,18,25` や `12 18 25`）
- 値は 0〜100 として描く
- 点の数は帯のウィジェットを右クリック →「設定…」→「グラフの点数」で変えられる（10〜120）

組込みの「推移」ウィジェット（CPU 使用率）も同じ描画で、設定から正方形にもできる。

## バンドル（.groupwidget）

スクリプトや画像など、複数のファイルをまとめたいときは**フォルダ**にして拡張子を `.groupwidget` にする。

```
MyWidget.groupwidget/
  manifest.json      ← 下の JSON（定義と同じ形式）
  data.txt           ← 好きなファイル（スクリプト・画像など）
```

`manifest.json` の中で `{bundle}` と書くと、そのバンドルのフォルダのパスに置き換わる。

```json
{
  "id": "com.example.mine",
  "title": "マイウィジェット",
  "type": "chart",
  "command": "/bin/sh {bundle}/update.sh",
  "interval": 15
}
```

## 許可と安全（必ず読む）

外部ウィジェットの `command` は、**GroupDock と同じ権限**で動く。そのため次のように絞ってある。

| 仕組み | 動き |
| --- | --- |
| **許可制** | 取り込んだときに内容を確認し、承認した定義だけがコマンドを実行する。設定 › ウィジェット › 許可 の一覧から「取り消す」でいつでも止められる |
| **全体スイッチ** | 設定 › ウィジェット ›「ウィジェットのコマンドを実行する」をオフにすると、全部が表示のみになる（組織で配るときはオフから始めると安全） |
| **通信の拒否（既定）** | 通信を許していないときは `sandbox-exec` で `(deny network*)` と `(deny file-write*)` を適用する。設定で明示的にオンにしたときだけ通信できる |
| **パラメータは引用** | `{id}` は**シェル引用して**差し込む。`$(...)` などを入れても追加のコマンドは動かない。改行は空白にし、200 文字で切る |
| **環境変数** | `$GROUPWIDGET_<ID>`（大文字）でも値を受け取れる。`{bundle}` は `$GROUPWIDGET_BUNDLE` |
| **打ち切り** | 5 秒で停止。`sh -c` の子プロセスも止める。出力は 256KB で切る |

`parameters` の値に秘密情報を入れないこと（設定ファイルに平文で残る）。

## 設定項目（parameters）

`kind` は `text` / `number` / `toggle` / `choice`。
コマンドの中では `{id}`（引用済み）または `$GROUPWIDGET_<ID>`（環境変数）で参照でき、
**ウィジェットごとに値を変えられる**（帯のウィジェットを右クリック →「設定…」）。

```json
{ "command": "date +{format}" }
```

### 使えるコマンド（許可リスト）

シェルは通りません。**下のプログラムを、引数つきで直接起動**するだけです。

`echo` / `date` / `uptime` / `df` / `ps` / `vm_stat` / `sysctl` / `pmset` / `cat`

- `sh` `bash` `zsh` `curl` `wget` `python` などは**拒否**（理由がログに残る）
- `|` `;` `&&` `$(` バッククォート `>` `<` `*` `{a,b}` などのシェル記号も**拒否**
- `cat` はバンドル（`.groupwidget`）の中のファイルだけ読める
- 追加してほしいプログラムがあれば `Sources/CommandGuard.swift` の許可リストに足す（引数だけで完結するものに限る）

`choice` は `choices` に選択肢を並べる。`toggle` は `"true"` / `"false"` が入る。

## どんな見た目が作れるか

`type` で描き方が決まる。グラフィカルなウィジェットは、この組み合わせで作れる。

| type | 見た目 | 向いているもの |
| --- | --- | --- |
| `ring` | リング（0〜100） | バッテリー・CPU・達成率 |
| `chart` | 横長のエリアチャート | 推移・履歴・為替 |
| `text` | 大きな文字 | 時計・数値・短い文 |
| `clock` / `date` | 時計・日付（地域・秒・書式は設定から） | — |

色（`tint`）・形（正方形／横長）・更新間隔・グラフの点数は、帯のウィジェットを
右クリック →「設定…」でウィジェットごとに変えられる。

## 安全のため

- コマンドは **5 秒で打ち切る**。固まるコマンドは `—` になる
- 外部コマンドは **最短 10 秒間隔**（重い処理で帯が固まらないように）
- ネットワークや鍵は各自の責任で。設定はローカルの JSON にだけ保存される
