#!/bin/sh
# ドラッグ＆ドロップなど、UI を通さずに確かめられるロジックのテスト。
set -eu
cd "$(dirname "$0")/.."

OUT=.build/tests
DATA="$PWD/$OUT/data"
rm -rf "$OUT"
mkdir -p "$OUT/data" "$DATA"

# UI を含まないソースだけをコピーし、保存先をテスト用に差し替える。
for f in Model Widgets WidgetLibrary Badges TileHitTest StripLayout CommandGuard Watchdog SystemDock BubblePlacement WidgetActions NowPlaying Instances DockMenu MenuPresenter Clipboard ClipboardCrypto ClipboardStore AudioDevices AudioHardware AudioReader AudioPinEnforcer BluetoothPaired DisplayBrightness AppVersion; do
    cp "Sources/$f.swift" "$OUT/$f.swift"
done
python3 - "$OUT/Model.swift" "$DATA" <<'PY'
import sys
path, data = sys.argv[1], sys.argv[2]
src = open(path).read()
old = """        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("GroupDock/groups.json")"""
new = '        return URL(fileURLWithPath: "%s/groups.json")' % data
if old not in src:
    raise SystemExit("Model.swift の保存先が見つかりません")
open(path, "w").write(src.replace(old, new))
PY

cp tests/main.swift "$OUT/main.swift"
swiftc -O "$OUT/Model.swift" "$OUT/Widgets.swift" "$OUT/WidgetLibrary.swift" "$OUT/Badges.swift" "$OUT/TileHitTest.swift" "$OUT/StripLayout.swift" "$OUT/CommandGuard.swift" "$OUT/Watchdog.swift" "$OUT/SystemDock.swift" "$OUT/BubblePlacement.swift" "$OUT/WidgetActions.swift" "$OUT/NowPlaying.swift" "$OUT/Instances.swift" "$OUT/DockMenu.swift" "$OUT/MenuPresenter.swift" "$OUT/Clipboard.swift" "$OUT/ClipboardCrypto.swift" "$OUT/ClipboardStore.swift" "$OUT/AudioDevices.swift" "$OUT/AudioHardware.swift" "$OUT/AudioReader.swift" "$OUT/AudioPinEnforcer.swift" "$OUT/BluetoothPaired.swift" "$OUT/DisplayBrightness.swift" "$OUT/AppVersion.swift" "$OUT/main.swift" -o "$OUT/tests"
"$OUT/tests"
