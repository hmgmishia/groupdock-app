#!/bin/sh
# ドラッグ＆ドロップなど、UI を通さずに確かめられるロジックのテスト。
# UI を含まないソースだけをコピーしてコンパイルする。保存先は環境変数 GROUPDOCK_TEST_DATA のフォルダへ差し替える
# （Store.directoryOverride。ソースの書き換えはしない）。
set -eu
cd "$(dirname "$0")/.."

OUT=.build/tests
DATA="$PWD/$OUT/data"
rm -rf "$OUT"
mkdir -p "$OUT" "$DATA"

FILES="Model Persistence Widgets WidgetLibrary Badges TileHitTest StripLayout CommandGuard Watchdog SystemDock BubblePlacement WidgetActions NowPlaying Instances DockMenu MenuPresenter Clipboard ClipboardCrypto ClipboardStore AudioDevices AudioHardware AudioReader AudioPinEnforcer BluetoothPaired DisplayBrightness AppVersion GaugeWheel PopupLayout GroupName Typo"
SOURCES=""
for f in $FILES; do
    cp "Sources/$f.swift" "$OUT/$f.swift"
    SOURCES="$SOURCES $OUT/$f.swift"
done

cp tests/main.swift "$OUT/main.swift"
# 機能ごとに分けたテスト（main.swift の check / failures を使う）。
for t in tests/*.swift; do
    [ "$t" = "tests/main.swift" ] && continue
    cp "$t" "$OUT/$(basename "$t")"
    SOURCES="$SOURCES $OUT/$(basename "$t")"
done
# shellcheck disable=SC2086
swiftc -O $SOURCES "$OUT/main.swift" -o "$OUT/tests"
GROUPDOCK_TEST_DATA="$DATA" "$OUT/tests"
