import CoreGraphics
import CoreMedia
import Foundation

// MARK: - 時間

/// このプロジェクトでは時間はすべて「秒(Double)」で保持する。
/// 編集操作の時点でフレーム境界にスナップするので、CMTime への変換は常に正確になる。
enum TimeScale {
    /// 30fps / 60fps いずれも割り切れる基準タイムスケール。
    static let preferred: CMTimeScale = 600
}

extension Double {
    var cmTime: CMTime { CMTime(seconds: self, preferredTimescale: TimeScale.preferred) }
}

extension CMTime {
    var secondsOrZero: Double { isNumeric ? CMTimeGetSeconds(self) : 0 }
}

// MARK: - キャンバス

struct CanvasPreset: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let size: CGSize

    static let youtubeHD = CanvasPreset(name: "YouTube HD (1920×1080)", size: CGSize(width: 1920, height: 1080))
    static let youtube4K = CanvasPreset(name: "YouTube 4K (3840×2160)", size: CGSize(width: 3840, height: 2160))
    static let youtubeShort = CanvasPreset(name: "YouTube Short (1080×1920)", size: CGSize(width: 1080, height: 1920))
    static let hd720 = CanvasPreset(name: "HD 720p (1280×720)", size: CGSize(width: 1280, height: 720))
    static let square = CanvasPreset(name: "Square (1080×1080)", size: CGSize(width: 1080, height: 1080))

    static let all: [CanvasPreset] = [.youtubeHD, .youtubeShort, .hd720, .square, .youtube4K]
}

struct CanvasSpec: Codable, Hashable {
    var width: Int
    var height: Int
    var fps: Int
    var backgroundColor: RGBAColor

    init(width: Int = 1920, height: Int = 1080, fps: Int = 30, backgroundColor: RGBAColor = .black) {
        self.width = width
        self.height = height
        self.fps = fps
        self.backgroundColor = backgroundColor
    }

    var size: CGSize { CGSize(width: width, height: height) }
    var frameDuration: Double { 1.0 / Double(fps) }
    var aspectRatio: Double { Double(width) / Double(height) }

    /// 時刻をフレーム境界へスナップする。
    func snap(_ seconds: Double) -> Double {
        (seconds * Double(fps)).rounded() / Double(fps)
    }

    func frameIndex(at seconds: Double) -> Int {
        Int((seconds * Double(fps)).rounded())
    }
}

// MARK: - 色

struct RGBAColor: Codable, Hashable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    static let black = RGBAColor(r: 0, g: 0, b: 0, a: 1)
    static let white = RGBAColor(r: 1, g: 1, b: 1, a: 1)
    static let clear = RGBAColor(r: 0, g: 0, b: 0, a: 0)

    var cgColor: CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    /// "#RRGGBB" / "#RRGGBBAA" を受け付ける。
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard let v = UInt64(s, radix: 16) else { return nil }
        switch s.count {
        case 6:
            self.init(r: Double((v >> 16) & 0xFF) / 255,
                      g: Double((v >> 8) & 0xFF) / 255,
                      b: Double(v & 0xFF) / 255,
                      a: 1)
        case 8:
            self.init(r: Double((v >> 24) & 0xFF) / 255,
                      g: Double((v >> 16) & 0xFF) / 255,
                      b: Double((v >> 8) & 0xFF) / 255,
                      a: Double(v & 0xFF) / 255)
        default:
            return nil
        }
    }

    var hexString: String {
        let ri = Int((r * 255).rounded()), gi = Int((g * 255).rounded())
        let bi = Int((b * 255).rounded()), ai = Int((a * 255).rounded())
        return ai == 255
            ? String(format: "#%02X%02X%02X", ri, gi, bi)
            : String(format: "#%02X%02X%02X%02X", ri, gi, bi, ai)
    }
}

// MARK: - 変形

/// キャンバスに対する相対変形。position はキャンバス中心を原点とした正規化座標
/// (x: 幅の割合, y: 高さの割合) なので、解像度プリセットを切り替えてもレイアウトが保たれる。
struct Transform2D: Codable, Hashable {
    var position: CGPoint = .zero
    var scale: Double = 1
    var rotation: Double = 0

    static let identity = Transform2D()
}

// MARK: - フェード

struct Fade: Codable, Hashable {
    var inDuration: Double = 0
    var outDuration: Double = 0

    static let none = Fade()

    /// クリップ内相対時刻 t における不透明度係数。
    func factor(at t: Double, clipDuration: Double) -> Double {
        var f = 1.0
        if inDuration > 0, t < inDuration {
            f *= max(0, min(1, t / inDuration))
        }
        if outDuration > 0 {
            let remaining = clipDuration - t
            if remaining < outDuration {
                f *= max(0, min(1, remaining / outDuration))
            }
        }
        return f
    }
}
