import Testing
import Foundation
@testable import Nanovid

/// タイムラインのテキストを字幕ファイル（SRT / WebVTT）にする。
struct SubtitleExportTests {

    /// 同梱の字幕テンプレート（文字列の props は text の 1 つ）で、テキストのクリップを作る。
    private func caption(_ text: String?, start: Double, duration: Double, in project: Project) -> Clip {
        let template = project.textTemplates[0]
        return Clip(start: start, duration: duration,
                    content: .text(TextInstance(templateID: template.id,
                                                props: text.map { ["text": .string($0)] } ?? [:])))
    }

    /// 映像 1 / テロップ / 音声 1 の starter に、テロップのトラックへ字幕を並べる。
    private func project(_ captions: [(String, Double, Double)]) -> Project {
        var project = Project.starter()
        project.tracks[1].clips = captions.map { caption($0.0, start: $0.1, duration: $0.2, in: project) }
        return project
    }

    // MARK: 集める

    @Test("テキストのクリップが、出る順に 1 枚ずつ字幕になる")
    func textClipsBecomeCues() {
        let project = project([("二枚目", 2, 1.5), ("一枚目", 0.5, 1)])
        #expect(SubtitleExport.cues(from: project) == [
            SubtitleCue(start: 0.5, end: 1.5, text: "一枚目"),
            SubtitleCue(start: 2, end: 3.5, text: "二枚目"),
        ])
    }

    @Test("映像や音声のクリップは字幕にならない")
    func mediaClipsAreIgnored() {
        var project = project([("字幕", 0, 1)])
        let asset = MediaAsset(path: "/a.mp4", displayName: "a", kind: .video, duration: 5,
                               naturalSize: nil, hasAudio: true, hasVideo: true)
        project.assets = [asset]
        project.tracks[0].clips = [Clip(start: 0, duration: 5, content: .media(assetID: asset.id, sourceStart: 0))]
        #expect(SubtitleExport.cues(from: project).map(\.text) == ["字幕"])
    }

    @Test("隠してあるトラックのテキストは出さない")
    func hiddenTracksAreSkipped() {
        var project = project([("見える", 0, 1)])
        var hidden = Track(name: "隠し", kind: .video)
        hidden.isHidden = true
        hidden.clips = [caption("見えない", start: 0, duration: 1, in: project)]
        project.tracks.append(hidden)
        #expect(SubtitleExport.cues(from: project).map(\.text) == ["見える"])
    }

    @Test("書き出す範囲の外は出さず、端で切って、範囲の頭を 0 秒にそろえる")
    func cuesFollowTheOutputRange() {
        var project = project([("前", 0, 1), ("頭にかかる", 1.5, 1), ("中", 3, 1), ("尻にかかる", 4.5, 2), ("後", 7, 1)])
        project.outputRange = OutputRange(start: 2, end: 5)
        #expect(SubtitleExport.cues(from: project) == [
            SubtitleCue(start: 0, end: 0.5, text: "頭にかかる"),
            SubtitleCue(start: 1, end: 2, text: "中"),
            SubtitleCue(start: 2.5, end: 3, text: "尻にかかる"),
        ])
    }

    @Test("文言を変えていないクリップは、テンプレートの既定の文言で出る")
    func defaultTextIsUsed() throws {
        let project = project([])
        var copy = project
        copy.tracks[1].clips = [caption(nil, start: 0, duration: 1, in: project)]
        let fallback = try #require(project.textTemplates[0].propDef(for: "text")?.defaultValue.stringValue)
        #expect(SubtitleExport.cues(from: copy).map(\.text) == [fallback])
    }

    @Test("空の文言は出さない。文言の中の空行と前後の空白は落とす")
    func emptyAndBlankLines() {
        let project = project([("", 0, 1), ("   ", 1, 1), ("  一行目 \n\n\r\n二行目\n", 2, 1)])
        #expect(SubtitleExport.cues(from: project).map(\.text) == ["一行目\n二行目"])
    }

    @Test("文字列の props がいくつかあるテンプレートは、定義の順に改行でつなぐ")
    func multipleStringPropsAreJoined() throws {
        var project = Project.starter()
        // 同梱の「タイトル」は見出しとサブの 2 つを持つ。
        let title = try #require(project.textTemplates.first { t in
            t.props.filter { $0.type == .string }.count >= 2
        })
        let keys = title.props.filter { $0.type == .string }.map(\.key)
        project.tracks[1].clips = [
            Clip(start: 0, duration: 2, content: .text(TextInstance(
                templateID: title.id, props: [keys[0]: .string("見出し"), keys[1]: .string("サブ")])))
        ]
        #expect(SubtitleExport.cues(from: project).map(\.text) == ["見出し\nサブ"])
    }

    @Test("同時に出るものは、もとの並び（奥のトラックから）のまま")
    func simultaneousCuesKeepTrackOrder() {
        var project = project([("奥", 1, 1)])
        var front = Track(name: "手前", kind: .video)
        front.clips = [caption("手前", start: 1, duration: 1, in: project),
                       caption("先に出る", start: 0, duration: 0.5, in: project)]
        project.tracks.append(front)
        #expect(SubtitleExport.cues(from: project).map(\.text) == ["先に出る", "奥", "手前"])
    }

    // MARK: 書く

    private let sample = [
        SubtitleCue(start: 0.5, end: 2, text: "こんにちは"),
        SubtitleCue(start: 3661.2345, end: 3662, text: "二行の\n字幕"),
    ]

    @Test("SRT の形")
    func srtFormat() {
        #expect(SubtitleExport.srt(sample) == """
        1
        00:00:00,500 --> 00:00:02,000
        こんにちは

        2
        01:01:01,235 --> 01:01:02,000
        二行の
        字幕

        """)
        #expect(SubtitleExport.srt([]) == "")
    }

    @Test("WebVTT の形")
    func vttFormat() {
        #expect(SubtitleExport.vtt(sample) == """
        WEBVTT

        00:00:00.500 --> 00:00:02.000
        こんにちは

        01:01:01.235 --> 01:01:02.000
        二行の
        字幕

        """)
        #expect(SubtitleExport.vtt([]) == "WEBVTT\n")
    }

    @Test("WebVTT ではタグと紛れる文字を実体参照にする。SRT はそのまま")
    func vttEscapes() {
        let cues = [SubtitleCue(start: 0, end: 1, text: "A & B <i>x</i> --> y")]
        #expect(SubtitleExport.vtt(cues).contains("A &amp; B &lt;i&gt;x&lt;/i&gt; --&gt; y"))
        #expect(SubtitleExport.srt(cues).contains("A & B <i>x</i> --> y"))
    }

    @Test("ミリ秒に丸めても、長さ 0 の字幕にならない")
    func roundingKeepsCuesNonEmpty() {
        let srt = SubtitleExport.srt([SubtitleCue(start: 1.0001, end: 1.0003, text: "一瞬")])
        #expect(srt.contains("00:00:01,000 --> 00:00:01,001"))
    }

    // MARK: store を通して

    @Test("store から書き出したファイルは UTF-8 で、枚数を返す")
    @MainActor
    func storeWritesTheFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nanovid-subs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = EditorStore()
        #expect(!store.canExportSubtitles)
        store.project = project([("日本語の字幕", 0, 1), ("二枚目", 1, 1)])
        #expect(store.canExportSubtitles)

        let srt = dir.appendingPathComponent("out.srt")
        #expect(try store.exportSubtitles(to: srt, format: .srt) == 2)
        #expect(try String(contentsOf: srt, encoding: .utf8) == SubtitleExport.srt(SubtitleExport.cues(from: store.project)))
        let vtt = dir.appendingPathComponent("out.vtt")
        try store.exportSubtitles(to: vtt, format: .vtt)
        #expect(try String(contentsOf: vtt, encoding: .utf8).hasPrefix("WEBVTT\n\n00:00:00.000 --> 00:00:01.000\n日本語の字幕\n"))
    }
}
