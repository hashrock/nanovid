#!/usr/bin/env swift
//
//  timeline-drag-check.swift — タイムラインのドラッグが実機で 1:1 に追従するか確かめる
//
//  使い方: swift Scripts/timeline-drag-check.swift <Nanovid.app のパス> [作業ディレクトリ]
//         Scripts/timeline-drag-check.sh            ← ビルドから通してやる版
//
//  やっていること:
//    1. アプリにデモプロジェクトを書き出させる
//    2. そのプロジェクトを開いて起動する
//    3. クリップの紫色を手がかりに位置を割り出し、マウス操作を合成してドラッグする
//    4. ⌘S で保存させ、書き戻された .nanovid の数値を期待値と突き合わせる
//
//  ドラッグの座標系はテストでは確かめきれない（.coordinateSpace(.named:) が
//  実際に解決されているかはビューを動かしてみないと分からない）ので、ここで見る。
//
//  必要な許可: 画面収録（クリップの位置を読む）とアクセシビリティ（入力の合成）。
//  実行中は数秒だけマウスカーソルが動く。
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - 設定

/// EditorStore の pixelsPerSecond の初期値。デモを開いた直後はこの倍率になる。
let nominalPPS = 80.0
/// クリップの塗り（ClipView の fill）。この色を手がかりに位置を探す。
let clipFill = (r: 115, g: 84, b: 184)
let bundleID = "com.hashrock.nanovid"

guard CommandLine.arguments.count >= 2 else {
    print("使い方: timeline-drag-check.swift <Nanovid.app のパス> [作業ディレクトリ]")
    exit(2)
}
let appPath = CommandLine.arguments[1]
let workDir = URL(fileURLWithPath: CommandLine.arguments.count > 2
                  ? CommandLine.arguments[2]
                  : NSTemporaryDirectory() + "nanovid-drag-check")
let binary = appPath + "/Contents/MacOS/Nanovid"
let projectURL = workDir.appendingPathComponent("demo.nanovid")

// MARK: - 小道具

@discardableResult
func run(_ path: String, _ args: [String]) -> String {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: path)
    task.arguments = args
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    try? task.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

func fail(_ message: String) -> Never {
    print("NG: \(message)")
    exit(1)
}

struct Window {
    let id: Int
    let rect: CGRect
}

func findWindow(owner: String) -> Window? {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                kCGNullWindowID) as? [[String: Any]] else { return nil }
    for w in list where (w[kCGWindowOwnerName as String] as? String) == owner {
        guard let id = w[kCGWindowNumber as String] as? Int,
              let b = w[kCGWindowBounds as String] as? [String: Any],
              let x = b["X"] as? Double, let y = b["Y"] as? Double,
              let width = b["Width"] as? Double, let height = b["Height"] as? Double,
              width > 400 else { continue }
        return Window(id: id, rect: CGRect(x: x, y: y, width: width, height: height))
    }
    return nil
}

/// ウィンドウを決まった大きさに直す。
///
/// 大きさは前回終了時のものが復元される。狭いままだと末尾のクリップが
/// 画面の端に寄り、ドラッグの行き先がウィンドウの外へ出てしまう。
/// 前提がそろわないまま「追従しない」と言われても原因がわからないので、
/// 測る前にこちらからそろえる。
func resizeWindow(owner: String, to size: CGSize) -> Bool {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.hashrock.nanovid").first
    else { return false }
    let element = AXUIElementCreateApplication(app.processIdentifier)
    var windowsValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windowsValue) == .success,
          let windows = windowsValue as? [AXUIElement], let window = windows.first
    else { return false }

    var origin = CGPoint(x: 60, y: 60)
    var wanted = size
    guard let originValue = AXValueCreate(.cgPoint, &origin),
          let sizeValue = AXValueCreate(.cgSize, &wanted) else { return false }
    AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, originValue)
    AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
    return true
}

func capture(_ window: Window) -> NSBitmapImageRep? {
    let path = NSTemporaryDirectory() + "nanovid-drag-check.png"
    run("/usr/sbin/screencapture", ["-x", "-o", "-l\(window.id)", path])
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return NSBitmapImageRep(data: data)
}

