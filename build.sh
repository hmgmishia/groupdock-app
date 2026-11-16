#!/bin/sh
# GroupDock を dist/GroupDock.app に組み立てる。
# ビルドのたびに BUILD_NUMBER を 1 つ上げ、VERSION（例 0.2）と合わせて Info.plist へ書く（アプリの設定 › 一般 で確認できる）。
# 番号を上げたくないとき（検証だけ）は、NO_BUMP=1 を付ける。
set -eu
cd "$(dirname "$0")"

VERSION=$(tr -d '[:space:]' < VERSION)
CURRENT=$(tr -d '[:space:]' < BUILD_NUMBER 2>/dev/null || true)
case "$CURRENT" in ''|*[!0-9]*) CURRENT=0 ;; esac
if [ "${NO_BUMP:-0}" = "1" ]; then BUILD=$CURRENT; else BUILD=$((CURRENT + 1)); printf '%s\n' "$BUILD" > BUILD_NUMBER; fi
SHORT="$VERSION.$BUILD"

APP=dist/GroupDock.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -target "$(uname -m)-apple-macos14.0" Sources/*.swift -o "$APP/Contents/MacOS/GroupDock"
cp Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SHORT" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
# 再生中の補助ライブラリ（Apple 署名の perl に読み込ませる。arm64e が要る）。
mkdir -p "$APP/Contents/Resources"
clang -arch arm64e -arch x86_64 -dynamiclib -fobjc-arc -framework Foundation \
    Helper/gdnowplaying.m -o "$APP/Contents/Resources/gdnowplaying.dylib"
./sign.sh "$APP/Contents/Resources/gdnowplaying.dylib" >/dev/null
./sign.sh "$APP"
echo "built $APP ($SHORT)"
