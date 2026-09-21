import SwiftUI
import UniformTypeIdentifiers

struct TimelineView: View {
    @Bindable var store: EditorStore

    static let headerWidth: CGFloat = 176
    static let laneHeight: CGFloat = 56
    static let laneGap: CGFloat = 4
    static let rulerHeight: CGFloat = 24

    @State private var drag: ClipDrag?
    @State private var dropTargetTrack: UUID?

    private var pps: Double { store.pixelsPerSecond }

    /// 表示順。映像は前面が上、音声はその下にまとめる。
    private var lanes: [Track] {
        let video = store.project.tracks.filter { $0.kind == .video }.reversed()
        let audio = store.project.tracks.filter { $0.kind == .audio }
        return Array(video) + audio
    }

    private var contentWidth: CGFloat {
        CGFloat(max(store.duration, 10) * pps) + 400
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            // ヘッダ列とレーン列は同じ HStack に入れて縦位置を揃える。
            // 縦スクロールは外側でまとめてかけ、横スクロールはレーン側だけにかける。
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    headerColumn
                    Divider()
                    ScrollView(.horizontal) {
                        ZStack(alignment: .topLeading) {
                            VStack(alignment: .leading, spacing: 0) {
                                RulerView(store: store, width: contentWidth)
                                    .frame(height: Self.rulerHeight)
                                ForEach(lanes) { track in
                                    laneView(track)
                                }
                            }
                            playhead
                        }
                        .frame(width: contentWidth, alignment: .topLeading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(Color(nsColor: .underPageBackgroundColor))
        }
        .focusable()
        .focusEffectDisabled()
        // 修飾キーなしのキー操作は、ここにフォーカスがあるときだけ効かせる。
        // こうしておけば一括編集やインスペクタでの文字入力を奪わない。
        .onKeyPress { press in
            switch press.key {
            case .space:
                store.togglePlay(); return .handled
            case .leftArrow:
                store.step(frames: press.modifiers.contains(.shift) ? -10 : -1); return .handled
            case .rightArrow:
                store.step(frames: press.modifiers.contains(.shift) ? 10 : 1); return .handled
            case .delete, .deleteForward:
                store.deleteSelection(); return .handled
            case .escape:
                store.selectedClipIDs = []; return .handled
            default:
                break
            }
            switch press.characters.lowercased() {
            case "s": store.splitAtPlayhead(); return .handled
            case "d": store.duplicateSelection(); return .handled
            case "j": store.seek(to: store.currentTime - 1); return .handled
            case "l": store.seek(to: store.currentTime + 1); return .handled
            case "k": store.togglePlay(); return .handled
            default: return .ignored
            }
        }
    }

    // MARK: - 上部ツールバー

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text(Format.timecode(store.currentTime, fps: store.project.canvas.fps))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.primary)
            Text("/ \(Format.timecode(store.duration, fps: store.project.canvas.fps))")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

            Divider().frame(height: 16)

            Button { store.splitAtPlayhead() } label: {
                Label("分割", systemImage: "scissors")
            }
            .help("再生ヘッドの位置でクリップを分割 (S)")

            Button { store.deleteSelection() } label: {
                Label("削除", systemImage: "trash")
            }
            .disabled(store.selectedClipIDs.isEmpty)

            Button { store.duplicateSelection() } label: {
                Label("複製", systemImage: "plus.square.on.square")
            }
            .disabled(store.selectedClipIDs.isEmpty)

            Spacer()

