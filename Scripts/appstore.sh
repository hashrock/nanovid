#!/bin/sh
#
# Mac App Store に出すパッケージ（.pkg）を作る。
#
#   Scripts/appstore.sh --archive-only  Archive と検査だけ
#   Scripts/appstore.sh --adhoc         手順の確認用。ad-hoc 署名のアプリと署名なしの .pkg
#   Scripts/appstore.sh --manual        手元の証明書とプロファイルで署名して .pkg にする
#   Scripts/appstore.sh                 Xcode に証明書とプロファイルを用意させて書き出す
#
# Apple と通信するのは最後の「引数なし」だけ（-allowProvisioningUpdates）。
# ほかの 3 つは手元で完結する（署名にタイムスタンプも付けない）。
# どれもアップロードはしない。できた .pkg は Transporter で送る。
#
# --manual に要るもの（キーチェーンとプロファイル置き場から探す）:
#   - Apple Distribution の証明書（アプリの署名）
#   - Mac Installer Distribution の証明書（.pkg の署名。キーチェーンでの名前は
#     「3rd Party Mac Developer Installer」）
#   - com.hashrock.nanovid の Mac App Store 用プロビジョニングプロファイル
#     （~/Library/Developer/Xcode/UserData/Provisioning Profiles か
#       ~/Library/MobileDevice/Provisioning Profiles。別の場所なら NANOVID_PROFILE で渡す）
#   証明書を名前で決めたいときは NANOVID_APP_IDENTITY / NANOVID_INSTALLER_IDENTITY。
#
# 引数なしに要るもの:
#   - Xcode の Settings > Accounts にチーム 5WLLZHK49R のアカウント
#   - App Store Connect に Bundle ID com.hashrock.nanovid のアプリ
#
# --adhoc は証明書なしで --manual と同じ道を通す。できたアプリ
# （dist/appstore/adhoc/Nanovid.app）は App Store 版と同じ中身・同じ Sandbox で
# 手元で起動できる。書類は open -a で渡す（起動引数ではアクセス権が付かない）。
# 未コミットの変更があっても動く（出すものではないので）。
#
# Developer ID で直接配るビルドは Scripts/release.sh。Archive は同じ Release 構成に
# NANOVID_APPSTORE=YES を足して作り、あとで App Store 用の署名に掛け直す。
#
# NANOVID_APPSTORE=YES は「App Store 用ビルド」の切り替え。AI から操作するための
# MCP サーバ（コード・メニュー・文言・待ち受けの権限 network.server）をコンパイルの
# 段階で落とす。Xcode の Product > Archive はこの切り替えが入らず MCP 入りに
# なるので、App Store に出すものは必ずこのスクリプトで作る。
#
set -e
cd "$(dirname "$0")/.."

MODE=export
case "$1" in
    --archive-only) MODE=archive ;;
    --adhoc) MODE=adhoc ;;
    --manual) MODE=manual ;;
    "") ;;
    -h|--help)
        awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
        exit 0
        ;;
    *) echo "知らないオプションです: $1" >&2; exit 2 ;;
esac

TEAM=5WLLZHK49R
BUNDLE_ID=com.hashrock.nanovid
OUT=dist/appstore
ARCHIVE="$OUT/Nanovid.xcarchive"

# App Store Connect は同じ版の中でビルド番号が増えていないと受け付けない。
# コミット数なら戻らないので、これを使う。未コミットの変更があると
# 同じ番号で中身の違うものができるので、止める。
if [ "$MODE" != adhoc ] && [ -n "$(git status --porcelain)" ]; then
    echo "未コミットの変更があります。ビルド番号はコミット数から作るので、先にコミットしてください。" >&2
    exit 1
fi
BUILD=$(git rev-list --count HEAD)

PROBLEMS=0
fail() { echo "  ✗ $1" >&2; PROBLEMS=$((PROBLEMS + 1)); }
ok() { echo "  ✓ $1"; }
plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null; }

