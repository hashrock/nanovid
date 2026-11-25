#!/bin/sh
# 1 枚描く（run.sh から呼ぶ）。使い方: take.sh <ja|en> <書類> <状態> <出力ディレクトリ> [onscreen]
# アプリ自身が 2 倍の画素で窓を描いて書き出す（--shot-png）。既定では窓を画面の外に置く。
# 自分で起動した Nanovid だけを PID で終わらせる（ほかの Nanovid には触れない）。
set -e
LANG_CODE=$1
DOC=$2
STATE=$3
OUTDIR=$4
APP=${NANOVID_APP:?run.sh から呼ぶか、NANOVID_APP に Debug の Nanovid.app を渡してください}
OFF=--shot-offscreen
MENU=
case "$STATE" in *silence-menu*) OFF=; MENU="--shot-menu-scale 2" ;; esac
rm -rf "$OUTDIR"
"$APP/Contents/MacOS/Nanovid" -AppleLanguages "($LANG_CODE)" -AppleLocale "${LANG_CODE}_JP" \
    --open "$DOC" --shot-size 1280x800 --shot-appearance light --shot-state "$STATE" \
    --shot-png "$OUTDIR" $OFF $MENU >/dev/null 2>&1 &
PID=$!
for _ in $(seq 1 60); do
    [ -f "$OUTDIR/windows.json" ] && break
    sleep 0.5
done
if [ -n "$MENU" ]; then
    # 開いたメニューは画面に出ている窓なので、外から等倍で撮る（文字は 2 倍で出してある）。
    sleep 1.5
    swift "$(dirname "$0")/shot.swift" $PID "$OUTDIR/menu" >/dev/null
fi
kill $PID 2>/dev/null || true
wait $PID 2>/dev/null || true
[ -f "$OUTDIR/windows.json" ] || { echo "描けませんでした: $OUTDIR" >&2; exit 1; }