/// 紫のかたまりを左から順に返す。重なって見えるクリップはひとつにまとまる。
func clipRects(_ rep: NSBitmapImageRep) -> [CGRect] {
    let w = rep.pixelsWide, h = rep.pixelsHigh, tolerance = 34
    var columns: [Int: (minY: Int, maxY: Int)] = [:]
    for x in 0..<w {
        for y in stride(from: 0, to: h, by: 2) {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            let r = Int(c.redComponent * 255), g = Int(c.greenComponent * 255)
            let b = Int(c.blueComponent * 255)
            guard abs(r - clipFill.r) < tolerance,
                  abs(g - clipFill.g) < tolerance,
                  abs(b - clipFill.b) < tolerance else { continue }
            let e = columns[x] ?? (y, y)
            columns[x] = (min(e.minY, y), max(e.maxY, y))
        }
    }
    guard !columns.isEmpty else { return [] }
    let xs = columns.keys.sorted()
    var runs: [[Int]] = [[xs[0]]]
    for x in xs.dropFirst() {
        if x - runs[runs.count - 1].last! > 8 { runs.append([x]) } else { runs[runs.count - 1].append(x) }
    }
    return runs.map { run in
        let minY = run.compactMap { columns[$0]?.minY }.min()!
        let maxY = run.compactMap { columns[$0]?.maxY }.max()!
        return CGRect(x: Double(run.first!), y: Double(minY),
                      width: Double(run.last! - run.first!), height: Double(maxY - minY))
    }
}

/// 押されっぱなしの修飾キーとマウスボタンを離す。
///
/// 前回の検証が途中で止まると、ボタンを押したままの状態が残る。
/// その状態で leftMouseDown を送っても何も起きず、ドラッグが 1 度も
/// 効かないまま「追従しない」と報告することになる。
func releaseStuckInput() {
    let src = CGEventSource(stateID: .hidSystemState)
    let clear = CGEvent(keyboardEventSource: src, virtualKey: 55, keyDown: false)
    clear?.type = .flagsChanged
    clear?.flags = []
    clear?.post(tap: .cghidEventTap)
    usleep(50_000)
    for key in [CGKeyCode(55), CGKeyCode(54), CGKeyCode(56), CGKeyCode(60),
                CGKeyCode(58), CGKeyCode(61), CGKeyCode(59)] {
        let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)
        up?.flags = []
        up?.post(tap: .cghidEventTap)
        usleep(20_000)
    }
    let here = CGEvent(source: nil)?.location ?? .zero
    for type: CGEventType in [.leftMouseUp, .rightMouseUp] {
        let e = CGEvent(mouseEventSource: src, mouseType: type,
                        mouseCursorPosition: here, mouseButton: .left)
        e?.flags = []
        e?.post(tap: .cghidEventTap)
        usleep(50_000)
    }
    usleep(200_000)
}

func post(_ type: CGEventType, _ p: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?
        .post(tap: .cghidEventTap)
}

func commandKey(_ code: CGKeyCode) {
    let src = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
    let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
    down?.flags = .maskCommand
    up?.flags = .maskCommand
    down?.post(tap: .cghidEventTap)
    usleep(60_000)
    up?.post(tap: .cghidEventTap)
}

enum GrabSpot {
    case center, leftEdge, rightEdge
}

/// クリップをつかんで横へ動かし、保存まで済ませる。
func drag(clipIndex: Int, seconds: Double, spot: GrabSpot) {
    guard let window = findWindow(owner: "nanovid") else { fail("ウィンドウが見つかりません") }
    guard let rep = capture(window) else { fail("キャプチャできません") }
    let rects = clipRects(rep)
    guard rects.indices.contains(clipIndex) else {
        fail("クリップ \(clipIndex) が見当たりません（見えているのは \(rects.count) 個）")
    }
    let scale = Double(rep.pixelsWide) / window.rect.width
    let rect = rects[clipIndex]
    let grabImageX: Double
    switch spot {
    case .center: grabImageX = rect.midX
    case .leftEdge: grabImageX = rect.minX + 3 * scale
    case .rightEdge: grabImageX = rect.maxX - 3 * scale
    }
    let start = CGPoint(x: window.rect.minX + grabImageX / scale,
                        y: window.rect.minY + rect.midY / scale)
    let distance = seconds * nominalPPS

    NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.activate()
    usleep(400_000)

    post(.mouseMoved, start)
    usleep(120_000)
    post(.leftMouseDown, start)
    usleep(200_000)
    // 細かく刻む。座標系を取り違えていると、ここで位置が暴れたり遅れたりする。
    let steps = 24
    for i in 1...steps {
        post(.leftMouseDragged, CGPoint(x: start.x + distance * Double(i) / Double(steps), y: start.y))
        usleep(25_000)
    }
    usleep(250_000)
    post(.leftMouseUp, CGPoint(x: start.x + distance, y: start.y))
    usleep(400_000)

    commandKey(1)   // ⌘S（開いているファイルへ上書き）
    usleep(700_000)
}