# 審査で落ちる・アップロードで弾かれるものを、送る前に見ておく。
check_app() {
    APP_TO_CHECK="$1"
    ENTITLEMENTS=$(codesign -d --entitlements - --xml "$APP_TO_CHECK" 2>/dev/null | plutil -convert xml1 -o - - 2>/dev/null || true)
    echo "$ENTITLEMENTS" | grep -q "com.apple.security.app-sandbox" \
        && ok "App Sandbox" || fail "App Sandbox が入っていません（2.4.5(i) で落ちる）"
    echo "$ENTITLEMENTS" | grep -q "get-task-allow" \
        && fail "get-task-allow が入っています（デバッグ用。アップロードで弾かれる）" || ok "get-task-allow なし"
    # 権限は「要るものだけ」。増えたら、審査メモに用途を書いてからここに足す。
    EXTRA=$(echo "$ENTITLEMENTS" | sed -n 's/.*<key>\(.*\)<\/key>.*/\1/p' | grep -v -x \
        -e com.apple.security.app-sandbox \
        -e com.apple.security.files.user-selected.read-write \
        -e com.apple.security.files.bookmarks.app-scope \
        -e com.apple.security.device.audio-input \
        -e com.apple.application-identifier \
        -e com.apple.developer.team-identifier || true)
    [ -z "$EXTRA" ] && ok "権限は決めた 4 つだけ" \
        || fail "決めていない権限が入っています: $(echo $EXTRA)"
    [ -f "$APP_TO_CHECK/Contents/Resources/PrivacyInfo.xcprivacy" ] \
        && ok "Privacy manifest" || fail "PrivacyInfo.xcprivacy が入っていません（ITMS-91053）"
    INFO="$APP_TO_CHECK/Contents/Info.plist"
    [ "$(plist "$INFO" CFBundleIdentifier)" = "$BUNDLE_ID" ] \
        && ok "Bundle ID $BUNDLE_ID" || fail "Bundle ID が $BUNDLE_ID ではありません"
    [ "$(plist "$INFO" ITSAppUsesNonExemptEncryption)" = "false" ] \
        && ok "暗号化の申告（使っていない）" || fail "ITSAppUsesNonExemptEncryption がありません"
    for key in NSMicrophoneUsageDescription NSSpeechRecognitionUsageDescription \
               LSApplicationCategoryType LSMinimumSystemVersion CFBundleIconName; do
        plist "$INFO" "$key" >/dev/null && ok "$key" || fail "$key がありません"
    done
    [ -f "$APP_TO_CHECK/Contents/Resources/Assets.car" ] && [ -f "$APP_TO_CHECK/Contents/Resources/AppIcon.icns" ] \
        && ok "アイコン（asset catalog と icns）" || fail "アイコンが入っていません（Assets.car / AppIcon.icns）"
    [ -f "$APP_TO_CHECK/Contents/Resources/en.lproj/InfoPlist.strings" ] \
        && ok "用途説明の英訳" || fail "InfoPlist.strings（英語）が入っていません"
    # MCP が入っていないこと（文字列・シンボル・文言の表・待ち受けの権限）。
    Scripts/check-no-mcp.sh "$APP_TO_CHECK" || PROBLEMS=$((PROBLEMS + 1))
    echo "  版 $(plist "$INFO" CFBundleShortVersionString) / ビルド $(plist "$INFO" CFBundleVersion)"
}

stop_if_problems() {
    if [ "$PROBLEMS" -gt 0 ]; then
        echo >&2
        echo "$PROBLEMS 件の問題があります。直してから出してください。" >&2
        exit 1
    fi
}

echo "Archive 中 (Release・App Store 用・ビルド番号 $BUILD)…"
rm -rf "$ARCHIVE"
mkdir -p "$OUT"
LOG=$(mktemp -t nanovid-archive)
# Release の署名は Developer ID + --timestamp（Apple のタイムスタンプサーバに問い合わせる）。
# ここで作るものはあとで署名を掛け直すので、タイムスタンプは付けない。
# --adhoc は Developer ID の証明書も使わない。
if [ "$MODE" = adhoc ]; then
    set -- CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
else
    set --
fi
if ! xcodebuild -project Nanovid.xcodeproj -scheme Nanovid -configuration Release \
     -archivePath "$ARCHIVE" archive CURRENT_PROJECT_VERSION="$BUILD" \
     NANOVID_APPSTORE=YES OTHER_CODE_SIGN_FLAGS=--timestamp=none "$@" >"$LOG" 2>&1; then
    echo "Archive に失敗しました:" >&2
    grep -E "error:" "$LOG" >&2 || tail -30 "$LOG" >&2
    rm -f "$LOG"
    exit 1
fi
rm -f "$LOG"

APP="$ARCHIVE/Products/Applications/Nanovid.app"
[ -d "$APP" ] || { echo "アプリが見つかりません: $APP" >&2; exit 1; }

echo
echo "検査（Archive）:"
check_app "$APP"
stop_if_problems

if [ "$MODE" = archive ]; then
    echo
    echo "Archive: $ARCHIVE"
    exit 0
fi

