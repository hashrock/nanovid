#!/usr/bin/env swift
//
//  icon-mask.swift — 白地に黒のグリフを、透明地の黒いグリフに直す
//
//  使い方: swift Scripts/icon-mask.swift <入力.png> <出力.png>
//
//  QuickLook は SVG を描くときに透明を白で塗りつぶしてしまうので、
//  明るさから透明度を作り直す。make-appicon.sh から呼ばれる。
//

import AppKit

// <白地に黒の PNG> <出力.png>
// QuickLook は透明を白で塗りつぶすので、明るさから透明度を作り直す。
// 白 → 透明、黒 → 不透明な黒。
let src = CommandLine.arguments[1]
let dst = CommandLine.arguments[2]
guard let data = FileManager.default.contents(atPath: src),
      let rep = NSBitmapImageRep(data: data) else { print("読めません"); exit(1) }

let w = rep.pixelsWide, h = rep.pixelsHigh
guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
      let pixels = ctx.data else { print("描けません"); exit(1) }

let buffer = pixels.bindMemory(to: UInt8.self, capacity: w * h * 4)
for y in 0..<h {
    for x in 0..<w {
        let luminance = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)?.brightnessComponent ?? 1
        let alpha = UInt8(max(0, min(1, 1 - luminance)) * 255)
        let i = (y * w + x) * 4
        buffer[i] = 0; buffer[i + 1] = 0; buffer[i + 2] = 0   // 黒（乗算済み）
        buffer[i + 3] = alpha
    }
}
guard let out = ctx.makeImage() else { print("書けません"); exit(1) }
try! NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: dst))
print(dst)