/// 保存された .nanovid からテロップトラックのクリップを読む。
func savedClips() -> [(start: Double, duration: Double)] {
    guard let data = try? Data(contentsOf: projectURL),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let tracks = json["tracks"] as? [[String: Any]] else { fail("プロジェクトを読めません") }
    let clips = tracks.flatMap { ($0["clips"] as? [[String: Any]]) ?? [] }
    return clips.compactMap {
        guard let s = $0["start"] as? Double, let d = $0["duration"] as? Double else { return nil }
        return (s, d)
    }.sorted { $0.start < $1.start }
}

func expect(_ label: String, actual: Double, expected: Double) -> Bool {
    let ok = abs(actual - expected) < 1e-6
    let mark = ok ? "OK" : "NG"
    print(String(format: "  %@ %@: 期待 %.4f / 実測 %.4f", mark, label, expected, actual))
    return ok
}

// MARK: - 本体

print("nanovid タイムラインのドラッグ検証")

releaseStuckInput()
if NSEvent.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty == false {
    print("（修飾キーが押されたままです: \(NSEvent.modifierFlags)）")
}

try? FileManager.default.removeItem(at: workDir)
try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
run(binary, ["--write-demo", workDir.path])
guard FileManager.default.fileExists(atPath: projectURL.path) else {
    fail("デモプロジェクトを作れませんでした（\(binary) は正しい？）")
}

run("/usr/bin/pkill", ["-f", "MacOS/Nanovid"])
sleep(1)
run("/usr/bin/open", ["-n", appPath, "--args", "--open", projectURL.path])

var waited = 0
while findWindow(owner: "nanovid") == nil {
    usleep(500_000)
    waited += 1
    if waited > 30 { fail("ウィンドウが開きません") }
}
sleep(2)

// 前回の大きさが残っていると、末尾のクリップのドラッグ先が窓の外へ出る。
if !resizeWindow(owner: "nanovid", to: CGSize(width: 1400, height: 820)) {
    print("（ウィンドウの大きさを直せませんでした。アクセシビリティの許可を確認してください）")
}
sleep(1)

// 倍率が想定どおりか確認する。ここがずれると以降の期待値が合わなくなる。
// 末尾のクリップは画面外へはみ出して幅が切れるので、先頭のクリップで測る。
if let window = findWindow(owner: "nanovid"), let rep = capture(window) {
    let scale = Double(rep.pixelsWide) / window.rect.width
    let rects = clipRects(rep)
    guard let first = rects.first, rects.count == 4 else {
        fail("デモのクリップ 4 個が見えていません（見えているのは \(rects.count) 個）")
    }
    let measured = (first.width / scale + 2) / 2.4        // 先頭のクリップは 2.4 秒
    if abs(measured - nominalPPS) / nominalPPS > 0.03 {
        fail(String(format: "倍率が想定と違います（実測 %.1f / 想定 %.1f px/秒）。"
                    + "EditorStore.pixelsPerSecond の初期値が変わった？", measured, nominalPPS))
    }
    print(String(format: "倍率 %.1f px/秒", measured))
}

var allOK = true

// デモの並びは [0.0(2.4), 2.8(3.2), 6.4(2.6), 9.6(3.4)]。
// 動かした結果が隣と重なると紫のかたまりが融合して番号がずれるので、右から順に触る。

print("末尾のクリップを +2.0 秒ぶんドラッグ（原点から離れた位置での追従）")
drag(clipIndex: 3, seconds: 2.0, spot: .center)
var clips = savedClips()
allOK = expect("開始", actual: clips.first { abs($0.duration - 3.4) < 1e-9 }?.start ?? -1,
               expected: 11.6) && allOK

print("3 つめの右端を +1.2 秒ぶんドラッグ（長さの調整）")
drag(clipIndex: 2, seconds: 1.2, spot: .rightEdge)
clips = savedClips()
allOK = expect("長さ", actual: clips.first { abs($0.start - 6.4) < 1e-9 }?.duration ?? -1,
               expected: 3.8) && allOK

print("先頭のクリップを +3.0 秒ぶんドラッグ（本体の移動）")
drag(clipIndex: 0, seconds: 3.0, spot: .center)
clips = savedClips()
allOK = expect("開始", actual: clips.first { abs($0.duration - 2.4) < 1e-9 }?.start ?? -1,
               expected: 3.0) && allOK

run("/usr/bin/pkill", ["-f", "MacOS/Nanovid"])

if allOK {
    print("すべて 1:1 で追従しました")
    exit(0)
} else {
    print("追従していない項目があります。ドラッグの座標系を疑うこと。")
    exit(1)
}
