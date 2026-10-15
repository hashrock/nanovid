import Testing
import Foundation
@testable import Nanovid

/// 無音カットの区間の見つけ方。音の大きさの列だけを渡すので、読み込みは挟まない。
struct SilenceDetectionTests {

    private static let loud: Float = 0.3     // おおよそ -10 dBFS
    private static let quiet: Float = 0.001  // -60 dBFS

    /// (大きさ, 秒) の並びを 10 ms 窓の列にする。
    private func levels(_ spans: [(Float, Double)]) -> AudioLevels {
        let window = 0.01
        let rms = spans.flatMap { level, seconds in
            [Float](repeating: level, count: Int((seconds / window).rounded()))
        }
        return AudioLevels(window: window, rms: rms)
    }

    private func close(_ range: ClosedRange<Double>?, _ lower: Double, _ upper: Double) -> Bool {
        guard let range else { return false }
        return abs(range.lowerBound - lower) < 1e-6 && abs(range.upperBound - upper) < 1e-6
    }

    @Test("声に挟まれた無音は、両端に余白を残して返す")
    func paddedBetweenSpeech() {
        let l = levels([(Self.loud, 1), (Self.quiet, 1), (Self.loud, 1)])
        let ranges = SilenceDetection.silentRanges(in: l, options: .standard)
        #expect(ranges.count == 1)
        #expect(close(ranges.first, 1.15, 1.85))
    }

    @Test("頭と尻の無音は、声に接していない側には余白を残さない")
    func edgesAreNotPadded() {
        let l = levels([(Self.quiet, 1), (Self.loud, 1), (Self.quiet, 1)])
        let ranges = SilenceDetection.silentRanges(in: l, options: .standard)
        #expect(ranges.count == 2)
        #expect(close(ranges.first, 0, 0.85))
        #expect(close(ranges.last, 2.15, 3))
    }

    @Test("短い間は残す")
    func shortPausesStay() {
        let l = levels([(Self.loud, 1), (Self.quiet, 0.4), (Self.loud, 1)])
        #expect(SilenceDetection.silentRanges(in: l, options: .standard).isEmpty)
        #expect(SilenceDetection.silentRanges(in: l, options: .tight).count == 1, "詰め気味なら抜く")
    }

    @Test("閾値より大きい音は無音にしない")
    func thresholdIsRespected() {
        let l = levels([(Self.loud, 1), (0.02, 1), (Self.loud, 1)])   // -34 dBFS
        #expect(SilenceDetection.silentRanges(in: l, options: .standard).isEmpty)
        var lenient = SilenceDetection.Options.standard
        lenient.thresholdDB = -30
        #expect(SilenceDetection.silentRanges(in: l, options: lenient).count == 1)
    }

    @Test("無音が無ければ何も返さない")
    func allSpeech() {
        let l = levels([(Self.loud, 3)])
        #expect(SilenceDetection.silentRanges(in: l, options: .tight).isEmpty)
    }

    @Test("窓の列の始まりがずれていれば、そのぶん時刻もずれる")
    func originShiftsRanges() {
        var l = levels([(Self.loud, 1), (Self.quiet, 1), (Self.loud, 1)])
        l.origin = 2
        #expect(close(SilenceDetection.silentRanges(in: l, options: .standard).first, 3.15, 3.85))
    }

    @Test("抜く範囲はフレームにそろい、書き出す範囲の外へは出ない")
    func cutsAreSnappedAndClamped() {
        var project = Project.starter()          // 30 fps
        project.outputRange = OutputRange(start: 0.5, end: 2.5)
        let l = levels([(Self.quiet, 1), (Self.loud, 1), (Self.quiet, 1)])
        var options = SilenceDetection.Options.standard
        options.padding = 0
        let cuts = SilenceDetection.cuts(in: l, options: options, project: project)
        #expect(cuts.count == 2)
        #expect(close(cuts.first, 0.5, 1))
        #expect(close(cuts.last, 2, 2.5))
        for cut in cuts {
            for edge in [cut.lowerBound, cut.upperBound] {
                #expect(abs(project.canvas.snap(edge) - edge) < 1e-9)
            }
        }
    }

    @Test("フレームにそろえてくっついた範囲はひとつにまとめる")
    func touchingCutsMerge() {
        var project = Project.starter()
        project.outputRange = OutputRange(start: 0, end: 10)
        // 余白なしで、ごく短い声に挟まれた無音を 2 つ作る。
        let l = levels([(Self.loud, 1), (Self.quiet, 1), (Self.loud, 0.01), (Self.quiet, 1), (Self.loud, 1)])
        var options = SilenceDetection.Options.standard
        options.padding = 0
        #expect(SilenceDetection.silentRanges(in: l, options: options).count == 2)
        let cuts = SilenceDetection.cuts(in: l, options: options, project: project)
        #expect(cuts.count == 1)
        #expect(close(cuts.first, 1, 3))
    }
}
