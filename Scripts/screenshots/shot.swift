// 指定した PID のウィンドウを 1 枚ずつ撮り（影なし）、位置を JSON に書く。
// 使い方: swift shot.swift <pid> <出力ディレクトリ>
// 出力: <dir>/w<n>.png と <dir>/windows.json（手前から奥の順。bounds は pt）
import AppKit
import CoreGraphics
import Foundation

let pid = Int32(CommandLine.arguments[1])!
let dir = CommandLine.arguments[2]
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] else { exit(1) }
var out: [[String: Any]] = []
var n = 0
for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
    guard let id = w[kCGWindowNumber as String] as? Int,
          let b = w[kCGWindowBounds as String] as? [String: Double],
          (b["Width"] ?? 0) > 40, (b["Height"] ?? 0) > 20,
          (w[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { continue }
    let file = "\(dir)/w\(n).png"
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    task.arguments = ["-x", "-o", "-l\(id)", file]
    try task.run()
    task.waitUntilExit()
    out.append(["file": file, "layer": w[kCGWindowLayer as String] as? Int ?? 0,
                "x": b["X"]!, "y": b["Y"]!, "w": b["Width"]!, "h": b["Height"]!])
    n += 1
}
let data = try JSONSerialization.data(withJSONObject: out, options: .prettyPrinted)
FileManager.default.createFile(atPath: "\(dir)/windows.json", contents: data)
print("\(n) windows")
