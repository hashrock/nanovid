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
            do {
                made.append(try await AssetCache.shared.inspect(url: url))
            } catch let problem as MediaProblem {
                // 再生できない形式や、途中で切れたファイル。理由をそのまま出す。
                buildError = problem.localizedDescription
            } catch {
                buildError = "読み込めませんでした: \(url.lastPathComponent)"
            }
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
                        content: .text(TextInstance(templateID: templateID)))
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

    /// すべてのクリップを選ぶ（ロックしたトラックは除く）。
    func selectAll() {
        selectedClipIDs = Set(project.tracks.filter { !$0.isLocked }
                                            .flatMap { $0.clips }
                                            .map(\.id))
    }

    /// 時間の範囲とトラックの範囲で囲って選ぶ。矩形選択の実体。
    /// - Parameters:
    ///   - trackIDs: 囲みに入ったトラック。表示順は呼び出し側が解決しておく。
    ///   - additive: 既存の選択に足す（⇧ドラッグ）。
    func selectClips(inTimeRange range: ClosedRange<Double>,
                     trackIDs: Set<UUID>,
                     additive: Bool,
                     base: Set<UUID> = []) {
        var hit: Set<UUID> = []
        for track in project.tracks where trackIDs.contains(track.id) && !track.isLocked {
            for clip in track.clips where clip.start < range.upperBound && clip.end > range.lowerBound {
                hit.insert(clip.id)
            }
        }
        // 幅ゼロの囲みでも、その時刻に重なっていれば拾えるようにする。
        if hit.isEmpty, range.lowerBound == range.upperBound {
            for track in project.tracks where trackIDs.contains(track.id) && !track.isLocked {
                for clip in track.clips where clip.contains(range.lowerBound) {
                    hit.insert(clip.id)
                }
            }
        }
        selectedClipIDs = additive ? base.union(hit) : hit
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

    /// 選択したクリップを消し、空いた時間ぶん後ろを詰める。
    /// カットで不要な区間を抜くときに、全トラックのそろいを保ったまま縮められる。
    func rippleDeleteSelection() {
        let ids = selectedClipIDs
        guard !ids.isEmpty else { return }
        let ranges = mergedRanges(of: ids)
        guard !ranges.isEmpty else { return }

        edit { p in
            for i in p.tracks.indices {
                p.tracks[i].clips.removeAll { ids.contains($0.id) }
            }
            // 後ろの範囲から順に詰める。先に前を詰めると後ろの位置がずれる。
            for range in ranges.reversed() {
                let length = range.upperBound - range.lowerBound
                for i in p.tracks.indices {
                    for j in p.tracks[i].clips.indices
                    where p.tracks[i].clips[j].start >= range.upperBound - 1e-9 {
                        p.tracks[i].clips[j].start -= length
                    }
                }
                p.tracks.indices.forEach { p.tracks[$0].sortClips() }
            }
        }
        selectedClipIDs = []
    }

    /// 選択したクリップをトラックごとに前へ詰めて、隙間をなくす。
    /// 先頭のクリップは動かさない。
    func packSelection() {
        let ids = selectedClipIDs
        guard ids.count > 1 else { return }
        edit { p in
            for i in p.tracks.indices {
                let selected = p.tracks[i].clips
                    .filter { ids.contains($0.id) }
                    .sorted { $0.start < $1.start }
                guard selected.count > 1 else { continue }

                var cursor = selected[0].end
                for clip in selected.dropFirst() {
                    guard let j = p.tracks[i].clips.firstIndex(where: { $0.id == clip.id }) else { continue }
                    p.tracks[i].clips[j].start = cursor
                    cursor += clip.duration
                }
                p.tracks[i].sortClips()
            }
        }
    }

    /// 選択したクリップが占めている時間。重なっている部分はひとつにまとめる。
    func mergedRanges(of ids: Set<UUID>) -> [ClosedRange<Double>] {
        let ranges = project.tracks
            .flatMap(\.clips)
            .filter { ids.contains($0.id) }
            .map { $0.start...($0.end) }
            .sorted { $0.lowerBound < $1.lowerBound }
        guard var current = ranges.first else { return [] }

        var merged: [ClosedRange<Double>] = []
        for range in ranges.dropFirst() {
            if range.lowerBound <= current.upperBound + 1e-9 {
                current = current.lowerBound...max(current.upperBound, range.upperBound)
            } else {
                merged.append(current)
                current = range
            }
        }
        merged.append(current)
        return merged
    }

    /// 選択したクリップ全体が占める時間。ズームや情報表示に使う。
    var selectionSpan: ClosedRange<Double>? {
        let clips = project.tracks.flatMap(\.clips).filter { selectedClipIDs.contains($0.id) }
        guard let first = clips.first else { return nil }
        let start = clips.map(\.start).min() ?? first.start
        let end = clips.map(\.end).max() ?? first.end
        return start...end
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

    /// 選択したクリップをまとめて動かす。互いの位置関係は保つ。
    /// - Parameters:
    ///   - laneDelta: 表示上、何段ぶん上下に動かすか。
    ///   - laneOrder: 表示順に並べたトラック ID。段の対応はここで解決する。
    func moveClips(_ ids: Set<UUID>, deltaSeconds: Double, laneDelta: Int, laneOrder: [UUID]) {
        let moving = project.tracks.flatMap { track in
            track.clips.filter { ids.contains($0.id) }.map { (clip: $0, trackID: track.id) }
        }
        guard !moving.isEmpty else { return }
        // ロックしたトラックのものは動かさない。
        guard moving.allSatisfy({ pair in
            project.tracks.first { $0.id == pair.trackID }?.isLocked == false
        }) else { return }

        // 先頭が 0 より手前へ出ないように寄せる。
        let earliest = moving.map(\.clip.start).min() ?? 0
        let delta = max(deltaSeconds, -earliest)

        // 段の移動は、全部が移せるときだけ通す。1 つでも無理なら時間だけ動かす。
        var targets: [UUID: UUID] = [:]
        var laneShift = laneDelta
        if laneShift != 0 {
            for pair in moving {
                guard let from = laneOrder.firstIndex(of: pair.trackID) else { laneShift = 0; break }
                let to = from + laneShift
                guard laneOrder.indices.contains(to),
                      let target = project.tracks.first(where: { $0.id == laneOrder[to] }),
                      !target.isLocked,
                      accepts(clip: pair.clip, track: target) else { laneShift = 0; break }
                targets[pair.clip.id] = target.id
            }
        }
        if laneShift == 0 { targets = [:] }

        edit { p in
            var detached: [(clip: Clip, trackID: UUID)] = []
            for i in p.tracks.indices {
                let taken = p.tracks[i].clips.filter { ids.contains($0.id) }
                p.tracks[i].clips.removeAll { ids.contains($0.id) }
                detached.append(contentsOf: taken.map { ($0, p.tracks[i].id) })
            }
            for var pair in detached {
                pair.clip.start = p.canvas.snap(max(0, pair.clip.start + delta))
                let destination = targets[pair.clip.id] ?? pair.trackID
                guard let i = p.tracks.firstIndex(where: { $0.id == destination }) else { continue }
                p.tracks[i].clips.append(pair.clip)
            }
            p.tracks.indices.forEach { p.tracks[$0].sortClips() }
        }
    }

    /// そのトラックにそのクリップを置けるか（映像と音声を取り違えないため）。
    func accepts(clip: Clip, track: Track) -> Bool {
        let isAudioOnly = clip.content.assetID
            .flatMap { project.asset($0) }?.kind == .audio
        return track.kind == .audio ? isAudioOnly : !isAudioOnly
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

    /// クリップを 1 つだけ書き換える。
    /// coalesceKey を渡すと、ドラッグ中の連続変更が 1 つの undo にまとまる。
    func updateClip(_ id: UUID, coalesceKey: String? = nil, _ body: (inout Clip) -> Void) {
        edit(coalescing: coalesceKey) { p in
            for ti in p.tracks.indices {
                for ci in p.tracks[ti].clips.indices where p.tracks[ti].clips[ci].id == id {
                    body(&p.tracks[ti].clips[ci])
                }
            }
        }
    }

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

// MARK: - 書き出す範囲

extension EditorStore {

    /// 範囲の最小の長さ。1 フレームは残す。
    private var minimumOutputDuration: Double { project.canvas.frameDuration }

    /// 開始位置を動かす。終了位置は据え置きなので、そのぶん尺が変わる。
    /// - Parameter coalescing: ドラッグ中は同じ key を渡して 1 つの undo にまとめる。
    func setOutputStart(_ time: Double, coalescing key: String? = nil) {
        let end = project.outputEnd
        let start = project.canvas.snap(min(max(0, time), end - minimumOutputDuration))
        applyOutputRange(start: start, end: end, coalescing: key)
    }

    /// 終了位置を動かす。開始位置は据え置き。
    func setOutputEnd(_ time: Double, coalescing key: String? = nil) {
        let start = project.outputStart
        let end = project.canvas.snap(max(time, start + minimumOutputDuration))
        applyOutputRange(start: start, end: end, coalescing: key)
    }

    /// 尺を決める。開始位置を軸に終了位置が動く。
    func setOutputDuration(_ seconds: Double, coalescing key: String? = nil) {
        setOutputEnd(project.outputStart + seconds, coalescing: key)
    }

    /// 範囲をクリップ追従に戻す。
    func resetOutputRange() {
        guard project.outputRange != nil else { return }
        edit { $0.outputRange = nil }
    }

    private func applyOutputRange(start: Double, end: Double, coalescing key: String?) {
        let next = OutputRange(start: start, end: max(start + minimumOutputDuration, end))
        guard next != project.outputRange else { return }
        edit(coalescing: key) { $0.outputRange = next }
    }
}
