#!/bin/sh
#
# nanovid のテストを走らせる。
#
#   Scripts/test.sh                      速い層だけ（関数レベル。既定）
#   Scripts/test.sh --all                重い層（合成・描画・実ファイル）も含めて全部
#   Scripts/test.sh --only HeadlessRenderTests
#                                        スイート（または 1 件）だけ走らせる
#   Scripts/test.sh --release            Release 構成で走らせる
#   Scripts/test.sh --verbose            xcodebuild の出力をそのまま流す
#   Scripts/test.sh --skip-l10n          文言カタログの検査を飛ばす
#
# 速い層は関数レベルのテストだけ。合成を組んで絵を描くもの、実ファイルを
# AVFoundation に読ませるものは重い層に置いてあり、既定では飛ばす（詳しくは
# NanovidTests/TestTiers.swift）。重い層と、性質テストの全部の種は CI が回す。
#
set -e
cd "$(dirname "$0")/.."

CONFIG=Debug
TIER=fast
ONLY=""
VERBOSE=0
L10N=1

while [ $# -gt 0 ]; do
    case "$1" in
        --all)      TIER=all ;;
        --release)  CONFIG=Release ;;
        --debug)    CONFIG=Debug ;;
        --verbose)  VERBOSE=1 ;;
        --skip-l10n) L10N=0 ;;
        --only)
            shift
            if [ $# -eq 0 ]; then
                echo "--only にはスイート名が要ります" >&2
                exit 2
            fi
            ONLY="$1"
            ;;
        -h|--help)
            # 冒頭のコメントをそのまま使い方として出す（行数に依存しないよう読む）。
            awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
            exit 0
            ;;
        *)
            echo "知らないオプションです: $1" >&2
            exit 2
            ;;
    esac
    shift
done

# ビルドより先に文言のずれを見る。L() でくるんだものは Xcode が拾わないので、
# ここで見ないとカタログから落ちたことに誰も気づかない（Scripts/check-localization.py）。
if [ "$L10N" = 1 ]; then
    python3 Scripts/check-localization.py --quiet
fi

set -- test -project Nanovid.xcodeproj -scheme Nanovid -configuration "$CONFIG" \
       -destination "platform=macOS"

if [ -n "$ONLY" ]; then
    set -- "$@" "-only-testing:NanovidTests/$ONLY"
fi

# TEST_RUNNER_ を付けた設定は、テストを動かす側のプロセスの環境変数として入る。
if [ "$TIER" = all ]; then
    set -- "$@" TEST_RUNNER_NANOVID_TESTS=all
    echo "テスト実行中 ($CONFIG・重い層も含む)…"
else
    echo "テスト実行中 ($CONFIG・速い層だけ。全部走らせるなら --all)…"
fi

START=$(date +%s)

if [ "$VERBOSE" = 1 ]; then
    xcodebuild "$@"
    STATUS=0
else
    LOG=$(mktemp -t nanovid-test)
    if xcodebuild "$@" -quiet >"$LOG" 2>&1; then
        STATUS=0
    else
        STATUS=1
        echo "テストに失敗しました:" >&2
        grep -E "error:|✘|failed|Failing tests" "$LOG" >&2 || tail -40 "$LOG" >&2
    fi
    rm -f "$LOG"
fi

echo "$(( $(date +%s) - START )) 秒"
exit $STATUS
