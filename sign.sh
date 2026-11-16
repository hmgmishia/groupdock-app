#!/bin/sh
# 使い方: ./sign.sh <app>
# 開発用の証明書があればそれで署名する。署名の要件が「バンドル ID + 証明書」で固定され、
# ビルドしてもアクセシビリティなどの許可が外れない。無ければアドホック署名（ビルドごとに許可が外れる）。
set -eu
APP="$1"
ID=$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development|Developer ID Application/ {print $2; exit}')
if [ -n "${ID:-}" ] && codesign --force --sign "$ID" "$APP" >/dev/null 2>&1; then
    echo "signed with a stable identity (permissions persist across builds)"
else
    codesign --force --sign - "$APP" >/dev/null 2>&1
    echo "signed ad-hoc (accessibility permission must be granted again after each build)"
fi
