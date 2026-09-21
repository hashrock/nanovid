import Testing
import Foundation
@testable import Nanovid

/// 書き起こしを字幕の枚数に割るところ。
struct SubtitleSegmentationTests {

    private func word(_ text: String, _ start: Double, _ end: Double) -> TranscribedWord {
        TranscribedWord(text: text, start: start, end: end)
    }

    @Test("無音で区切る")
    func splitsOnPause() {
        let words = [
            word("今回は", 0.0, 0.6),
            word("nanovid の話", 0.6, 1.4),
            // ここで 0.8 秒あく
            word("まずは", 2.2, 2.8),
            word("タイムライン", 2.8, 3.4),
        ]
        let lines = SubtitleSegmentation.lines(from: words)
        #expect(lines.count == 2)
        #expect(lines[0].text == "今回はnanovid の話")
        #expect(lines[1].text == "まずはタイムライン")
        #expect(abs(lines[1].start - 2.2) < 1e-9)
    }

    @Test("無音が閾値に満たなければ続ける")
    func keepsGoingBelowThreshold() {
        let words = [
            word("あいう", 0.0, 0.5),
            word("えお", 0.7, 1.2),          // 空き 0.2 秒
        ]
        let lines = SubtitleSegmentation.lines(from: words)
        #expect(lines.count == 1)
        #expect(lines[0].text == "あいうえお")
    }

    @Test("文字数の上限を超えたら割る")
    func splitsOnLength() {
        var options = SubtitleSegmentation.Options.default
        options.maxCharacters = 6
        let words = (0..<5).map { i in
            word("あいう", Double(i) * 0.3, Double(i) * 0.3 + 0.3)
        }
        let lines = SubtitleSegmentation.lines(from: words, options: options)
        #expect(lines.allSatisfy { $0.text.count <= 6 })
        #expect(lines.count == 3)      // 15 文字 ÷ 6 文字
    }

    @Test("長く出しっぱなしにしない")
    func splitsOnDuration() {
        var options = SubtitleSegmentation.Options.default
        options.maxDuration = 2.0
        options.maxCharacters = 999
        let words = (0..<6).map { i in
            word("あ", Double(i), Double(i) + 0.9)     // 空きは 0.1 秒
        }
        let lines = SubtitleSegmentation.lines(from: words, options: options)
        #expect(lines.allSatisfy { $0.duration <= options.maxDuration + 1e-9 })
        #expect(lines.count > 1)
    }

    @Test("文の終わりで区切る")
    func splitsOnSentenceEnd() {
        // 間は無いが句点がある。合成音声や早口だと間が出ないので、句読点が頼りになる。
        let words = [
            word("これは一文目です。", 0.0, 1.0),
            word("これが二文目", 1.05, 1.9),
        ]
        let lines = SubtitleSegmentation.lines(from: words)
        #expect(lines.count == 2)
        #expect(lines[0].text == "これは一文目です。")
        #expect(lines[1].text == "これが二文目")
    }

    @Test("長い文は均等に割る")
    func splitsEvenly() {
        var options = SubtitleSegmentation.Options.default
        options.maxCharacters = 20
        // 24 文字ぶんをひと続きで渡す。前から 20 文字で切ると 4 文字の端数が出る。
        let words = (0..<12).map { i in
            word("あい", Double(i) * 0.2, Double(i) * 0.2 + 0.2)
        }
        let lines = SubtitleSegmentation.lines(from: words, options: options)
        #expect(lines.count == 2)
        let lengths = lines.map(\.text.count)
        #expect(lengths.allSatisfy { $0 <= 20 })
        #expect(abs(lengths[0] - lengths[1]) <= 2, "偏らない: \(lengths)")
    }

    @Test("割るときは読点を優先する")
    func prefersClauseBreaks() {
        var options = SubtitleSegmentation.Options.default
        options.maxCharacters = 12
        let words = [
            word("まずはこれ、", 0.0, 0.8),
            word("つぎにこれ", 0.85, 1.6),
            word("をやります", 1.65, 2.4),
        ]
        let lines = SubtitleSegmentation.lines(from: words, options: options)
        #expect(lines.first?.text == "まずはこれ、", "読点で切れている")
    }

    @Test("短すぎる字幕は読める長さまで伸ばす")
    func stretchesShortLines() {
        let words = [word("はい", 0.0, 0.2)]
        let lines = SubtitleSegmentation.lines(from: words)
        #expect(lines.count == 1)
        #expect(abs(lines[0].duration - 0.6) < 1e-9)
    }

    @Test("伸ばしても次の字幕にはぶつけない")
    func stretchDoesNotOverlapNext() {
        // 空き 0.4 秒で区切られるが、次が 0.5 秒後なので 0.6 秒までは伸ばせない。
        let words = [
            word("はい", 0.0, 0.1),
            word("つぎ", 0.5, 1.2),
        ]
        let lines = SubtitleSegmentation.lines(from: words)
        #expect(lines.count == 2)
        #expect(abs(lines[0].duration - 0.5) < 1e-9, "次の頭で頭打ちになる")
        #expect(lines[0].end <= lines[1].start + 1e-9, "重ならない")
    }

    @Test("空白だけの語は捨てる")
    func skipsBlankWords() {
        let words = [
            word("  ", 0.0, 0.1),
            word("ほんぶん", 0.1, 0.8),
        ]
        let lines = SubtitleSegmentation.lines(from: words)
        #expect(lines.count == 1)
        #expect(lines[0].text == "ほんぶん")
    }

    @Test("英語の語間の空白は保つ")
    func keepsEnglishSpacing() {
        let words = [
            word("Hello", 0.0, 0.4),
            word(" world", 0.4, 0.9),
        ]
        let lines = SubtitleSegmentation.lines(from: words)
        #expect(lines[0].text == "Hello world")
    }

    @Test("前後の空白は落とす")
    func trimsOuterWhitespace() {
        let words = [word(" こんにちは ", 0.0, 0.8)]
        #expect(SubtitleSegmentation.lines(from: words)[0].text == "こんにちは")
    }

    @Test("順番が入れ替わっていても時間順に直す")
    func sortsByTime() {
        let words = [
            word("あと", 2.0, 2.5),
            word("さき", 0.0, 0.5),
        ]
        let lines = SubtitleSegmentation.lines(from: words)
        #expect(lines.first?.text == "さき")
    }

    @Test("何も無ければ何も作らない")
    func emptyInput() {
        #expect(SubtitleSegmentation.lines(from: []).isEmpty)
    }

    @Test("字幕どうしは重ならない")
    func linesDoNotOverlap() {
        let words = (0..<20).map { i in
            word("あいうえ", Double(i) * 0.7, Double(i) * 0.7 + 0.5)
        }
        let lines = SubtitleSegmentation.lines(from: words)
        for i in 1..<lines.count {
            #expect(lines[i - 1].end <= lines[i].start + 1e-9)
        }
    }
}
