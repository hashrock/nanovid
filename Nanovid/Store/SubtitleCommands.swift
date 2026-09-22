import Foundation

/// 字幕の自動生成。
extension EditorStore {

    /// タイムラインの音声を書き起こして、新しいトラックに字幕として並べる。
    @MainActor
    func generateSubtitles(locale: Locale,
                           templateID: UUID,
                           options: SubtitleSegmentation.Options = .default) async {
        guard #available(macOS 26.0, *) else {
            buildError = SubtitleGeneration.requirement
            return
        }
        guard subtitleProgress == nil else { return }
        guard duration > 0 else {
            buildError = L("タイムラインに何も置かれていません。")
            return
        }

        let worker = Transcriber()
        transcriberHandle = worker
        subtitleProgress = SubtitleProgress(phase: .preparing, fraction: nil)
        defer {
            subtitleProgress = nil
            transcriberHandle = nil
        }

        do {
            let words = try await worker.transcribe(
                project: project, baseURL: baseURL, locale: locale
            ) { value in
                Task { @MainActor [weak self] in self?.subtitleProgress = value }
            }
            subtitleProgress = SubtitleProgress(phase: .finishing, fraction: nil)
            let lines = SubtitleSegmentation.lines(from: words, options: options)
            guard !lines.isEmpty else {
                buildError = L("音声から文字を聞き取れませんでした。")
                return
            }
            applySubtitles(lines, templateID: templateID)
        } catch {
            buildError = error.localizedDescription
        }
    }

    func cancelSubtitleGeneration() {
        guard #available(macOS 26.0, *) else { return }
        (transcriberHandle as? Transcriber)?.cancel()
    }

    /// 生成した字幕を新しいトラックへ入れる。
    /// 既存のテロップを壊さないし、気に入らなければトラックごと消せる。
    func applySubtitles(_ lines: [SubtitleLine], templateID: UUID) {
        guard let template = project.template(templateID),
              let key = template.props.first(where: { $0.type == .string })?.key else {
            buildError = L("テンプレートに文字を入れる項目がありません。")
            return
        }

        var made: Set<UUID> = []
        edit { p in
            var track = Track(name: Self.uniqueTrackName(L("字幕（自動）"), in: p), kind: .video)
            track.clips = lines.map { line in
                let clip = Clip(start: p.canvas.snap(line.start),
                                duration: max(p.canvas.frameDuration, p.canvas.snap(line.duration)),
                                content: .text(TextInstance(templateID: templateID,
                                                            props: [key: .string(line.text)])))
                made.insert(clip.id)
                return clip
            }
            p.tracks.append(track)      // 配列の末尾が最前面
        }
        selectedClipIDs = made
    }

    /// 同じ名前のトラックが並ばないようにする。
    static func uniqueTrackName(_ base: String, in project: Project) -> String {
        guard project.tracks.contains(where: { $0.name == base }) else { return base }
        var i = 2
        while project.tracks.contains(where: { $0.name == "\(base) \(i)" }) { i += 1 }
        return "\(base) \(i)"
    }
}
