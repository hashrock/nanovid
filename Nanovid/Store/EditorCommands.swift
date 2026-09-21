import AVFoundation
import Foundation

/// タイムラインに対する編集操作。すべて checkpoint 経由なので undo が効く。
extension EditorStore {

    // MARK: - 素材の取り込み

    @MainActor
    func importAssets(urls: [URL]) async -> [MediaAsset] {
        var made: [MediaAsset] = []
        for url in urls {
            // 同じファイルを二重登録しない。
            if let existing = project.assets.first(where: {
                $0.url(relativeTo: baseURL).standardizedFileURL == url.standardizedFileURL
            }) {
                made.append(existing)
                continue
            }
            guard let asset = try? await AssetCache.shared.inspect(url: url) else {
                buildError = "読み込めませんでした: \(url.lastPathComponent)"
                continue
            }
            made.append(asset)
        }
        guard !made.isEmpty else { return [] }
        let fresh = made.filter { a in !project.assets.contains { $0.id == a.id } }
        if !fresh.isEmpty {
            edit { $0.assets.append(contentsOf: fresh) }
        }
        return made
    }

    /// 取り込んで、そのままタイムライン末尾に並べる。
    @MainActor
    func importAndAppend(urls: [URL]) async {
        let assets = await importAssets(urls: urls)
        guard !assets.isEmpty else { return }
        checkpoint()
        var copy = project
        for asset in assets {
            let kind: TrackKind = asset.kind == .audio ? .audio : .video
            guard let trackIndex = copy.tracks.lastIndex(where: { $0.kind == kind })
                ?? copy.tracks.firstIndex(where: { $0.kind == kind }) else { continue }
            let start = copy.canvas.snap(copy.tracks[trackIndex].duration)
            var clip = Clip(name: asset.displayName, start: start,
                            duration: copy.canvas.snap(max(asset.duration, copy.canvas.frameDuration)),
                            content: .media(assetID: asset.id, sourceStart: 0))
            if asset.kind == .image { clip.duration = 5 }
            copy.tracks[trackIndex].clips.append(clip)
            copy.tracks[trackIndex].sortClips()
        }
        project = copy
    }

    // MARK: - クリップの追加

    func addMediaClip(assetID: UUID, trackID: UUID, at time: Double) {
        guard let asset = project.asset(assetID),
              let ti = project.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        let start = project.canvas.snap(max(0, time))
        let duration = project.canvas.snap(max(project.canvas.frameDuration,
                                               asset.kind == .image ? 5 : asset.duration))
        edit {
            $0.tracks[ti].clips.append(Clip(name: asset.displayName, start: start, duration: duration,
                                            content: .media(assetID: assetID, sourceStart: 0)))
            $0.tracks[ti].sortClips()
        }
    }

    func addTextClip(templateID: UUID, trackID: UUID, at time: Double, duration: Double = 3) {
        guard let ti = project.tracks.firstIndex(where: { $0.id == trackID }),
              let template = project.template(templateID) else { return }
        let clip = Clip(name: template.name,
                        start: project.canvas.snap(max(0, time)),
                        duration: project.canvas.snap(duration),
                        content: .text(TextInstance(templateID: templateID)),
                        fade: Fade(inDuration: 0.2, outDuration: 0.2))
        edit {
            $0.tracks[ti].clips.append(clip)
            $0.tracks[ti].sortClips()
        }
        selectedClipIDs = [clip.id]
    }

    // MARK: - 選択と削除

    func select(clipID: UUID, extend: Bool) {
        if extend {
            if selectedClipIDs.contains(clipID) { selectedClipIDs.remove(clipID) }
            else { selectedClipIDs.insert(clipID) }
        } else {
            selectedClipIDs = [clipID]
        }
        selectedTrackID = project.track(containing: clipID)?.id
    }

    func deleteSelection() {
        guard !selectedClipIDs.isEmpty else { return }
        let ids = selectedClipIDs
        edit { p in
            for i in p.tracks.indices {
                p.tracks[i].clips.removeAll { ids.contains($0.id) }
            }
        }
        selectedClipIDs = []
    }

    func duplicateSelection() {
        guard !selectedClipIDs.isEmpty else { return }
        let ids = selectedClipIDs
        var newIDs: Set<UUID> = []
        edit { p in
            for i in p.tracks.indices {
                let copies = p.tracks[i].clips.filter { ids.contains($0.id) }.map { original -> Clip in
                    var c = original
                    c.id = UUID()
                    c.start = p.canvas.snap(original.end)
                    newIDs.insert(c.id)
                    return c
                }
                p.tracks[i].clips.append(contentsOf: copies)
                p.tracks[i].sortClips()
            }
        }
        selectedClipIDs = newIDs
    }