            Menu {
                Button("映像トラックを追加") { store.addTrack(kind: .video) }
                Button("音声トラックを追加") { store.addTrack(kind: .audio) }
            } label: {
                Label("トラック", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
            Slider(value: $store.pixelsPerSecond, in: 12...400).frame(width: 130)
            Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .labelStyle(.iconOnly)
        .padding(.horizontal, 10)
        .frame(height: 34)
    }

    // MARK: - トラックヘッダ

    private var headerColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ルーラーの高さぶんだけ空ける。これでレーンと行がそろう。
            Color.clear.frame(width: Self.headerWidth, height: Self.rulerHeight)
            ForEach(lanes) { track in
                TrackHeaderView(store: store, track: track)
                    .frame(width: Self.headerWidth, height: Self.laneHeight)
                    .padding(.bottom, Self.laneGap)
            }
        }
        .frame(width: Self.headerWidth, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - レーン

    private func laneView(_ track: Track) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(laneBackground(track))
                .frame(height: Self.laneHeight)
                .contentShape(Rectangle())
                .onTapGesture { store.selectedClipIDs = [] }

            ForEach(track.clips) { clip in
                clipView(clip, in: track)
            }
        }
        .frame(width: contentWidth, height: Self.laneHeight, alignment: .topLeading)
        .clipped()
        .padding(.bottom, Self.laneGap)
        .dropDestination(for: URL.self) { urls, location in
            handleDrop(urls: urls, track: track, at: location)
            return true
        } isTargeted: { targeted in
            dropTargetTrack = targeted ? track.id : nil
        }
    }

    private func laneBackground(_ track: Track) -> Color {
        if dropTargetTrack == track.id { return Color.accentColor.opacity(0.18) }
        return Color(nsColor: .controlBackgroundColor).opacity(track.isHidden ? 0.4 : 0.8)
    }

    private func clipView(_ clip: Clip, in track: Track) -> some View {
        let preview = previewGeometry(for: clip)
        return ClipView(
            store: store,
            clip: clip,
            track: track,
            isSelected: store.selectedClipIDs.contains(clip.id),
            isDragging: drag?.clipID == clip.id
        )
        .frame(width: max(6, CGFloat(preview.duration * pps)), height: Self.laneHeight)
        .offset(x: CGFloat(preview.start * pps))
        .zIndex(drag?.clipID == clip.id ? 10 : 0)
        .gesture(moveGesture(clip: clip, track: track))
        .overlay(alignment: .leading) { trimHandle(clip: clip, edge: .leading) }
        .overlay(alignment: .trailing) { trimHandle(clip: clip, edge: .trailing) }
        .offset(y: drag?.clipID == clip.id ? CGFloat(drag?.laneOffset ?? 0) : 0)
    }

    // MARK: - ドラッグ

    struct ClipDrag {
        enum Mode { case move, trimLeft, trimRight }
        var clipID: UUID
        var mode: Mode
        var deltaSeconds: Double = 0
        var laneDelta: Int = 0

        var laneOffset: Double {
            Double(laneDelta) * Double(TimelineView.laneHeight + TimelineView.laneGap)
        }
    }

    private struct PreviewGeometry {
        var start: Double
        var duration: Double
    }

    private func previewGeometry(for clip: Clip) -> PreviewGeometry {
        guard let drag, drag.clipID == clip.id else {
            return PreviewGeometry(start: clip.start, duration: clip.duration)
        }
        switch drag.mode {
        case .move:
            return PreviewGeometry(start: max(0, clip.start + drag.deltaSeconds), duration: clip.duration)
        case .trimLeft:
            let limit = clip.duration - store.project.canvas.frameDuration
            let d = min(max(drag.deltaSeconds, -clip.start), limit)
            return PreviewGeometry(start: clip.start + d, duration: clip.duration - d)
        case .trimRight:
            let maxD = store.maxDuration(of: clip)
            let d = min(max(clip.duration + drag.deltaSeconds, store.project.canvas.frameDuration), maxD)
            return PreviewGeometry(start: clip.start, duration: d)
        }
    }

    private func moveGesture(clip: Clip, track: Track) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                guard !track.isLocked else { return }
                if drag == nil {
                    drag = ClipDrag(clipID: clip.id, mode: .move)
                    if !store.selectedClipIDs.contains(clip.id) {
                        store.select(clipID: clip.id, extend: false)
                    }
                }
                let raw = Double(value.translation.width) / pps
                drag?.deltaSeconds = snapped(delta: raw, clip: clip, edge: .start)
                let laneStep = Double(Self.laneHeight + Self.laneGap)
                drag?.laneDelta = Int((Double(value.translation.height) / laneStep).rounded())
            }
            .onEnded { _ in
                defer { drag = nil }
                guard let d = drag, d.clipID == clip.id else { return }
                let newStart = max(0, clip.start + d.deltaSeconds)
                let targetTrack = laneTrack(from: track, offset: d.laneDelta) ?? track
                store.move(clipID: clip.id, toTrack: targetTrack.id, start: newStart)
            }
    }

    private func trimHandle(clip: Clip, edge: HorizontalEdge) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .frame(width: 10)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .highPriorityGesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if drag == nil {
                            drag = ClipDrag(clipID: clip.id,
                                            mode: edge == .leading ? .trimLeft : .trimRight)
                        }
                        let raw = Double(value.translation.width) / pps
                        drag?.deltaSeconds = snapped(delta: raw, clip: clip,
                                                     edge: edge == .leading ? .start : .end)
                    }
                    .onEnded { _ in
                        defer { drag = nil }
                        guard let d = drag, d.clipID == clip.id else { return }
                        if edge == .leading {
                            store.trimLeft(clipID: clip.id, to: clip.start + d.deltaSeconds)
                        } else {
                            store.trimRight(clipID: clip.id, to: clip.end + d.deltaSeconds)
                        }
                    }
            )
    }

    private func laneTrack(from track: Track, offset: Int) -> Track? {
        guard let index = lanes.firstIndex(where: { $0.id == track.id }) else { return nil }
        let target = index + offset
        guard lanes.indices.contains(target) else { return nil }
        return lanes[target]
    }

    // MARK: - スナップ

    private enum SnapEdge { case start, end }

    /// 近くのクリップ端・再生ヘッド・原点に吸着させる。効かない場合はフレーム境界へ丸める。
    private func snapped(delta: Double, clip: Clip, edge: SnapEdge) -> Double {
        let canvas = store.project.canvas
        let base = edge == .start ? clip.start : clip.end
        let moved = base + delta
        let threshold = 8.0 / pps

        var targets: [Double] = [0, store.currentTime]
        for t in store.project.tracks {
            for c in t.clips where c.id != clip.id {
                targets.append(c.start)
                targets.append(c.end)
            }
        }
        if let near = targets.min(by: { abs($0 - moved) < abs($1 - moved) }),
           abs(near - moved) < threshold {
            return near - base
        }
        return canvas.snap(moved) - base
    }

    // MARK: - 再生ヘッド

    private var playhead: some View {
        let x = CGFloat(store.currentTime * pps)
        let height = Self.rulerHeight + CGFloat(lanes.count) * (Self.laneHeight + Self.laneGap)
        return Rectangle()
            .fill(Color.red)
            .frame(width: 1.5, height: max(height, Self.rulerHeight))
            .overlay(alignment: .top) {
                // Path の座標はフレーム左上が原点。幅 10 の中で中央に頂点を置く。
                Path { p in
                    p.move(to: CGPoint(x: 0, y: 0))
                    p.addLine(to: CGPoint(x: 10, y: 0))
                    p.addLine(to: CGPoint(x: 5, y: 8))
                    p.closeSubpath()
                }
                .fill(Color.red)
                .frame(width: 10, height: 8)
            }
            // 線の中心を時刻位置に合わせる。
            .offset(x: x - 0.75)
            .allowsHitTesting(false)
    }

    // MARK: - ドロップ

    private func handleDrop(urls: [URL], track: Track, at location: CGPoint) {
        let time = store.project.canvas.snap(max(0, Double(location.x) / pps))
        Task { @MainActor in
            let assets = await store.importAssets(urls: urls)
            var cursor = time
            for asset in assets {
                let wantsAudio = asset.kind == .audio
                guard (track.kind == .audio) == wantsAudio else { continue }
                store.addMediaClip(assetID: asset.id, trackID: track.id, at: cursor)
                cursor += asset.kind == .image ? 5 : asset.duration
            }
        }
    }
}

