#!/usr/bin/env swift
//
//  window-shot.swift — 指定したアプリのウィンドウだけを撮る
//
//  使い方: swift Scripts/window-shot.swift <アプリ名> <出力.png>
//  例:     swift Scripts/window-shot.swift nanovid /tmp/shot.png
//
//  画面全体ではなくウィンドウ単体を狙うので、他のアプリは写らない。
//  システム設定 > プライバシーとセキュリティ > 画面収録 で、このスクリプトを
//  実行するターミナルに許可が要る。許可が無いと他アプリのウィンドウが
//  一覧に出てこないため "window not found" になる。
//

import AppKit
import CoreGraphics
import Foundation

guard CommandLine.arguments.count >= 3 else {
    print("使い方: window-shot.swift <アプリ名> <出力.png>")
    exit(2)
}
let owner = CommandLine.arguments[1]
let out = CommandLine.arguments[2]

guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                            kCGNullWindowID) as? [[String: Any]] else {
    print("ウィンドウ一覧を取得できませんでした")
    exit(1)
}

func width(_ w: [String: Any]) -> Double {
    (w[kCGWindowBounds as String] as? [String: Any])?["Width"] as? Double ?? 0
}

// 同じアプリに複数あるときは、いちばん大きいものを本体とみなす。
let matches = list
    .filter { ($0[kCGWindowOwnerName as String] as? String) == owner }
    .sorted { width($0) > width($1) }

guard let window = matches.first, let id = window[kCGWindowNumber as String] as? Int else {
    let owners = Set(list.compactMap { $0[kCGWindowOwnerName as String] as? String }).sorted()
    print("\(owner) のウィンドウが見つかりません。見えているアプリ: \(owners.joined(separator: ", "))")
    print("画面収録の許可が無いと、他アプリのウィンドウは一覧に出てきません。")
    exit(1)
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
task.arguments = ["-x", "-o", "-l\(id)", out]
try task.run()
task.waitUntilExit()

guard task.terminationStatus == 0 else {
    print("キャプチャに失敗しました")
    exit(1)
}
print(out)
