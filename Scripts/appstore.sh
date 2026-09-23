#!/bin/sh
#
# Mac App Store に出すパッケージ（.pkg）を作る。
#
#   Scripts/appstore.sh                 Archive して App Store 向けに書き出す
#   Scripts/appstore.sh --archive-only  Archive と検査だけ（Apple とは通信しない）
#
# アップロードはしない。できた .pkg は Transporter で送るか、.xcarchive を
# ダブルクリックして Xcode の Organizer から送る。
#
# 前提（一度だけ）:
#   - Xcode の Settings > Accounts にチーム 5WLLZHK49R のアカウントを入れておく
#   - App Store Connect に Bundle ID com.hashrock.nanovid のアプリを作っておく
# 配布用の証明書（Apple Distribution / Mac Installer Distribution）と
# プロビジョニングプロファイルは、書き出しのときに Xcode が用意する
# （-allowProvisioningUpdates。ここで Apple と通信する）。
#
# Developer ID で直接配るビルドは Scripts/release.sh。Archive は同じ Release 構成で、
# 書き出しのときに App Store 用の署名に掛け直す。
#
set -e
cd "$(dirname "$0")/.."

ARCHIVE_ONLY=0
case "$1" in
    --archive-only) ARCHIVE_ONLY=1 ;;
    "") ;;
    -h|--help)
        awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
        exit 0
        ;;
    *) echo "知らないオプションです: $1" >&2; exit 2 ;;
esac

TEAM=5WLLZHK49R
OUT=dist/appstore
ARCHIVE="$OUT/Nanovid.xcarchive"

# App Store Connect は同じ版の中でビルド番号が増えていないと受け付けない。
# コミット数なら戻らないので、これを使う。未コミットの変更があると
# 同じ番号で中身の違うものができるので、止める。
if [ -n "$(git status --porcelain)" ]; then
    echo "未コミットの変更があります。ビルド番号はコミット数から作るので、先にコミットしてください。" >&2
    exit 1
fi
BUILD=$(git rev-list --count HEAD)

echo "Archive 中 (Release・ビルド番号 $BUILD)…"
rm -rf "$ARCHIVE"
mkdir -p "$OUT"
LOG=$(mktemp -t nanovid-archive)
if ! xcodebuild -project Nanovid.xcodeproj -scheme Nanovid -configuration Release \
     -archivePath "$ARCHIVE" archive CURRENT_PROJECT_VERSION="$BUILD" >"$LOG" 2>&1; then
    echo "Archive に失敗しました:" >&2
    grep -E "error:" "$LOG" >&2 || tail -30 "$LOG" >&2
    rm -f "$LOG"
    exit 1
fi
rm -f "$LOG"

APP="$ARCHIVE/Products/Applications/Nanovid.app"
[ -d "$APP" ] || { echo "アプリが見つかりません: $APP" >&2; exit 1; }

# 審査で落ちる・アップロードで弾かれるものを、送る前に見ておく。
PROBLEMS=0
fail() { echo "  ✗ $1" >&2; PROBLEMS=$((PROBLEMS + 1)); }
ok() { echo "  ✓ $1"; }

echo
echo "検査:"
ENTITLEMENTS=$(codesign -d --entitlements - --xml "$APP" 2>/dev/null)
echo "$ENTITLEMENTS" | grep -q "com.apple.security.app-sandbox" \
    && ok "App Sandbox" || fail "App Sandbox が入っていません（2.4.5(i) で落ちる）"
echo "$ENTITLEMENTS" | grep -q "get-task-allow" \
    && fail "get-task-allow が入っています（デバッグ用。アップロードで弾かれる）" || ok "get-task-allow なし"
[ -f "$APP/Contents/Resources/PrivacyInfo.xcprivacy" ] \
    && ok "Privacy manifest" || fail "PrivacyInfo.xcprivacy が入っていません（ITMS-91053）"
INFO="$APP/Contents/Info.plist"
[ "$(/usr/libexec/PlistBuddy -c 'Print :ITSAppUsesNonExemptEncryption' "$INFO" 2>/dev/null)" = "false" ] \
    && ok "暗号化の申告（使っていない）" || fail "ITSAppUsesNonExemptEncryption がありません"
for key in NSMicrophoneUsageDescription NSSpeechRecognitionUsageDescription LSApplicationCategoryType; do
    /usr/libexec/PlistBuddy -c "Print :$key" "$INFO" >/dev/null 2>&1 \
        && ok "$key" || fail "$key がありません"
done
[ -f "$APP/Contents/Resources/en.lproj/InfoPlist.strings" ] \
    && ok "用途説明の英訳" || fail "InfoPlist.strings（英語）が入っていません"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO")
echo "  版 $VERSION / ビルド $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO")"

if [ "$PROBLEMS" -gt 0 ]; then
    echo >&2
    echo "$PROBLEMS 件の問題があります。直してから出してください。" >&2
    exit 1
fi

if [ "$ARCHIVE_ONLY" = 1 ]; then
    echo
    echo "Archive: $ARCHIVE"
    exit 0
fi

echo
echo "App Store 向けに書き出し中（Apple と通信して署名を用意します）…"
OPTIONS=$(mktemp -t nanovid-export).plist
cat >"$OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>export</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>teamID</key>
    <string>$TEAM</string>
</dict>
</plist>
PLIST
LOG=$(mktemp -t nanovid-export)
if ! xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT" \
     -exportOptionsPlist "$OPTIONS" -allowProvisioningUpdates >"$LOG" 2>&1; then
    echo "書き出しに失敗しました:" >&2
    grep -E "error:|No .* found|requires a provisioning profile" "$LOG" >&2 || tail -30 "$LOG" >&2
    echo >&2
    echo "Xcode の Settings > Accounts にチームのアカウントが入っているか、" >&2
    echo "App Store Connect に com.hashrock.nanovid のアプリがあるかを確認してください。" >&2
    rm -f "$LOG" "$OPTIONS"
    exit 1
fi
rm -f "$LOG" "$OPTIONS"

PKG=$(ls "$OUT"/*.pkg 2>/dev/null | head -1)
echo
echo "できました: $PKG"
echo
echo "送り方（どちらか）:"
echo "  - Transporter.app に $PKG をドラッグする"
echo "  - $ARCHIVE をダブルクリックし、Organizer の Distribute App から送る"
