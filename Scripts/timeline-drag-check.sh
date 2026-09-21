#!/bin/sh
#
# タイムラインのドラッグを実機で検証する。ビルドから通してやる版。
#
#   Scripts/timeline-drag-check.sh
#
# 数秒だけマウスカーソルが動く。画面収録とアクセシビリティの許可が要る。
#
set -e
cd "$(dirname "$0")/.."

xcodebuild -project Nanovid.xcodeproj -scheme Nanovid -configuration Debug build >/dev/null 2>&1

APP_DIR=$(xcodebuild -project Nanovid.xcodeproj -scheme Nanovid -configuration Debug \
  -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{print $2}')

exec swift Scripts/timeline-drag-check.swift "$APP_DIR/Nanovid.app"