    // MARK: - 分割

    /// 再生ヘッド位置で、選択中（未選択なら全トラック）のクリップを切る。
    func splitAtPlayhead() {
        let t = project.canvas.snap(currentTime)
        let targets = selectedClipIDs
        var produced: Set<UUID> = []
        edit { p in
            for ti in p.tracks.indices where !p.tracks[ti].isLocked {
                var appended: [Clip] = []
                for ci in p.tracks[ti].clips.indices {
                    let clip = p.tracks[ti].clips[ci]
                    guard targets.isEmpty || targets.contains(clip.id) else { continue }
                    guard clip.contains(t), t - clip.start > 1e-6, clip.end - t > 1e-6 else { continue }

                    let offset = t - clip.start
                    var left = clip
                    left.duration = offset
                    left.fade.outDuration = 0

                    var right = clip
                    right.id = UUID()
                    right.start = t
                    right.duration = clip.duration - offset
                    right.fade.inDuration = 0
                    if case .media(let assetID, let sourceStart) = clip.content {
                        right.content = .media(assetID: assetID, sourceStart: sourceStart + offset)
                    }
                    p.tracks[ti].clips[ci] = left
                    appended.append(right)
                    produced.insert(right.id)
                }
                p.tracks[ti].clips.append(contentsOf: appended)
                p.tracks[ti].sortClips()
            }
        }
        if !produced.isEmpty { selectedClipIDs = produced }
    }

    // MARK: - 移動とトリム

    func move(clipID: UUID, toTrack targetTrackID: UUID, start newStart: Double) {
        guard let sourceIndex = project.tracks.firstIndex(where: {
            $0.clips.contains { $0.id == clipID }
        }), let targetIndex = project.tracks.firstIndex(where: { $0.id == targetTrackID }),
        !project.tracks[sourceIndex].isLocked, !project.tracks[targetIndex].isLocked else { return }

        // 映像クリップを音声トラックへ、のような付け替えは許さない。
        let clipIsAudioOnly = project.clip(clipID).map { clip -> Bool in
            guard let assetID = clip.content.assetID else { return false }
            return project.asset(assetID)?.kind == .audio
        } ?? false
        let target = project.tracks[targetIndex]
        if target.kind == .audio && !clipIsAudioOnly { return }
        if target.kind == .video && clipIsAudioOnly { return }

        edit { p in
            guard let ci = p.tracks[sourceIndex].clips.firstIndex(where: { $0.id == clipID }) else { return }
            var clip = p.tracks[sourceIndex].clips.remove(at: ci)
            clip.start = p.canvas.snap(max(0, newStart))
            p.tracks[targetIndex].clips.append(clip)
            p.tracks[targetIndex].sortClips()
            p.tracks[sourceIndex].sortClips()
        }
    }

    /// 素材の残り尺を踏まえた、そのクリップで取り得る最大長。
    func maxDuration(of clip: Clip) -> Double {
        guard case .media(let assetID, let sourceStart) = clip.content,
              let asset = project.asset(assetID), asset.kind != .image else { return .infinity }
        return max(project.canvas.frameDuration, asset.duration - sourceStart)
    }

    func trimLeft(clipID: UUID, to newStart: Double) {
        guard let ti = project.tracks.firstIndex(where: { $0.clips.contains { $0.id == clipID } }),
              let ci = project.tracks[ti].clips.firstIndex(where: { $0.id == clipID }) else { return }
        let clip = project.tracks[ti].clips[ci]
        let snapped = project.canvas.snap(max(0, newStart))
        var delta = snapped - clip.start
        // 素材の先頭より手前には戻せない。
        if case .media(_, let sourceStart) = clip.content, clip.content.assetID != nil {
            delta = max(delta, -sourceStart)
        }
        delta = min(delta, clip.duration - project.canvas.frameDuration)
        guard abs(delta) > 1e-9 else { return }

        edit { p in
            var c = p.tracks[ti].clips[ci]
            c.start += delta
            c.duration -= delta
            if case .media(let assetID, let sourceStart) = c.content {
                c.content = .media(assetID: assetID, sourceStart: max(0, sourceStart + delta))
            }
            p.tracks[ti].clips[ci] = c
            p.tracks[ti].sortClips()
        }
    }

    func trimRight(clipID: UUID, to newEnd: Double) {
        guard let ti = project.tracks.firstIndex(where: { $0.clips.contains { $0.id == clipID } }),
              let ci = project.tracks[ti].clips.firstIndex(where: { $0.id == clipID }) else { return }
        let clip = project.tracks[ti].clips[ci]
        let limit = maxDuration(of: clip)
        let duration = min(limit, max(project.canvas.frameDuration,
                                      project.canvas.snap(newEnd) - clip.start))
        guard abs(duration - clip.duration) > 1e-9 else { return }
        edit { $0.tracks[ti].clips[ci].duration = duration }
    }

