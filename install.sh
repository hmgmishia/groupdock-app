#!/bin/sh
# 最新ビルドを /Applications に反映して起動し直す（署名が変わるので毎回やる）。
set -eu
cd "$(dirname "$0")"

./build.sh
DEST=/Applications/GroupDock.app

pkill -f "GroupDock.app/Contents/MacOS/GroupDock" 2>/dev/null || true
sleep 1
rm -rf "$DEST"
cp -R dist/GroupDock.app "$DEST"
./sign.sh "$DEST"
open "$DEST"
echo "installed $DEST"
