#!/bin/sh
#
# Mac App Store のスクリーンショット（2880×1800、ja・en 各 6 枚）を作り直す。
#
#   Scripts/screenshots/run.sh <出力ディレクトリ> [ja|en ...]
#
# 1. Debug ビルドを作る（撮影用の起動引数 --shot-* は Debug だけにある）
# 2. デモ書類「ハンドドリップ入門」/「Pour-Over Basics」を作る（scenes.py・make_demo.py。
#    絵は PIL で描き、ナレーションは say、BGM と動画は ffmpeg）
# 3. 1 枚ずつアプリを起動し、状態を起動引数で作って、窓を 2 倍の画素で描かせる
#    （--shot-png。画面の倍率によらず 2560×1600 になる）。窓は画面の外に置く
# 4. 前回と同じ背景・影に合成する（compose.py）
#
# 本物のクリックやキーは送らない。アプリも前に出さない（そのため窓は
# 「使っていない窓」の見た目で、選んでいる項目やボタンは青くならない。信号機と
# ツールバーの下地だけ compose.py で塗る）。
# 02 だけはメニューを画面に出す（メニューは外から撮るしかないため）。数秒で消える。
#
# 要るもの: Xcode、python3 と Pillow、ffmpeg、macOS の say（Kyoko・Samantha の声）。
# 02 のメニューを撮るには、実行するターミナルに画面収録の許可が要る。
#
set -e
cd "$(dirname "$0")/../.."
OUT=${1:?出力ディレクトリを渡してください}
shift
LANGS=${*:-ja en}
T=$PWD/Scripts/screenshots
WORK=${NANOVID_SHOTS_WORK:-${TMPDIR:-/tmp/}nanovid-shots}

echo "ビルド中 (Debug)…"
xcodebuild -project Nanovid.xcodeproj -scheme Nanovid -configuration Debug build >/dev/null
APP_DIR=$(xcodebuild -project Nanovid.xcodeproj -scheme Nanovid -configuration Debug \
          -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{print $2}')
export NANOVID_APP="$APP_DIR/Nanovid.app"

rm -rf "$WORK"
mkdir -p "$WORK/img"
python3 -I "$T/scenes.py" "$WORK/img" >/dev/null

for L in $LANGS; do
    # テンプレートとトラック名の既定値は、その言語で作った書類からもらう。
    "$NANOVID_APP/Contents/MacOS/Nanovid" --write-demo "$WORK/base-$L" -AppleLanguages "($L)" >/dev/null
    python3 -I "$T/make_demo.py" "$WORK" "$WORK/base-$L/demo.nanovid/project.json" "$L" >/dev/null
    if [ "$L" = ja ]; then NAME="ハンドドリップ入門"; else NAME="Pour-Over Basics"; fi
    MAIN="$WORK/$L/$NAME.nanovid"
    SIL="$WORK/$L/silence/$NAME.nanovid"
    # 字幕のトラックの 4 本目・6 本目の真ん中（その時刻に字幕が出ている）。
    at() { python3 -I -c "import json,sys; c=json.load(open(sys.argv[1]))['tracks'][2]['clips'][int(sys.argv[2])]; print(round(c['start']+c['duration']/2,2))" "$MAIN/project.json" "$1"; }
    AT4=$(at 3)
    AT6=$(at 5)
    S="$WORK/shots/$L"
    echo "$L: 撮影中…"
    "$T/take.sh" $L "$MAIN" "lanes:4,pps:25.5,select-text" "$S/01"
    "$T/take.sh" $L "$SIL" "lanes:4,pps:25.5,seek:1.5,silence-menu" "$S/02"
    "$T/take.sh" $L "$SIL" "lanes:4,pps:25.5,silence-cut,seek:1.5" "$S/03"
    "$T/take.sh" $L "$MAIN" "lanes:8,pps:25.5,text-tab,select-at:$AT4" "$S/04"
    "$T/take.sh" $L "$MAIN" "lanes:4,pps:25.5,select-text,template-editor" "$S/05"
    "$T/take.sh" $L "$MAIN" "lanes:4,pps:25.5,select-at:$AT6,export" "$S/06"
    mkdir -p "$OUT/$L"
    python3 -I "$T/compose.py" "$S/01" "$OUT/$L/01-timeline.png" >/dev/null
    python3 -I "$T/compose.py" "$S/02" "$OUT/$L/02-silence-cut.png" 1090,656 >/dev/null
    python3 -I "$T/compose.py" "$S/03" "$OUT/$L/03-silence-cut-result.png" >/dev/null
    python3 -I "$T/compose.py" "$S/04" "$OUT/$L/04-subtitles.png" >/dev/null
    python3 -I "$T/compose.py" "$S/05" "$OUT/$L/05-template.png" >/dev/null
    python3 -I "$T/compose.py" "$S/06" "$OUT/$L/06-export.png" >/dev/null
done
echo "できました: $OUT"
