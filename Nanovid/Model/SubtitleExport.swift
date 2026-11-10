import Foundation

/// 字幕 1 枚。時刻は書き出した動画の頭を 0 とした秒。
struct SubtitleCue: Hashable {
    var start: Double
    var end: Double
    var text: String
}

/// タイムラインのテキストを、字幕ファイル（SRT / WebVTT）にする。
///
/// 動画サイトやほかの編集ソフトへ字幕を渡すためのもの。動画に焼き込まれる
/// 見た目（色・位置・フェード）は持っていかず、いつ・何と出るかだけを書く。
///
/// **何を字幕と見なすか**: テキストのクリップ全部。下段の「字幕」タブに並ぶのと
/// 同じもの。このアプリには「字幕」と「テロップ」「タイトル」を分ける型が無く、
/// どれも同じテキストクリップで、テンプレートが違うだけなので、ここでも分けない。
/// - 隠してあるトラックのものは出さない（動画にも映らないので）。
/// - 書き出す範囲の外は出さない。範囲の端にかかるものは端で切り、時刻は範囲の頭を
///   0 秒にそろえる（書き出した MP4 と合う）。
/// - 文言は、テンプレートの文字列の props を定義の順に改行でつないだもの
///   （字幕のテンプレートなら 1 つ、タイトルなら見出しとサブの 2 行）。変えていない
///   props はテンプレートの既定値。空のものは出さない。
enum SubtitleExport {

    enum Format: String, CaseIterable {
        case srt, vtt

        var fileExtension: String { rawValue }
    }

    // MARK: - 集める

    static func cues(from project: Project) -> [SubtitleCue] {
        let from = project.outputStart
        let to = project.outputEnd
        var cues: [SubtitleCue] = []
        for track in project.tracks where !track.isHidden {
            for clip in track.clips {
                guard let instance = clip.content.textInstance,
                      let template = project.template(instance.templateID) else { continue }
                let start = max(clip.start, from)
                let end = min(clip.end, to)
                guard end - start > 1e-9 else { continue }
                let text = self.text(of: instance, in: template)
                guard !text.isEmpty else { continue }
                cues.append(SubtitleCue(start: start - from, end: end - from, text: text))
            }
        }
        // 出る順。同時に出るものは、もとの並び（奥のトラックから）のまま。
        return cues.enumerated().sorted { a, b in
            if a.element.start != b.element.start { return a.element.start < b.element.start }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// クリップの文言。文字列の props を、テンプレートの定義の順に改行でつなぐ。
    static func text(of instance: TextInstance, in template: TextTemplate) -> String {
        template.props
            .filter { $0.type == .string }
            .compactMap { instance.value($0.key, in: template)?.stringValue }
            .map(normalized)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// 字幕ファイルは空行で 1 枚が終わる。文言の中の空行と前後の空白を落とす。
    static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    // MARK: - 書く

    static func string(_ cues: [SubtitleCue], format: Format) -> String {
        switch format {
        case .srt: return srt(cues)
        case .vtt: return vtt(cues)
        }
    }

    /// SubRip。番号、`00:00:01,500 --> 00:00:03,000`、文言、空行。
    static func srt(_ cues: [SubtitleCue]) -> String {
        cues.enumerated().map { index, cue in
            let (start, end) = milliseconds(cue)
            return "\(index + 1)\n\(timestamp(start, separator: ",")) --> \(timestamp(end, separator: ","))\n\(cue.text)\n"
        }.joined(separator: "\n")
    }

    /// WebVTT。先頭に `WEBVTT`、時刻の小数点はピリオド。文言の `&` `<` `>` は
    /// タグと紛れるので実体参照にする（`-->` が文言に入るのもこれで防げる）。
    static func vtt(_ cues: [SubtitleCue]) -> String {
        let body = cues.map { cue in
            let (start, end) = milliseconds(cue)
            let text = cue.text
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            return "\(timestamp(start, separator: ".")) --> \(timestamp(end, separator: "."))\n\(text)\n"
        }.joined(separator: "\n")
        return body.isEmpty ? "WEBVTT\n" : "WEBVTT\n\n" + body
    }

    /// ミリ秒に丸める。丸めた結果、長さが 0 にならないようにする。
    private static func milliseconds(_ cue: SubtitleCue) -> (start: Int, end: Int) {
        let start = max(0, Int((cue.start * 1000).rounded()))
        let end = max(start + 1, Int((cue.end * 1000).rounded()))
        return (start, end)
    }

    static func timestamp(_ milliseconds: Int, separator: String) -> String {
        let ms = milliseconds % 1000
        let seconds = milliseconds / 1000
        return String(format: "%02d:%02d:%02d%@%03d",
                      seconds / 3600, seconds / 60 % 60, seconds % 60, separator, ms)
    }
}
