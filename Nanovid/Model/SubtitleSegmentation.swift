import Foundation

/// 書き起こしの最小単位。認識器が返す語（日本語なら文節に近い）とその時間。
struct TranscribedWord: Equatable, Sendable {
    /// 認識器が返したままの文字列。前後の空白も含む（英語の語間を保つため）。
    var text: String
    var start: Double
    var end: Double

    var duration: Double { max(0, end - start) }
}

/// 1 枚ぶんの字幕。
struct SubtitleLine: Equatable, Sendable {
    var text: String
    var start: Double
    var duration: Double

    var end: Double { start + duration }
}

/// 書き起こしを字幕の枚数に割る。
///
/// 話の切れ目（無音）で区切るのが基本。それでも長いものは文字数で割る。
/// 一文まるごとだと画面に入りきらず、秒数で機械的に割ると文の途中で切れるため。
enum SubtitleSegmentation {

    /// 文の終わり。ここで区切ると意味のまとまりが保てる。
    static let sentenceEnders: Set<Character> = ["。", "．", "！", "？", ".", "!", "?"]
    /// 文の途中の切れ目。文字数で割るときの逃がし先。
    static let clauseBreaks: Set<Character> = ["、", "，", ","]

    struct Options: Equatable, Sendable {
        /// これ以上の無音があれば区切る。
        var pauseThreshold: Double = 0.4
        /// 1 枚に入れる文字数の上限。超えたら割る。
        var maxCharacters: Int = 20
        /// 短すぎると読めないので、最低これだけは出す。
        var minDuration: Double = 0.6
        /// 長く出しっぱなしにしない。
        var maxDuration: Double = 6.0

        static let `default` = Options()
    }

    static func lines(from words: [TranscribedWord],
                      options: Options = .default) -> [SubtitleLine] {
        let usable = words
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.start < $1.start }
        guard !usable.isEmpty else { return [] }

        // 2 段構え。まず意味のまとまりに切り、そのあと長すぎるものを均等に割る。
        // 文字数だけで前から詰めると、最後に 2 文字の端数が残ったりする。
        let lines = chunk(usable, options: options)
            .flatMap { split($0, options: options) }
            .compactMap { makeLine(from: $0) }
        return stretchShortLines(lines, options: options)
    }

    /// 文末・間・出しっぱなしの上限で、意味のまとまりに切る。
    private static func chunk(_ words: [TranscribedWord],
                              options: Options) -> [[TranscribedWord]] {
        var result: [[TranscribedWord]] = []
        var group: [TranscribedWord] = []

        for word in words {
            if let previous = group.last, let first = group.first {
                let silence = word.start - previous.end
                let spanIfAdded = word.end - first.start
                if endsSentence(previous)
                    || silence >= options.pauseThreshold
                    || spanIfAdded > options.maxDuration {
                    result.append(group)
                    group = []
                }
            }
            group.append(word)
        }
        if !group.isEmpty { result.append(group) }
        return result
    }

    /// 長すぎるまとまりを、読点を優先しつつ均等に割る。
    private static func split(_ words: [TranscribedWord],
                              options: Options) -> [[TranscribedWord]] {
        let total = trimmedText(words).count
        guard total > options.maxCharacters, words.count > 1 else { return [words] }

        // 端数が出ないよう、まず何枚に割るかを決めてから目標の文字数を出す。
        let parts = max(2, Int(ceil(Double(total) / Double(options.maxCharacters))))
        let target = Int(ceil(Double(total) / Double(parts)))
        let soft = max(1, Int(Double(target) * 0.6))

        var result: [[TranscribedWord]] = []
        var group: [TranscribedWord] = []

        for (i, word) in words.enumerated() {
            group.append(word)
            let remaining = words.count - i - 1
            guard remaining > 0 else { continue }

            let length = trimmedText(group).count
            let atClause = endsClause(word) && length >= soft
            if atClause || length >= target {
                result.append(group)
                group = []
            }
        }
        if !group.isEmpty { result.append(group) }
        return result
    }

    private static func endsSentence(_ word: TranscribedWord) -> Bool {
        guard let last = word.text.trimmingCharacters(in: .whitespaces).last else { return false }
        return sentenceEnders.contains(last)
    }

    private static func endsClause(_ word: TranscribedWord) -> Bool {
        guard let last = word.text.trimmingCharacters(in: .whitespaces).last else { return false }
        return clauseBreaks.contains(last)
    }

    private static func trimmedText(_ words: [TranscribedWord]) -> String {
        words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func makeLine(from words: [TranscribedWord]) -> SubtitleLine? {
        guard let first = words.first, let last = words.last else { return nil }
        let text = trimmedText(words)
        guard !text.isEmpty else { return nil }
        let span = max(last.end - first.start, 0)
        return SubtitleLine(text: text, start: first.start, duration: span)
    }

    /// 短すぎる字幕を読める長さまで伸ばす。次の字幕にはぶつけない。
    private static func stretchShortLines(_ lines: [SubtitleLine],
                                          options: Options) -> [SubtitleLine] {
        guard !lines.isEmpty else { return [] }
        var result = lines
        for i in result.indices {
            guard result[i].duration < options.minDuration else { continue }
            let limit = i + 1 < result.count
                ? result[i + 1].start - result[i].start
                : Double.greatestFiniteMagnitude
            result[i].duration = min(max(result[i].duration, options.minDuration), max(limit, 0))
        }
        return result
    }
}
