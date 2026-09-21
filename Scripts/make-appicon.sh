#!/bin/sh
#
# Design/appicon.svg からアプリアイコンを作り直す。
#
#   Scripts/make-appicon.sh
#
# macOS 26 は新形式（Icon Composer の .icon）でないアイコンを、システムの
# 台座に載せて表示する。そこで背景は描かず、黒いグリフだけを透明地で渡して
# 台座を背景として使う。自前で角丸を描くと台座の上にもう一枚四角が乗り、
# 二重枠に見えてしまう。
#
set -e
cd "$(dirname "$0")/.."

SRC=Design/appicon.svg
OUT=Nanovid/Assets.xcassets/AppIcon.appiconset
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cp "$SRC" "$WORK/appicon.svg"
# SVG のラスタライズは QuickLook に任せる（追加のツールを入れずに済む）。
(cd "$WORK" && qlmanage -t -s 1024 -o . appicon.svg >/dev/null 2>&1)
[ -f "$WORK/appicon.svg.png" ] || { echo "SVG を描けませんでした" >&2; exit 1; }

swift Scripts/icon-mask.swift "$WORK/appicon.svg.png" "$OUT/icon_1024.png" >/dev/null
for s in 16 32 64 128 256 512; do
    sips -Z $s "$OUT/icon_1024.png" --out "$OUT/icon_$s.png" >/dev/null
done

echo "作り直しました:"
ls -1 "$OUT"/*.png | sed 's/^/  /'
