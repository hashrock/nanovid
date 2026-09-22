import Testing
import Foundation
@testable import Nanovid

/// 書き起こしを字幕に割る処理。
struct SubtitleSegmentationPropertyTests {

    /// それらしい語の並びを作る。文末・読点・無音の間を混ぜる。
    private func words(seed: Int) -> (words: [TranscribedWord], options: SubtitleSegmentation.Options) {
        var g = SeededGenerator(seed: UInt64(seed) &+ 0x5AB7)
        let pieces = ["これは", "テストの", "文です", "。", "ところで", "、", "長い",
                      "ナレーションを", "区切る", "ときに", "使います", "！",
                      "hello ", "world ", "this is ", "a test. "]
        var result: [TranscribedWord] = []
        var cursor = g.double(in: 0...2)
        for _ in 0..<g.int(in: 1...40) {
            let duration = g.double(in: 0.08...1.2)
            result.append(TranscribedWord(text: g.pick(pieces), start: cursor, end: cursor + duration))
            // ときどき間を空ける。無音で区切る経路を通すため。
            cursor += duration + (g.chance(0.25) ? g.double(in: 0.4...1.5) : g.double(in: 0...0.2))
        }
        let options = SubtitleSegmentation.Options(
            pauseThreshold: g.double(in: 0.2...0.8),
            maxCharacters: g.int(in: 6...40),
            minDuration: g.double(in: 0.2...1.0),
            maxDuration: g.double(in: 2.0...8.0))
        return (result, options)
    }

    private func squashed(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).joined()
    }

    @Test("語は過不足なく、順番どおりに出てくる", arguments: PropertyRuns.seeds(300))
    func everyWordAppearsOnceInOrder(seed: Int) {
        let (input, options) = words(seed: seed)
        let lines = SubtitleSegmentation.lines(from: input, options: options)
        let want = squashed(input.map(\.text).joined())
        let got = squashed(lines.map(\.text).joined())
        #expect(got == want, """
            seed \(seed): 中身が変わった
            もと: \(want)
            字幕: \(got)
            """)
    }

    @Test("字幕は時刻順に並び、重ならない", arguments: PropertyRuns.seeds(300))
    func linesAreOrderedAndDoNotOverlap(seed: Int) {
        let (input, options) = words(seed: seed)
        let lines = SubtitleSegmentation.lines(from: input, options: options)
        for i in 0..<max(0, lines.count - 1) {
            #expect(lines[i].start <= lines[i + 1].start + 1e-9,
                    "seed \(seed): \(i) 番目と \(i + 1) 番目の開始が逆")
            #expect(lines[i].end <= lines[i + 1].start + 1e-9,
                    "seed \(seed): \(i) 番目 (〜\(lines[i].end)) が次 (\(lines[i + 1].start)〜) に重なる")
        }
    }

    @Test("字幕の時間は元の語の範囲に収まる", arguments: PropertyRuns.seeds(300))
    func linesStayInsideTheTranscript(seed: Int) {
        let (input, options) = words(seed: seed)
        let lines = SubtitleSegmentation.lines(from: input, options: options)
        guard let first = input.map(\.start).min(), let last = input.map(\.end).max() else { return }
        for line in lines {
            #expect(line.start >= first - 1e-9, "seed \(seed): 書き起こしより前から始まっている")
            // 最後の 1 枚だけは、短すぎると読めないので minDuration まで伸ばす。
            // そのぶんは語の終わりを越えてよい。
            #expect(line.end <= last + options.minDuration + 1e-9,
                    "seed \(seed): 書き起こしより \(line.end - last) 秒も後ろまで伸びている")
            #expect(line.duration >= 0)
        }
    }

    @Test("空の字幕は作らない", arguments: PropertyRuns.seeds(300))
    func noEmptyLines(seed: Int) {
        let (input, options) = words(seed: seed)
        for line in SubtitleSegmentation.lines(from: input, options: options) {
            #expect(!line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @Test("文字数の上限を大きく超えない", arguments: PropertyRuns.seeds(300))
    func linesStayNearTheCharacterLimit(seed: Int) {
        let (input, options) = words(seed: seed)
        let lines = SubtitleSegmentation.lines(from: input, options: options)
        // 語の途中では切らないので、最後の 1 語ぶんは超えうる。
        let longestWord = input.map { squashed($0.text).count }.max() ?? 0
        for line in lines {
            #expect(line.text.count <= options.maxCharacters + longestWord, """
                seed \(seed): 「\(line.text)」が \(line.text.count) 文字
                上限 \(options.maxCharacters) ＋ 最長の語 \(longestWord)
                """)
        }
    }

    @Test("空白だけの語しか無ければ字幕は作らない", arguments: PropertyRuns.seeds(50))
    func blankTranscriptProducesNothing(seed: Int) {
        var g = SeededGenerator(seed: UInt64(seed) &+ 0x0B1A)
        let blanks = (0..<g.int(in: 1...8)).map { i in
            TranscribedWord(text: ["", " ", "\n", "  "][g.int(in: 0...3)],
                            start: Double(i), end: Double(i) + 0.5)
        }
        #expect(SubtitleSegmentation.lines(from: blanks).isEmpty)
    }

    @Test("語の並びが前後していても時刻順に直してから割る", arguments: PropertyRuns.seeds(100))
    func shuffledInputIsSortedFirst(seed: Int) {
        let (input, options) = words(seed: seed)
        var shuffled = input
        var g = SeededGenerator(seed: UInt64(seed) &+ 0x5FFF)
        for i in shuffled.indices.reversed() where i > 0 {
            shuffled.swapAt(i, g.int(in: 0...i))
        }
        let a = SubtitleSegmentation.lines(from: input, options: options)
        let b = SubtitleSegmentation.lines(from: shuffled, options: options)
        #expect(a == b, "seed \(seed): 並び順で結果が変わる")
    }
}
