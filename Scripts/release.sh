#!/bin/sh
#
# 配布用のビルドを作る。
#
#   Scripts/release.sh
#
# Developer ID で署名し、配布用の zip を dist/ に置く。
# 公証（notarization）は Apple への送信になるのでここではやらない。手順は最後に出す。
#
set -e
cd "$(dirname "$0")/.."

OUT=dist
APP_NAME=Nanovid.app
BUILD=build/Build/Products/Release

echo "ビルド中 (Release)…"
LOG=$(mktemp -t nanovid-release)
if ! xcodebuild -project Nanovid.xcodeproj -scheme Nanovid -configuration Release \
     -derivedDataPath build clean build >"$LOG" 2>&1; then
    echo "ビルドに失敗しました:" >&2
    grep -E "error:" "$LOG" >&2 || tail -30 "$LOG" >&2
    rm -f "$LOG"
    exit 1
fi
rm -f "$LOG"

APP="$BUILD/$APP_NAME"
[ -d "$APP" ] || { echo "アプリが見つかりません: $APP" >&2; exit 1; }

echo
echo "署名:"
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E "Authority=Developer ID|Timestamp=|flags=" | sed 's/^/  /'

echo
echo "エンタイトルメント:"
codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -p - | sed 's/^/  /'

# デバッグ用のエンタイトルメントが混ざっていると公証で弾かれる。
if codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q "get-task-allow"; then
    echo >&2
    echo "get-task-allow が入っています。このままでは公証できません。" >&2
    echo "Release の CODE_SIGN_INJECT_BASE_ENTITLEMENTS を確認してください。" >&2
    exit 1
fi

echo
echo "検証:"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/  /'

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
ZIP="$OUT/Nanovid-$VERSION.zip"
mkdir -p "$OUT"
rm -f "$ZIP"
# 公証へ出すときもこの形式で固める。
ditto -c -k --keepParent "$APP" "$ZIP"

echo
echo "できました: $ZIP ($(du -h "$ZIP" | cut -f1))"
echo
echo "配る前に公証しておくと、初回起動の警告が出なくなります:"
echo "  1) 初回だけ資格情報を保存する"
echo "     xcrun notarytool store-credentials nanovid \\"
echo "       --apple-id <Apple ID> --team-id 5WLLZHK49R --password <App 用パスワード>"
echo "  2) 送って待つ"
echo "     xcrun notarytool submit $ZIP --keychain-profile nanovid --wait"
echo "  3) 結果をアプリに焼き付けて、固め直す"
echo "     xcrun stapler staple $APP"
echo "     ditto -c -k --keepParent $APP $ZIP"
