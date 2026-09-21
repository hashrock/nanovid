#!/bin/sh
#
# nanovid をビルドして起動する。
#
#   Scripts/run.sh                       新規プロジェクトで起動
#   Scripts/run.sh path/to/movie.nanovid そのプロジェクトを開いて起動
#   Scripts/run.sh --demo                テキストを並べたデモを作って開く
#   Scripts/run.sh --release             Release 構成でビルドして起動
#   Scripts/run.sh --no-build            ビルドせず、前回の成果物を起動
#
# すでに起動している nanovid は終了させてから開き直す。
#
set -e
cd "$(dirname "$0")/.."

CONFIG=Debug
PROJECT=""
MAKE_DEMO=0
BUILD=1

while [ $# -gt 0 ]; do
    case "$1" in
        --release)  CONFIG=Release ;;
        --debug)    CONFIG=Debug ;;
        --demo)     MAKE_DEMO=1 ;;
        --no-build) BUILD=0 ;;
        -h|--help)
            # 冒頭のコメントをそのまま使い方として出す（行数に依存しないよう読む）。
            awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
            exit 0
            ;;
        -*)
            echo "知らないオプションです: $1" >&2
            exit 2
            ;;
        *)
            PROJECT="$1"
            ;;
    esac
    shift
done

if [ -n "$PROJECT" ] && [ ! -f "$PROJECT" ]; then
    echo "プロジェクトが見つかりません: $PROJECT" >&2
    exit 1
fi

if [ "$BUILD" = 1 ]; then
    echo "ビルド中 ($CONFIG)…"
    LOG=$(mktemp -t nanovid-build)
    if ! xcodebuild -project Nanovid.xcodeproj -scheme Nanovid \
         -configuration "$CONFIG" build >"$LOG" 2>&1; then
        echo "ビルドに失敗しました:" >&2
        grep -E "error:" "$LOG" >&2 || tail -30 "$LOG" >&2
        rm -f "$LOG"
        exit 1
    fi
    rm -f "$LOG"
fi

APP_DIR=$(xcodebuild -project Nanovid.xcodeproj -scheme Nanovid -configuration "$CONFIG" \
          -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{print $2}')
APP="$APP_DIR/Nanovid.app"

if [ ! -d "$APP" ]; then
    echo "アプリが見つかりません: $APP" >&2
    echo "--no-build を外してビルドしてください。" >&2
    exit 1
fi

if [ "$MAKE_DEMO" = 1 ]; then
    DEMO_DIR="${TMPDIR:-/tmp/}nanovid-demo"
    rm -rf "$DEMO_DIR"
    "$APP/Contents/MacOS/Nanovid" --write-demo "$DEMO_DIR" >/dev/null
    PROJECT="$DEMO_DIR/demo.nanovid"
fi

pkill -f "MacOS/Nanovid" 2>/dev/null || true
sleep 1

if [ -n "$PROJECT" ]; then
    # アプリの作業ディレクトリは / なので、絶対パスにして渡す。
    ABS="$(cd "$(dirname "$PROJECT")" && pwd)/$(basename "$PROJECT")"
    echo "起動: $APP"
    echo "開く: $ABS"
    open -n "$APP" --args --open "$ABS"
else
    echo "起動: $APP"
    open -n "$APP"
fi