// MARK: - 目盛り

private struct RulerView: View {
    @Bindable var store: EditorStore
    let width: CGFloat

    var body: some View {
        let pps = store.pixelsPerSecond
        let spec = TickSpec.forRuler(pixelsPerSecond: pps)
        SwiftUI.Canvas { context, size in
            let labelColor = Color.secondary
            let count = spec.minorCount(width: Double(size.width), pixelsPerSecond: pps)
            for i in 0...max(0, count) {
                let isMajor = spec.isMajor(index: i)
                if !isMajor && !spec.showsMinor { continue }
                let t = spec.time(index: i)
                let x = CGFloat(t * pps)
                if x > size.width { break }

                var line = Path()
                line.move(to: CGPoint(x: x, y: isMajor ? 4 : 13))
                line.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(line,
                               with: .color(.secondary.opacity(isMajor ? 0.55 : 0.22)),
                               lineWidth: 1)

                if isMajor {
                    let text = Text(Format.rulerLabel(t, step: spec.major))
                        .font(.system(size: 9, design: .monospaced))
                    var resolved = context.resolve(text)
                    resolved.shading = .color(labelColor)
                    context.draw(resolved, at: CGPoint(x: x + 3, y: 2), anchor: .topLeading)
                }
            }
        }
        .frame(width: width)
        .background(Color(nsColor: .windowBackgroundColor))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    store.pause()
                    store.seek(to: store.project.canvas.snap(Double(value.location.x) / pps))
                }
        )
    }

}

// MARK: - トラックヘッダ