# ---------------------------------------------------------------------------
# 手元の証明書で署名して .pkg にする（--manual）。--adhoc は同じ道を証明書なしで通す。
# ---------------------------------------------------------------------------
if [ "$MODE" = manual ] || [ "$MODE" = adhoc ]; then
    # キーチェーンから、名前がこの頭で始まる署名用の証明書を 1 つ探す（"名前" を返す）。
    find_identity() {
        security find-identity -v 2>/dev/null | sed -n "s/^ *[0-9]*) [0-9A-F]* \"\\($1[^\"]*\\)\"\$/\\1/p" | head -1
    }
    # プロファイルを読む。$1 = ファイル、$2 = キーのパス。
    profile_value() {
        security cms -D -i "$1" 2>/dev/null | plutil -extract "$2" raw -o - - 2>/dev/null
    }
    # com.hashrock.nanovid の Mac App Store 用プロファイルを探す。
    # 端末の一覧（ProvisionedDevices）があるものは開発用なので除く。期限切れも除く。
    find_profile() {
        NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        for f in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"/*.provisionprofile \
                 "$HOME/Library/MobileDevice/Provisioning Profiles"/*.provisionprofile; do
            [ -f "$f" ] || continue
            [ "$(profile_value "$f" 'Entitlements.com\.apple\.application-identifier')" = "$TEAM.$BUNDLE_ID" ] || continue
            profile_value "$f" ProvisionedDevices >/dev/null && continue
            [ "$(profile_value "$f" ProvisionsAllDevices)" = true ] && continue
            EXPIRES=$(profile_value "$f" ExpirationDate)
            [ "$EXPIRES" \> "$NOW" ] || continue
            echo "$f"
            return 0
        done
        return 1
    }

    if [ "$MODE" = adhoc ]; then
        STAGE="$OUT/adhoc"
        APP_IDENTITY=-
        INSTALLER_IDENTITY=
        PROFILE=
        PKG="$STAGE/Nanovid-adhoc.pkg"
    else
        STAGE="$OUT/manual"
        MISSING=0
        APP_IDENTITY=${NANOVID_APP_IDENTITY:-$(find_identity "Apple Distribution")}
        [ -n "$APP_IDENTITY" ] || APP_IDENTITY=$(find_identity "3rd Party Mac Developer Application")
        INSTALLER_IDENTITY=${NANOVID_INSTALLER_IDENTITY:-$(find_identity "3rd Party Mac Developer Installer")}
        [ -n "$INSTALLER_IDENTITY" ] || INSTALLER_IDENTITY=$(find_identity "Mac Installer Distribution")
        PROFILE=${NANOVID_PROFILE:-$(find_profile || true)}
        echo
        echo "署名に使うもの:"
        if [ -n "$APP_IDENTITY" ]; then ok "アプリの署名: $APP_IDENTITY"
        else fail "Apple Distribution の証明書がキーチェーンにありません"; MISSING=1; fi
        if [ -n "$INSTALLER_IDENTITY" ]; then ok ".pkg の署名: $INSTALLER_IDENTITY"
        else fail "Mac Installer Distribution（3rd Party Mac Developer Installer）の証明書がキーチェーンにありません"; MISSING=1; fi
        if [ -n "$PROFILE" ] && [ -f "$PROFILE" ]; then ok "プロファイル: $(profile_value "$PROFILE" Name)（$(profile_value "$PROFILE" ExpirationDate) まで）"
        else fail "$BUNDLE_ID の Mac App Store 用プロビジョニングプロファイルがありません"; MISSING=1; fi
        # プロファイルは、作るときに選んだ証明書でしか使えない。違う証明書で署名すると
        # アップロードで弾かれるので、ここで見ておく。
        if [ "$MISSING" = 0 ]; then
            IDENTITY_HASH=$(security find-identity -v | sed -n "s/^ *[0-9]*) \\([0-9A-F]*\\) \"$APP_IDENTITY\"\$/\\1/p" | head -1)
            FOUND=0
            N=0
            while CERT=$(profile_value "$PROFILE" "DeveloperCertificates.$N"); do
                HASH=$(echo "$CERT" | base64 -d | shasum -a 1 | cut -d' ' -f1 | tr a-f A-F)
                [ "$HASH" = "$IDENTITY_HASH" ] && FOUND=1
                N=$((N + 1))
            done
            if [ "$FOUND" = 1 ]; then ok "プロファイルはこの証明書のもの"
            else fail "プロファイルに、この証明書が入っていません（Xcode が作ったプロファイルは Xcode 管理の証明書用。この証明書を選んでプロファイルを作り直す）"; MISSING=1; fi
        fi
        if [ "$MISSING" = 1 ]; then
            cat >&2 <<HELP