    // MARK: - クリップ属性

    func updateSelectedClips(_ body: @escaping (inout Clip) -> Void) {
        let ids = selectedClipIDs
        guard !ids.isEmpty else { return }
        edit { p in
            for ti in p.tracks.indices {
                for ci in p.tracks[ti].clips.indices where ids.contains(p.tracks[ti].clips[ci].id) {
                    body(&p.tracks[ti].clips[ci])
                }
            }
        }
    }

    // MARK: - テキストの一括編集

    /// 選択中（または指定した）テキストクリップの props をまとめて書き換える。
    /// coalesceKey を渡すと、文字入力のような連続変更が 1 つの undo にまとまる。
    func setTextProp(_ key: String, to value: PropValue,
                     clipIDs: Set<UUID>? = nil, coalesceKey: String? = nil) {
        let ids = clipIDs ?? selectedClipIDs
        guard !ids.isEmpty else { return }
        edit(coalescing: coalesceKey) { p in
            for ti in p.tracks.indices {
                for ci in p.tracks[ti].clips.indices where ids.contains(p.tracks[ti].clips[ci].id) {
                    guard var inst = p.tracks[ti].clips[ci].content.textInstance else { continue }
                    inst.props[key] = value
                    p.tracks[ti].clips[ci].content = .text(inst)
                }
            }
        }
    }

    /// 上書きを取り消してテンプレートの既定値に戻す。
    func resetTextProp(_ key: String, clipIDs: Set<UUID>? = nil) {
        let ids = clipIDs ?? selectedClipIDs
        guard !ids.isEmpty else { return }
        edit { p in
            for ti in p.tracks.indices {
                for ci in p.tracks[ti].clips.indices where ids.contains(p.tracks[ti].clips[ci].id) {
                    guard var inst = p.tracks[ti].clips[ci].content.textInstance else { continue }
                    inst.props.removeValue(forKey: key)
                    p.tracks[ti].clips[ci].content = .text(inst)
                }
            }
        }
    }

    /// テキストクリップのテンプレートを差し替える。props のキーが一致するものは引き継ぐ。
    func retemplate(clipIDs: Set<UUID>, to templateID: UUID) {
        guard let template = project.template(templateID) else { return }
        let valid = Set(template.props.map(\.key))
        edit { p in
            for ti in p.tracks.indices {
                for ci in p.tracks[ti].clips.indices where clipIDs.contains(p.tracks[ti].clips[ci].id) {
                    guard var inst = p.tracks[ti].clips[ci].content.textInstance else { continue }
                    inst.templateID = templateID
                    inst.props = inst.props.filter { valid.contains($0.key) }
                    p.tracks[ti].clips[ci].content = .text(inst)
                }
            }
        }
    }

    // MARK: - トラック

    func addTrack(kind: TrackKind) {
        let count = project.tracks.filter { $0.kind == kind }.count + 1
        edit { $0.tracks.append(Track(name: "\(kind.label) \(count)", kind: kind)) }
    }

    func removeTrack(id: UUID) {
        edit { $0.tracks.removeAll { $0.id == id } }
    }

    func moveTrack(id: UUID, offset: Int) {
        guard let i = project.tracks.firstIndex(where: { $0.id == id }) else { return }
        let j = i + offset
        guard project.tracks.indices.contains(j) else { return }
        edit { $0.tracks.swapAt(i, j) }
    }

    // MARK: - テンプレート

    func upsertTemplate(_ template: TextTemplate) {
        edit { p in
            if let i = p.textTemplates.firstIndex(where: { $0.id == template.id }) {
                p.textTemplates[i] = template
            } else {
                p.textTemplates.append(template)
            }
        }
        TextRasterizer.shared.invalidateAll()
    }

    func duplicateTemplate(_ id: UUID) {
        guard var t = project.template(id) else { return }
        t.id = UUID()
        t.name += " のコピー"
        t.nodes = t.nodes.map { var n = $0; n.id = UUID(); return n }
        edit { $0.textTemplates.append(t) }
    }

    func removeTemplate(_ id: UUID) {
        guard project.textClips(usingTemplate: id).isEmpty else {
            buildError = "このテンプレートは使用中です。"
            return
        }
        edit { $0.textTemplates.removeAll { $0.id == id } }
    }

    // MARK: - キャンバス

    func setCanvas(width: Int, height: Int, fps: Int) {
        edit {
            $0.canvas.width = width
            $0.canvas.height = height
            $0.canvas.fps = fps
        }
        TextRasterizer.shared.invalidateAll()
    }
}
