#!/bin/sh
#
# App Store 用ビルドに MCP が入っていないことを確かめる。
#
#   Scripts/check-no-mcp.sh path/to/Nanovid.app
#
# App Store 用ビルド（NANOVID_APPSTORE=YES）では、MCP サーバのコード・メニュー・
# 文言・待ち受けの権限（network.server）をコンパイルの段階で落としてある。
# 実行時に隠しているだけになっていないかを、できあがったアプリで見る。
# Scripts/appstore.sh と CI から走る。問題があれば 1 で落ちる。
#
set -e

APP="$1"
if [ -z "$APP" ] || [ ! -d "$APP" ]; then
    echo "使い方: Scripts/check-no-mcp.sh path/to/Nanovid.app" >&2
    exit 2
fi
BIN="$APP/Contents/MacOS/Nanovid"
[ -f "$BIN" ] || { echo "実行ファイルが見つかりません: $BIN" >&2; exit 2; }

PROBLEMS=0
fail() { echo "  ✗ $1" >&2; PROBLEMS=$((PROBLEMS + 1)); }
ok() { echo "  ✓ $1"; }

# 探す文字列。大文字小文字を無視して "mcp" を探すと memcpy や機械語の断片
# （"C0mcplH" など）に当たるので、実際に MCP が使う形に絞る。
#   MCP              型の名前（MCPServer / MCPTools …）、メニューの文言、道具の説明
#   mcpServerEnabled 入切を覚える UserDefaults のキー
#   nanovid.mcp      待ち受けのキューの名前
#   127.0.0.1        待ち受ける先（接続先の URL の組み立てにも出る）
#   tools/call ほか   JSON-RPC のメソッド名
PATTERN='MCP|mcpServerEnabled|nanovid\.mcp|127\.0\.0\.1|tools/call|tools/list|protocolVersion'

# Debug ビルドは中身が Nanovid.debug.dylib に入るので、そちらも見る。
for f in "$APP"/Contents/MacOS/*; do
    name=$(basename "$f")
    HITS=$(strings -a "$f" | grep -E "$PATTERN" | head -5 || true)
    if [ -n "$HITS" ]; then
        fail "$name に MCP の文字列が残っています:"
        echo "$HITS" | sed 's/^/      /' >&2
    else
        ok "$name に MCP の文字列なし"
    fi
    HITS=$(nm "$f" 2>/dev/null | grep -E "$PATTERN" | cut -c 1-160 | head -5 || true)
    if [ -n "$HITS" ]; then
        fail "$name に MCP のシンボルが残っています:"
        echo "$HITS" | sed 's/^/      /' >&2
    else
        ok "$name に MCP のシンボルなし"
    fi
    # 待ち受けに使う Network.framework は MCP だけが使っていた。
    if otool -L "$f" 2>/dev/null | grep -q "Network.framework"; then
        fail "$name が Network.framework をリンクしています"
    else
        ok "$name は Network.framework をリンクしていない"
    fi
done

# 文言の表（MCP.strings）やその他のリソース。名前と中身の両方を見る。
HITS=$(find "$APP/Contents/Resources" -iname "*mcp*" | head -5)
if [ -n "$HITS" ]; then
    fail "MCP のリソースが入っています:"
    echo "$HITS" | sed 's/^/      /' >&2
else
    ok "MCP のリソースなし"
fi
HITS=""
for f in $(find "$APP/Contents/Resources" -name "*.strings" -o -name "*.stringsdict"); do
    if plutil -convert xml1 -o - "$f" 2>/dev/null | grep -qi "mcp"; then HITS="$HITS $f"; fi
done
if [ -n "$HITS" ]; then
    fail "文言の表に MCP が残っています:$HITS"
else
    ok "文言の表に MCP なし"
fi

# 署名していないビルド（CI）では entitlement が無いので、あるときだけ見る。
ENTITLEMENTS=$(codesign -d --entitlements - --xml "$APP" 2>/dev/null || true)
if echo "$ENTITLEMENTS" | grep -q "com.apple.security.network"; then
    fail "ネットワークの entitlement が入っています（MCP の待ち受け用。App Store 用には要らない）"
else
    ok "ネットワークの entitlement なし"
fi

if [ "$PROBLEMS" -gt 0 ]; then
    echo "$PROBLEMS 件の問題があります。" >&2
    exit 1
fi