証明書とプロファイルは Apple Developer のサイトで作る（Apple と通信する手順）。
  1. キーチェーンアクセス > 証明書アシスタント > 認証局に証明書を要求… で CSR を作る
  2. https://developer.apple.com/account/resources/certificates/add で
     「Apple Distribution」と「Mac Installer Distribution」を作り、ダウンロードして開く
  3. https://developer.apple.com/account/resources/profiles/add で
     Distribution > Mac App Store Connect、App ID $BUNDLE_ID、2 の Apple Distribution を選んで作り、
     ダウンロードして NANOVID_PROFILE=<パス> で渡す（ダブルクリックで入れてもよい）
Xcode に任せるなら、引数なしの Scripts/appstore.sh。
Archive は検査を通っています: $ARCHIVE
HELP
            exit 1
        fi
        PKG="$STAGE/Nanovid-$(plist "$APP/Contents/Info.plist" CFBundleShortVersionString)-$BUILD.pkg"
    fi

    rm -rf "$STAGE"
    mkdir -p "$STAGE"
    SIGNED="$STAGE/Nanovid.app"
    ditto "$APP" "$SIGNED"

    # 権限は Archive のものをそのまま引き継ぎ、App Store 用の署名に要る 2 つを足す。
    # ad-hoc 署名でこの 2 つを付けると起動を止められるので、--adhoc では足さない。
    SIGN_ENTITLEMENTS=$(mktemp -t nanovid-entitlements).plist
    codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -convert xml1 -o "$SIGN_ENTITLEMENTS" -
    if [ "$MODE" = manual ]; then
        /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $TEAM.$BUNDLE_ID" \
            -c "Add :com.apple.developer.team-identifier string $TEAM" "$SIGN_ENTITLEMENTS" >/dev/null
        cp "$PROFILE" "$SIGNED/Contents/embedded.provisionprofile"
    fi
    # ダウンロードしたプロファイルに付く com.apple.quarantine が残っていると、
    # アップロードで弾かれる（ITMS-91109）。
    xattr -cr "$SIGNED"

    echo
    echo "署名中…"
    codesign --force --options runtime --timestamp=none --generate-entitlement-der \
        --entitlements "$SIGN_ENTITLEMENTS" --sign "$APP_IDENTITY" "$SIGNED"
    rm -f "$SIGN_ENTITLEMENTS"
    codesign --verify --strict --deep "$SIGNED"

    echo
    echo "検査（署名し直したアプリ）:"
    check_app "$SIGNED"
    if [ "$MODE" = manual ]; then
        SIGNED_ENTITLEMENTS=$(codesign -d --entitlements - --xml "$SIGNED" 2>/dev/null | plutil -convert xml1 -o - -)
        echo "$SIGNED_ENTITLEMENTS" | grep -q "<string>$TEAM.$BUNDLE_ID</string>" \
            && ok "application-identifier $TEAM.$BUNDLE_ID" || fail "application-identifier が入っていません"
        [ "$(profile_value "$SIGNED/Contents/embedded.provisionprofile" 'Entitlements.com\.apple\.application-identifier')" = "$TEAM.$BUNDLE_ID" ] \
            && ok "プロファイルを埋め込んだ" || fail "埋め込んだプロファイルの App ID が合いません"
        codesign -dvv "$SIGNED" 2>&1 | grep -q "^Authority=\(Apple Distribution\|3rd Party Mac Developer Application\)" \
            && ok "配布用の証明書で署名" || fail "配布用の証明書で署名されていません"
    fi
    stop_if_problems

    echo
    echo ".pkg を作成中…"
    if [ -n "$INSTALLER_IDENTITY" ]; then
        productbuild --component "$SIGNED" /Applications --sign "$INSTALLER_IDENTITY" --timestamp=none "$PKG" >/dev/null
        pkgutil --check-signature "$PKG" | sed -n '1,6p'
    else
        productbuild --component "$SIGNED" /Applications "$PKG" >/dev/null
    fi
    pkgutil --payload-files "$PKG" | grep -q "Nanovid.app/Contents/MacOS/Nanovid" \
        || { echo ".pkg にアプリが入っていません" >&2; exit 1; }

    echo
    if [ "$MODE" = adhoc ]; then
        echo "できました（確認用。App Store には出せません）:"
        echo "  アプリ: $SIGNED"
        echo "  .pkg:   $PKG"
        echo
        echo "Sandbox の下で試す:"
        echo "  open -n -a \"$PWD/$SIGNED\" <書類.nanovid>"
    else
        echo "できました: $PKG"
        echo
        echo "送り方: Transporter.app に $PKG をドラッグして「配信」"
    fi
    exit 0
fi

# ---------------------------------------------------------------------------
# Xcode に証明書とプロファイルを用意させて書き出す（Apple と通信する）。
# ---------------------------------------------------------------------------
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
    echo "App Store Connect に $BUNDLE_ID のアプリがあるかを確認してください。" >&2
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