private struct TrackHeaderView: View {
    @Bindable var store: EditorStore
    let track: Track

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: track.kind == .video ? "film" : "waveform")
                .foregroundStyle(.secondary)
                .font(.caption)
            Text(track.name)
                .font(.caption)
                .lineLimit(1)
            Spacer(minLength: 0)
            if track.kind == .video {
                toggle(systemImage: track.isHidden ? "eye.slash" : "eye", isOn: !track.isHidden) {
                    store.edit { p in
                        if let i = p.tracks.firstIndex(where: { $0.id == track.id }) {
                            p.tracks[i].isHidden.toggle()
                        }
                    }
                }
            }
            toggle(systemImage: track.isMuted ? "speaker.slash" : "speaker.wave.2", isOn: !track.isMuted) {
                store.edit { p in
                    if let i = p.tracks.firstIndex(where: { $0.id == track.id }) {
                        p.tracks[i].isMuted.toggle()
                    }
                }
            }
            toggle(systemImage: track.isLocked ? "lock" : "lock.open", isOn: !track.isLocked) {
                store.edit { p in
                    if let i = p.tracks.firstIndex(where: { $0.id == track.id }) {
                        p.tracks[i].isLocked.toggle()
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .contextMenu {
            Button("上へ") { store.moveTrack(id: track.id, offset: 1) }
            Button("下へ") { store.moveTrack(id: track.id, offset: -1) }
            Divider()
            Button("トラックを削除", role: .destructive) { store.removeTrack(id: track.id) }
        }
    }

    private func toggle(systemImage: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10))
                .foregroundStyle(isOn ? Color.secondary : Color.orange)
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.borderless)
    }
}

// MARK: - クリップ

private struct ClipView: View {
    @Bindable var store: EditorStore
    let clip: Clip
    let track: Track
    let isSelected: Bool
    let isDragging: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5)
                .fill(fill)
            if clip.fade.inDuration > 0 || clip.fade.outDuration > 0 {
                fadeOverlay
            }
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9))
                Text(label).font(.system(size: 10)).lineLimit(1)
            }
            .foregroundStyle(.white.opacity(0.95))
            .padding(.horizontal, 6)
            .padding(.top, 5)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(isSelected ? Color.white : Color.black.opacity(0.35),
                              lineWidth: isSelected ? 2 : 1)
        )
        .opacity(isDragging ? 0.75 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 5))
        .onTapGesture {
            store.select(clipID: clip.id, extend: NSEvent.modifierFlags.contains(.command))
        }
        .contextMenu {
            Button("この位置で分割") {
                store.selectedClipIDs = [clip.id]
                store.splitAtPlayhead()
            }
            Button("複製") {
                store.selectedClipIDs = [clip.id]
                store.duplicateSelection()
            }
            Divider()
            Button("削除", role: .destructive) {
                store.selectedClipIDs = [clip.id]
                store.deleteSelection()
            }
        }
    }

    private var fadeOverlay: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let total = max(clip.duration, 1e-6)
            let inW = CGFloat(clip.fade.inDuration / total) * w
            let outW = CGFloat(clip.fade.outDuration / total) * w
            ZStack(alignment: .leading) {
                if inW > 1 {
                    LinearGradient(colors: [.black.opacity(0.55), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: inW)
                }
                if outW > 1 {
                    LinearGradient(colors: [.clear, .black.opacity(0.55)],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: outW)
                        .offset(x: w - outW)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .allowsHitTesting(false)
    }

    private var isText: Bool { clip.content.textInstance != nil }

    private var fill: Color {
        if isText { return Color(red: 0.45, green: 0.33, blue: 0.72) }
        if track.kind == .audio { return Color(red: 0.16, green: 0.49, blue: 0.36) }
        return Color(red: 0.18, green: 0.38, blue: 0.62)
    }

    private var icon: String {
        if isText { return "textformat" }
        if track.kind == .audio { return "waveform" }
        if let id = clip.content.assetID, store.project.asset(id)?.kind == .image { return "photo" }
        return "film"
    }

    private var label: String {
        if let inst = clip.content.textInstance {
            if let template = store.project.template(inst.templateID) {
                // 一番はじめの文字列プロパティを見出しに使う。
                for def in template.props where def.type == .string {
                    if let s = inst.value(def.key, in: template)?.stringValue, !s.isEmpty {
                        return s
                    }
                }
                return template.name
            }
            return "テキスト"
        }
        if !clip.name.isEmpty { return clip.name }
        if let id = clip.content.assetID { return store.project.asset(id)?.displayName ?? "クリップ" }
        return "クリップ"
    }
}
