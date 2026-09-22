import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TimelineView: View {
    @Bindable var store: EditorStore
    @Binding var bottomTab: BottomTab

    static let headerWidth: CGFloat = 176
    static let laneHeight: CGFloat = 56
    static let laneGap: CGFloat = 4
    static let rulerHeight: CGFloat = 24
    static let minZoom: Double = 8
    static let maxZoom: Double = 600
    /// レーン表示領域の座標空間。ドラッグ中に動かない基準として使う。
    static let laneSpaceName = "nanovid.timeline.lanes"

    /// 横スクロール位置(pt)。ScrollView に任せるとズーム時にカーソル位置を保てないので自前で持つ。
    @State private var scrollX: Double = 0
    @State private var scrollY: Double = 0
    @State private var viewport: CGSize = .zero
    /// レーン表示領域でのカーソル位置。ズームの軸と、右クリック挿入位置に使う。
    @State private var hoverPoint: CGPoint?
    @State private var wheelMonitor: Any?
    @State private var scrollBarGrabOffset: Double?
    @State private var verticalBarGrabOffset: Double?
    /// 吸着を効かせるか。プロジェクトではなく端末ごとの好みなので AppStorage で持つ。
    @AppStorage("nanovid.timeline.snapping") private var snappingEnabled = true

    @State private var drag: ClipDrag?
    @State private var dropTargetTrack: UUID?
    @State private var hoveredClipID: UUID?
    @State private var marquee: Marquee?

    /// ドラッグ中の囲み。座標はレーン表示領域（表示座標）。
    struct Marquee {
        var start: CGPoint
        var current: CGPoint
        /// ⇧ドラッグ。もとの選択に足す。
        var additive: Bool
        var base: Set<UUID>

        var rect: CGRect {
            CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                   width: abs(current.x - start.x), height: abs(current.y - start.y))
        }
    }

    private var pps: Double { store.pixelsPerSecond }

    /// 表示順。映像は前面が上、音声はその下にまとめる。
    private var lanes: [Track] {
        let video = store.project.tracks.filter { $0.kind == .video }.reversed()
        let audio = store.project.tracks.filter { $0.kind == .audio }
        return Array(video) + audio
    }

    private var contentWidth: CGFloat {
        // 末尾にも余白を持たせて、終端の先へ置けるようにする。
        // EditorStore.timelineEnd と同じ範囲になるようにそろえてある。
        CGFloat(TimelineScroll.contentX(forTime: max(max(store.contentEnd, store.outputEnd), 10),
                                        pixelsPerSecond: pps))
            + CGFloat(EditorStore.trailingSlack)
    }

    /// レーンを縦に並べたときの高さ。
    ///
    /// 各レーンの下に隙間を入れているが、いちばん下の隙間は数えない。
    /// 数えると、ちょうど収まる本数でも隙間ぶんだけはみ出したことになり、
    /// スクロールバーが出っぱなしになる（ホイールもそこへ吸われる）。
    private var lanesHeight: CGFloat {
        guard !lanes.isEmpty else { return 0 }
        return CGFloat(lanes.count) * (Self.laneHeight + Self.laneGap) - Self.laneGap
    }

    private var maxScrollX: Double {
        max(0, Double(contentWidth) - Double(viewport.width))
    }

    private var maxScrollY: Double {
        max(0, Double(lanesHeight) - (Double(viewport.height) - Double(Self.rulerHeight)))
    }

    private var offsetX: Double { min(max(0, scrollX), maxScrollX) }
    private var offsetY: Double { min(max(0, scrollY), maxScrollY) }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                headerColumn
                Divider()
                laneArea
            }
            scrollBar
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(action: handleKey)
        .onAppear(perform: installWheelMonitor)
        .onDisappear(perform: removeWheelMonitor)
        .onChange(of: store.currentTime) { _, _ in followPlayheadIfNeeded() }
    }

    // MARK: - 上部ツールバー

    private var toolbar: some View {
        HStack(spacing: 10) {
            BottomTabPicker(selection: $bottomTab)

            Divider().frame(height: 16)

            Text(Format.timecode(store.currentTime, fps: store.project.canvas.fps))
                .font(.system(.callout, design: .monospaced))
            Text("/ \(Format.timecode(store.duration, fps: store.project.canvas.fps))")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

            Divider().frame(height: 16)

            Toggle(isOn: $snappingEnabled) {
                // magnet は macOS 26 の SF Symbols に無い。pin で代用する。
                Label("吸着", systemImage: snappingEnabled ? "pin" : "pin.slash")
            }
            .toggleStyle(.button)
            .help("クリップの端や再生ヘッドへの吸着 (ドラッグ中に ⌥ で一時的に切り替え)")

            Button { store.splitAtPlayhead() } label: { Label("分割", systemImage: "scissors") }
                .help("再生ヘッドの位置でクリップを分割 (S)")
            Button { store.deleteSelection() } label: { Label("削除", systemImage: "trash") }
                .disabled(store.selectedClipIDs.isEmpty)
            Button { store.duplicateSelection() } label: {
                Label("複製", systemImage: "plus.square.on.square")
            }
            .disabled(store.selectedClipIDs.isEmpty)

            if !store.selectedClipIDs.isEmpty {
                Divider().frame(height: 16)
                selectionMenu
            }

            if let range = store.pendingExtractRange {
                Divider().frame(height: 16)
                extractControl(range)
            }

            Spacer()

            Menu {
                Button("映像トラックを追加") { store.addTrack(kind: .video) }
                Button("音声トラックを追加") { store.addTrack(kind: .audio) }
            } label: {
                Label("トラック", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button { zoomStep(0.8) } label: { Image(systemName: "minus.magnifyingglass") }
            Slider(value: Binding(
                get: { pps },
                set: { zoom(to: $0, anchorX: Double(viewport.width) / 2) }
            ), in: Self.minZoom...Self.maxZoom)
            .frame(width: 130)
            Button { zoomStep(1.25) } label: { Image(systemName: "plus.magnifyingglass") }
            Button { zoomToFit() } label: { Image(systemName: "arrow.left.and.right") }
                .help("全体が収まるまで縮小")
        }
        .buttonStyle(.borderless)
        .labelStyle(.iconOnly)
        .padding(.horizontal, 10)
        .frame(height: 34)
    }

    /// 切り抜きの範囲を打っているあいだの表示と操作。
    private func extractControl(_ range: ClosedRange<Double>) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "scissors")
                .font(.caption)
                .foregroundStyle(.orange)
            Text("切り抜き \(Format.seconds(range.upperBound - range.lowerBound)) 秒")
                .font(.caption)
                .foregroundStyle(.orange)
            Button("切り抜く") { store.extractMarkedRange() }
                .font(.caption)
            Button {
                store.cancelExtract()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .help("切り抜きをやめる (Esc)")
        }
    }

    /// 選択中のクリップに対する操作。まとめて選んだあとの行き先をここに集める。
    private var selectionMenu: some View {
        Menu {
            Button("コピー") { store.copySelection() }
            Button("切り取り") { store.cutSelection() }
            Button("貼り付け") { store.paste() }
            Divider()
            Button("削除して詰める") { store.rippleDeleteSelection() }
            Button("隙間を詰める") { store.packSelection() }
                .disabled(store.selectedClipIDs.count < 2)
            Divider()
            Button("選択にズーム") { zoomToSelection() }
            Button("選択の先頭へ") {
                if let span = store.selectionSpan { store.seek(to: span.lowerBound) }
            }
            Divider()
            Button("すべて選択") { store.selectAll() }
            Button("選択を解除") { store.selectedClipIDs = [] }
        } label: {
            Text(selectionSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var selectionSummary: String {
        let count = store.selectedClipIDs.count
        guard let span = store.selectionSpan else { return "\(count) 個" }
        let total = store.mergedRanges(of: store.selectedClipIDs)
            .reduce(0.0) { $0 + ($1.upperBound - $1.lowerBound) }
        return count == 1
            ? "1 個 · \(Format.seconds(total)) 秒"
            : "\(count) 個 · \(Format.seconds(total)) 秒 / 範囲 \(Format.seconds(span.upperBound - span.lowerBound)) 秒"
    }

    /// 選択したクリップが画面いっぱいに入るまで寄る。
    private func zoomToSelection() {
        guard let span = store.selectionSpan, viewport.width > 0 else { return }
        let length = max(span.upperBound - span.lowerBound, 0.2)
        let target = (Double(viewport.width) - 80) / length
        store.pixelsPerSecond = min(Self.maxZoom, max(Self.minZoom, target))
        scrollX = max(0, TimelineScroll.contentX(forTime: span.lowerBound,
                                                 pixelsPerSecond: pps) - 40)
    }

    // MARK: - トラックヘッダ

    private var headerColumn: some View {
        VStack(spacing: 0) {
            Color.clear.frame(width: Self.headerWidth, height: Self.rulerHeight)
            // GeometryReader で包んで、中身の高さに引きずられないようにする。
            // 並べたヘッダは固定高なので、そのままだとこの列が縮まず、
            // タイムライン全体の最小高さがトラック数ぶんに固定されてしまう。
            // 枠が足りないとはみ出して、上のトランスポートに重なる。
            GeometryReader { _ in
                VStack(spacing: 0) {
                    ForEach(lanes) { track in
                        TrackHeaderView(store: store, track: track)
                            .frame(width: Self.headerWidth, height: Self.laneHeight)
                            .padding(.bottom, Self.laneGap)
                    }
                }
                .offset(y: -offsetY)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .clipped()
        }
        .frame(width: Self.headerWidth)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - レーン表示領域

    private var laneArea: some View {
        GeometryReader { geo in
            // レーンの中身はビューポートより広いので、各段に実寸の幅を与えて左端に固定する。
            // maxWidth: .infinity だけだと内容幅まで広がり、目盛りが中央寄せされてしまう。
            //
            // 目盛りは ZStack の後ろに置いて最前面にする。縦にスクロールするとレーンが
            // 目盛りの位置まで上がってくるが、clipped() は描画を隠すだけでクリックは
            // 奪ったままになるため、前面に無いと目盛りが押せなくなる。
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(lanes) { track in
                        laneView(track)
                    }
                }
                .offset(x: -offsetX, y: -offsetY)
                .frame(width: geo.size.width,
                       height: max(0, geo.size.height - Self.rulerHeight),
                       alignment: .topLeading)
                .clipped()
                .padding(.top, Self.rulerHeight)

                RulerView(store: store, scrollX: offsetX, snappingEnabled: snappingEnabled)
                    .frame(width: geo.size.width, height: Self.rulerHeight, alignment: .topLeading)
                    .clipped()
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .overlay(alignment: .topLeading) { outsideOutputWash }
            .overlay(alignment: .topLeading) { extractOverlay }
            .overlay(alignment: .topLeading) { playhead }
            .overlay(alignment: .topLeading) { marqueeOverlay }
            .overlay(alignment: .topTrailing) { verticalScrollBar }
            .background(Color(nsColor: .underPageBackgroundColor))
            // クリップのドラッグはこの空間で測る。クリップ自身は .offset で動くので、
            // ジェスチャをクリップのローカル空間で測ると位置が振動してしまう。
            .coordinateSpace(.named(Self.laneSpaceName))
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hoverPoint = point
                case .ended: hoverPoint = nil
                }
            }
            .gesture(magnifyGesture)
            .onAppear { viewport = geo.size }
            .onChange(of: geo.size) { _, new in viewport = new }
        }
    }

    private func laneView(_ track: Track) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(laneBackground(track))
                .frame(width: contentWidth, height: Self.laneHeight)
                .contentShape(Rectangle())
                // クリックも囲みも同じジェスチャで扱う。onTapGesture を併置すると
                // 取り合いになって囲みが始まらない。
                .gesture(marqueeGesture)
                .contextMenu { laneMenu(track) }

            ForEach(track.clips) { clip in
                clipView(clip, in: track)
            }
        }
        .frame(width: contentWidth, height: Self.laneHeight, alignment: .topLeading)
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
        return Color(nsColor: .controlBackgroundColor).opacity(track.isHidden ? 0.4 : 0.85)
    }

    // MARK: - 右クリックメニュー

    @ViewBuilder
    private func laneMenu(_ track: Track) -> some View {
        let time = insertTime

        Text("\(Format.timecode(time, fps: store.project.canvas.fps)) に追加")

        if track.kind == .video {
            Menu("テキスト") {
                ForEach(store.project.textTemplates) { template in
                    Button(template.name) {
                        store.addTextClip(templateID: template.id, trackID: track.id, at: time)
                    }
                }
            }
        }

        let usable = store.project.assets.filter {
            (track.kind == .audio) == ($0.kind == .audio)
        }
        if !usable.isEmpty {
            Menu("素材") {
                ForEach(usable) { asset in
                    Button(asset.displayName) {
                        store.addMediaClip(assetID: asset.id, trackID: track.id, at: time)
                    }
                }
            }
        }

        Button("ファイルを読み込んで置く…") { importAndPlace(on: track, at: time) }

        Divider()
        Button("ここへ再生ヘッドを移動") { store.seek(to: time) }
        Divider()
        Button("映像トラックを追加") { store.addTrack(kind: .video) }
        Button("音声トラックを追加") { store.addTrack(kind: .audio) }
    }

    /// 右クリックした位置の時刻。カーソルが外に出ていれば再生ヘッド位置。
    private var insertTime: Double {
        guard let p = hoverPoint else { return store.currentTime }
        return store.project.canvas.snap(
            TimelineScroll.time(atViewportX: Double(p.x), scrollX: offsetX, pixelsPerSecond: pps))
    }

    private func importAndPlace(on track: Track, at time: Double) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ProjectIO.mediaTypes
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { @MainActor in
            let assets = await store.importAssets(urls: urls)
            var cursor = time
            for asset in assets where (track.kind == .audio) == (asset.kind == .audio) {
                store.addMediaClip(assetID: asset.id, trackID: track.id, at: cursor)
                cursor += asset.kind == .image ? 5 : asset.duration
            }
        }
    }

    // MARK: - クリップ

    private func clipView(_ clip: Clip, in track: Track) -> some View {
        let preview = previewGeometry(for: clip)
        let width = max(6, CGFloat(TimelineScroll.contentX(forTime: preview.duration,
                                                           pixelsPerSecond: pps)))
        let isSelected = store.selectedClipIDs.contains(clip.id)
        // 短いクリップでも掴み代が本体を覆い尽くさないようにする。
        let handleWidth = min(9, max(4, width / 3))

        return ZStack(alignment: .leading) {
            ClipView(store: store, clip: clip, track: track,
                     isSelected: isSelected, isDragging: isDragging(clip))
                .gesture(moveGesture(clip: clip, track: track))

            // 掴み代はクリップ本体より後ろに置く＝上に重なるので、確実にこちらが先に当たる。
            HStack(spacing: 0) {
                trimHandle(clip: clip, edge: .leading, width: handleWidth,
                           visible: isSelected || hoveredClipID == clip.id)
                Spacer(minLength: 0)
                trimHandle(clip: clip, edge: .trailing, width: handleWidth,
                           visible: isSelected || hoveredClipID == clip.id)
            }
            .disabled(track.isLocked)
        }
        .frame(width: width, height: Self.laneHeight)
        .offset(x: CGFloat(TimelineScroll.contentX(forTime: preview.start,
                                                   pixelsPerSecond: pps)))
        .offset(y: dragLaneOffset(for: clip))
        .zIndex(isDragging(clip) ? 10 : 0)
        .onHover { inside in
            if inside { hoveredClipID = clip.id }
            else if hoveredClipID == clip.id { hoveredClipID = nil }
        }
    }

    private func trimHandle(clip: Clip, edge: HorizontalEdge,
                            width: CGFloat, visible: Bool) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.white.opacity(visible ? 0.55 : 0.001))
            .frame(width: width)
            .padding(.vertical, 6)
            .padding(edge == .leading ? .leading : .trailing, 2)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
            }
            .highPriorityGesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.laneSpaceName))
                    .onChanged { value in
                        let pointer = pointerTime(value.location)
                        let base = edge == .leading ? clip.start : clip.end
                        if drag == nil {
                            drag = ClipDrag(clipID: clip.id,
                                            mode: edge == .leading ? .trimLeft : .trimRight,
                                            grabOffset: pointerTime(value.startLocation) - base,
                                            grabY: Double(value.startLocation.y))
                        }
                        // 移動ジェスチャが先に始まっていたら手を出さない。
                        guard var current = drag, current.clipID == clip.id,
                              current.mode != .move else { return }
                        let resolved = TimelineSnap.resolve(
                            pointerTime: pointer, grabOffset: current.grabOffset,
                            targets: snapTargets(excluding: [clip.id]),
                            threshold: snapThreshold,
                            frameDuration: store.project.canvas.frameDuration)
                        current.deltaSeconds = resolved - base
                        drag = current
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

    // MARK: - ドラッグ

    struct ClipDrag {
        enum Mode { case move, trimLeft, trimRight }
        var clipID: UUID
        var mode: Mode
        /// 掴んだ瞬間の「ポインタの時刻 − 基準時刻」。以降これを引いて目標時刻を出す。
        var grabOffset: Double
        /// 掴んだ瞬間のポインタの Y（表示座標）。トラック間移動の判定に使う。
        var grabY: Double
        /// 複数選んでいるときは、掴んだもの以外も一緒に動かす。
        var movesSelection: Bool = false
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

    /// ドラッグ中に動いて見えるか。まとめて動かしているときは選択中のものすべて。
    private func isDragging(_ clip: Clip) -> Bool {
        guard let drag else { return false }
        if drag.clipID == clip.id { return true }
        return drag.mode == .move && drag.movesSelection
            && store.selectedClipIDs.contains(clip.id)
    }

    private func dragLaneOffset(for clip: Clip) -> CGFloat {
        isDragging(clip) ? CGFloat(drag?.laneOffset ?? 0) : 0
    }

    private func previewGeometry(for clip: Clip) -> PreviewGeometry {
        guard let drag, isDragging(clip) else {
            return PreviewGeometry(start: clip.start, duration: clip.duration)
        }
        // 端のトリムは掴んだクリップだけに効かせる。
        if drag.mode != .move, drag.clipID != clip.id {
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

    // MARK: - 矩形選択

    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.laneSpaceName))
            .onChanged { value in
                if marquee == nil {
                    let additive = NSEvent.modifierFlags.contains(.shift)
                    marquee = Marquee(start: value.startLocation, current: value.location,
                                      additive: additive,
                                      base: additive ? store.selectedClipIDs : [])
                }
                marquee?.current = value.location
                applyMarquee()
            }
            .onEnded { value in
                defer { marquee = nil }
                let moved = max(abs(value.translation.width), abs(value.translation.height))
                if moved < 3 {
                    // ほぼ動いていなければ、空きをクリックしたとみなして選択を解く。
                    if !(marquee?.additive ?? false) { store.selectedClipIDs = [] }
                } else {
                    applyMarquee()
                }
            }
    }

    private func applyMarquee() {
        guard let m = marquee else { return }
        let a = pointerTime(m.start)
        let b = pointerTime(m.current)
        let lo = laneIndex(atViewportY: Double(m.start.y))
        let hi = laneIndex(atViewportY: Double(m.current.y))
        let touched = lanes.enumerated()
            .filter { $0.offset >= min(lo, hi) && $0.offset <= max(lo, hi) }
            .map(\.element.id)
        store.selectClips(inTimeRange: min(a, b)...max(a, b),
                          trackIDs: Set(touched),
                          additive: m.additive, base: m.base)
    }

    /// 表示座標の y から段番号を出す。はみ出したぶんは端の段に寄せる。
    private func laneIndex(atViewportY y: Double) -> Int {
        let local = y - Double(Self.rulerHeight) + offsetY
        let step = Double(Self.laneHeight + Self.laneGap)
        let raw = Int(floor(local / step))
        return min(max(raw, 0), max(0, lanes.count - 1))
    }

    @ViewBuilder
    private var marqueeOverlay: some View {
        if let m = marquee {
            let rect = m.rect
            Rectangle()
                .fill(Color.accentColor.opacity(0.14))
                .overlay(Rectangle().strokeBorder(Color.accentColor.opacity(0.85), lineWidth: 1))
                .frame(width: max(rect.width, 1), height: max(rect.height, 1))
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
        }
    }

    // MARK: - 移動

    private func moveGesture(clip: Clip, track: Track) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.laneSpaceName))
            .onChanged { value in
                guard !track.isLocked else { return }
                let pointer = pointerTime(value.location)
                if drag == nil {
                    if !store.selectedClipIDs.contains(clip.id) {
                        store.select(clipID: clip.id, extend: false)
                    }
                    // 掴んだ基準は startLocation から取る。最初の onChanged が届く時点では
                    // ポインタが minimumDistance ぶん進んでいるので、location だと
                    // その移動量を飲み込んでカーソルから遅れてしまう。
                    drag = ClipDrag(clipID: clip.id, mode: .move,
                                    grabOffset: pointerTime(value.startLocation) - clip.start,
                                    grabY: Double(value.startLocation.y),
                                    movesSelection: store.selectedClipIDs.count > 1
                                        && store.selectedClipIDs.contains(clip.id))
                }
                guard var current = drag, current.mode == .move, current.clipID == clip.id else { return }
                let resolved = TimelineSnap.resolve(
                    pointerTime: pointer, grabOffset: current.grabOffset,
                    targets: snapTargets(excluding: movingIDs(current)),
                    threshold: snapThreshold,
                    frameDuration: store.project.canvas.frameDuration)
                current.deltaSeconds = resolved - clip.start
                let laneStep = Double(Self.laneHeight + Self.laneGap)
                current.laneDelta = Int(((Double(value.location.y) - current.grabY) / laneStep).rounded())
                drag = current
            }
            .onEnded { _ in
                defer { drag = nil }
                guard let d = drag, d.clipID == clip.id, d.mode == .move else { return }
                let ids = d.movesSelection ? store.selectedClipIDs : [clip.id]
                store.moveClips(ids, deltaSeconds: d.deltaSeconds,
                                laneDelta: d.laneDelta, laneOrder: lanes.map(\.id))
            }
    }

    // MARK: - スナップ

    /// 吸着が効く距離。画面上 8pt ぶんを時間に直す。
    /// 切っているあいだは 0 にして、フレーム境界への丸めだけ残す。
    /// フレームから外れた位置は動画として意味がないので、そこは常に丸める。
    ///
    /// - Parameter inverted: ⌥ のように、そのときだけ設定を裏返す指示。
    static func snapThreshold(pixelsPerSecond pps: Double,
                              enabled: Bool, inverted: Bool) -> Double {
        let snapping = inverted ? !enabled : enabled
        return snapping ? 8.0 / max(pps, 1) : 0
    }

    /// ドラッグの最中に読むので、⌥ の状態はそのつど見る。
    /// DragGesture の値には修飾キーが載ってこないため。
    static func liveSnapThreshold(pixelsPerSecond pps: Double, enabled: Bool) -> Double {
        snapThreshold(pixelsPerSecond: pps, enabled: enabled,
                      inverted: NSEvent.modifierFlags.contains(.option))
    }

    private var snapThreshold: Double {
        Self.liveSnapThreshold(pixelsPerSecond: pps, enabled: snappingEnabled)
    }

    /// 吸着先。一緒に動くもの以外のクリップ端・再生ヘッド・原点。
    /// まとめて動かしているときに相手へ吸着すると、位置関係が崩れてしまう。
    private func snapTargets(excluding ids: Set<UUID>) -> [Double] {
        var targets: [Double] = [0, store.currentTime]
        for track in store.project.tracks {
            for c in track.clips where !ids.contains(c.id) {
                targets.append(c.start)
                targets.append(c.end)
            }
        }
        return targets
    }

    /// ドラッグ中に一緒に動くクリップ。
    private func movingIDs(_ drag: ClipDrag) -> Set<UUID> {
        drag.movesSelection ? store.selectedClipIDs : [drag.clipID]
    }

    /// 表示座標のポインタ位置を時刻に直す。
    private func pointerTime(_ location: CGPoint) -> Double {
        TimelineScroll.time(atViewportX: Double(location.x),
                            scrollX: offsetX, pixelsPerSecond: pps)
    }

    // MARK: - 再生ヘッド

    private var playhead: some View {
        let x = CGFloat(TimelineScroll.viewportX(forTime: store.currentTime,
                                                 scrollX: offsetX, pixelsPerSecond: pps))
        let visible = x >= -1 && x <= viewport.width + 1
        return Rectangle()
            .fill(Color.red)
            .frame(width: 1.5)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .top) {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: 0))
                    p.addLine(to: CGPoint(x: 10, y: 0))
                    p.addLine(to: CGPoint(x: 5, y: 8))
                    p.closeSubpath()
                }
                .fill(Color.red)
                .frame(width: 10, height: 8)
            }
            .offset(x: x - 0.75)
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(false)
    }

    /// 書き出す範囲の外を伏せる。目盛りと同じ濃さにそろえてある。
    /// クリックは奪わない（範囲外のクリップも触れる）。
    @ViewBuilder
    private var outsideOutputWash: some View {
        let startX = TimelineScroll.viewportX(forTime: store.outputStart,
                                              scrollX: offsetX, pixelsPerSecond: pps)
        let endX = TimelineScroll.viewportX(forTime: store.outputEnd,
                                            scrollX: offsetX, pixelsPerSecond: pps)
        let wash = Color(nsColor: .windowBackgroundColor).opacity(0.55)
        ZStack(alignment: .topLeading) {
            if startX > 0 {
                Rectangle().fill(wash)
                    .frame(width: min(startX, Double(viewport.width)))
                    .frame(maxHeight: .infinity)
            }
            if endX < Double(viewport.width) {
                Rectangle().fill(wash)
                    .frame(width: Double(viewport.width) - max(0, endX))
                    .frame(maxHeight: .infinity)
                    .offset(x: max(0, endX))
            }
        }
        .padding(.top, Self.rulerHeight)
        .allowsHitTesting(false)
    }

    /// 切り抜きの範囲。開始を打ってから切り抜くまでのあいだ出しておく。
    @ViewBuilder
    private var extractOverlay: some View {
        if let range = store.pendingExtractRange {
            let x0 = TimelineScroll.viewportX(forTime: range.lowerBound,
                                              scrollX: offsetX, pixelsPerSecond: pps)
            let x1 = TimelineScroll.viewportX(forTime: range.upperBound,
                                              scrollX: offsetX, pixelsPerSecond: pps)
            Rectangle()
                .fill(Color.orange.opacity(0.16))
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color.orange).frame(width: 2)
                }
                .overlay(alignment: .trailing) {
                    Rectangle().fill(Color.orange.opacity(0.7)).frame(width: 1)
                }
                .frame(width: max(2, x1 - x0))
                .frame(maxHeight: .infinity)
                .offset(x: x0)
                .allowsHitTesting(false)
        }
    }

    /// 再生中、ヘッドが画面外に出そうになったら表示を送る。
    private func followPlayheadIfNeeded() {
        guard store.isPlaying, viewport.width > 0 else { return }
        let headX = TimelineScroll.contentX(forTime: store.currentTime, pixelsPerSecond: pps)
        let x = headX - offsetX
        if x > Double(viewport.width) - 80 {
            scrollX = min(maxScrollX, headX - Double(viewport.width) * 0.25)
        } else if x < 0 {
            scrollX = max(0, headX - Double(viewport.width) * 0.25)
        }
    }

    // MARK: - ズームとパン

    private func zoom(to newValue: Double, anchorX: Double) {
        let old = pps
        let clamped = min(Self.maxZoom, max(Self.minZoom, newValue))
        guard abs(clamped - old) > 1e-9 else { return }
        // カーソル（またはビューポート中央）の下にある時刻を動かさない。
        let next = TimelineScroll.anchoredScrollX(scrollX: offsetX, anchorX: anchorX,
                                                  oldPPS: old, newPPS: clamped)
        store.pixelsPerSecond = clamped
        scrollX = next
    }

    private func zoomStep(_ factor: Double) {
        let anchor = hoverPoint.map { Double($0.x) } ?? Double(viewport.width) / 2
        zoom(to: pps * factor, anchorX: anchor)
    }

    private func zoomToFit() {
        let span = max(store.contentEnd, store.outputEnd)
        guard span > 0, viewport.width > 0 else { return }
        let target = (Double(viewport.width) - 40) / span
        store.pixelsPerSecond = min(Self.maxZoom, max(Self.minZoom, target))
        scrollX = 0
    }

    private func pan(dx: Double, dy: Double) {
        scrollX = TimelineScroll.clamp(scrollX + dx,
                                       contentWidth: Double(contentWidth),
                                       viewportWidth: Double(viewport.width))
        scrollY = min(max(0, scrollY + dy), maxScrollY)
    }

    // MARK: - ホイール

    private func installWheelMonitor() {
        guard wheelMonitor == nil else { return }
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            // カーソルがタイムライン上にあるときだけ横取りする。
            // シートが出ている間は、その中のスクロールを奪わないよう手を出さない。
            guard let point = hoverPoint, NSApp.keyWindow?.isSheet != true else { return event }
            handleScroll(event, at: Double(point.x))
            return nil
        }
    }

    private func removeWheelMonitor() {
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
        wheelMonitor = nil
    }

    private func handleScroll(_ event: NSEvent, at anchorX: Double) {
        let flags = event.modifierFlags
        let precise = event.hasPreciseScrollingDeltas
        let rawX = Double(event.scrollingDeltaX)
        let rawY = Double(event.scrollingDeltaY)

        // ⌘ または ⌥ でズーム。カーソル位置の時刻を軸にする。
        if flags.contains(.command) || flags.contains(.option) {
            let amount = precise ? rawY : rawY * 4
            zoom(to: pps * exp(amount * 0.01), anchorX: anchorX)
            return
        }

        let d = TimelineWheel.route(deltaX: rawX, deltaY: rawY, precise: precise,
                                    shift: flags.contains(.shift),
                                    scrollY: offsetY, maxScrollY: maxScrollY)
        pan(dx: d.dx, dy: d.dy)
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let anchor = hoverPoint.map { Double($0.x) } ?? Double(viewport.width) / 2
                // 変化ぶんだけ倍率を当てる。
                zoom(to: pps * (1 + (value.magnification - 1) * 0.06), anchorX: anchor)
            }
    }

    // MARK: - 横スクロールバー

    /// レーンの縦スクロールバー。レーンの右端に浮かせる。
    ///
    /// 横と違って行を削れないので、帯を敷かずに重ねる。
    /// 動かす先が無いときは当たり判定ごと消して、クリップのクリックを奪わない。
    @ViewBuilder
    private var verticalScrollBar: some View {
        let lanesViewport = max(0, Double(viewport.height) - Double(Self.rulerHeight))
        let trackHeight = max(0, lanesViewport - 8)
        let ratio = lanesHeight > 0 ? min(1, lanesViewport / Double(lanesHeight)) : 1
        let thumb = max(28, trackHeight * ratio)
        let travel = max(0, trackHeight - thumb)
        let pos = maxScrollY > 0 ? (offsetY / maxScrollY) * travel : 0

        ZStack(alignment: .top) {
            Capsule().fill(Color.secondary.opacity(0.10))
            Capsule()
                .fill(Color.secondary.opacity(verticalBarGrabOffset == nil ? 0.35 : 0.6))
                .frame(height: thumb)
                .offset(y: pos)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if verticalBarGrabOffset == nil {
                                verticalBarGrabOffset = Double(value.startLocation.y) - pos
                            }
                            guard travel > 0, let grab = verticalBarGrabOffset else { return }
                            let newPos = Double(value.location.y) - grab
                            scrollY = min(max(0, newPos / travel * maxScrollY), maxScrollY)
                        }
                        .onEnded { _ in verticalBarGrabOffset = nil }
                )
        }
        .frame(width: 7, height: trackHeight)
        .padding(.top, Double(Self.rulerHeight) + 4)
        .padding(.trailing, 3)
        .opacity(maxScrollY > 0 ? 1 : 0)
        .allowsHitTesting(maxScrollY > 0)
    }

    private var scrollBar: some View {
        GeometryReader { geo in
            let trackWidth = Double(geo.size.width) - Double(Self.headerWidth) - 8
            let ratio = contentWidth > 0 ? min(1, Double(viewport.width) / Double(contentWidth)) : 1
            let thumb = max(36, trackWidth * ratio)
            let travel = max(0, trackWidth - thumb)
            let pos = maxScrollX > 0 ? (offsetX / maxScrollX) * travel : 0

            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.10))
                Capsule()
                    .fill(Color.secondary.opacity(scrollBarGrabOffset == nil ? 0.35 : 0.6))
                    .frame(width: thumb)
                    .offset(x: pos)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if scrollBarGrabOffset == nil {
                                    scrollBarGrabOffset = Double(value.startLocation.x) - pos
                                }
                                guard travel > 0, let grab = scrollBarGrabOffset else { return }
                                let newPos = Double(value.location.x) - grab
                                scrollX = min(max(0, newPos / travel * maxScrollX), maxScrollX)
                            }
                            .onEnded { _ in scrollBarGrabOffset = nil }
                    )
            }
            .frame(width: max(0, trackWidth), height: 7)
            .padding(.leading, Double(Self.headerWidth) + 4)
            .padding(.vertical, 3)
            .opacity(maxScrollX > 0 ? 1 : 0)
        }
        .frame(height: 13)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - キー操作

    /// 修飾キーなしのキーは、タイムラインにフォーカスがあるときだけ効かせる。
    /// こうしておけば一括編集やインスペクタでの文字入力を奪わない。
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        // ⌘C / ⌘X / ⌘V はメニューに載せない。載せると常に有効になり、
        // 文字入力中のコピー＆ペーストまで奪ってしまう。ここで受ければ
        // タイムラインにフォーカスがあるときだけ効く。
        if press.modifiers.contains(.command) {
            switch press.characters.lowercased() {
            case "c": store.copySelection(); return .handled
            case "x": store.cutSelection(); return .handled
            case "v": store.paste(); return .handled
            case "a":
                if press.modifiers.contains(.shift) {
                    store.selectedClipIDs = []
                } else {
                    store.selectAll()
                }
                return .handled
            default: return .ignored
            }
        }
        guard !press.modifiers.contains(.option), !press.modifiers.contains(.control) else {
            return .ignored
        }

        switch press.key {
        case .space:
            store.togglePlay(); return .handled
        case .leftArrow:
            store.step(frames: press.modifiers.contains(.shift) ? -10 : -1); return .handled
        case .rightArrow:
            store.step(frames: press.modifiers.contains(.shift) ? 10 : 1); return .handled
        case .delete, .deleteForward:
            store.deleteSelection(); return .handled
        case .clear:
            store.deleteSelection(); return .handled
        case .escape:
            // 切り抜きを打っている途中なら、まずそちらをやめる。
            if store.extractStart != nil {
                store.cancelExtract()
            } else {
                store.selectedClipIDs = []
            }
            return .handled
        default:
            break
        }
        // Delete キーは環境によって届く文字が違う（U+0008 / U+007F）。
        // KeyEquivalent での一致に漏れることがあるので、文字でも拾っておく。
        if let scalar = press.characters.unicodeScalars.first,
           scalar.value == 8 || scalar.value == 127 {
            store.deleteSelection()
            return .handled
        }

        switch press.characters.lowercased() {
        case "q": store.markExtractStart(); return .handled
        case "w": store.extractMarkedRange(); return .handled
        case "s": store.splitAtPlayhead(); return .handled
        case "d": store.duplicateSelection(); return .handled
        case "j": store.seek(to: store.currentTime - 1); return .handled
        case "l": store.seek(to: store.currentTime + 1); return .handled
        case "k": store.togglePlay(); return .handled
        case "=", "+": zoomStep(1.25); return .handled
        case "-": zoomStep(0.8); return .handled
        case "f": zoomToFit(); return .handled
        case "z": zoomToSelection(); return .handled
        default: return .ignored
        }
    }

    // MARK: - ドロップ

    private func handleDrop(urls: [URL], track: Track, at location: CGPoint) {
        // location はレーンの内容座標。スクロール量はすでに織り込まれている。
        let time = store.project.canvas.snap(
            TimelineScroll.time(atContentX: Double(location.x), pixelsPerSecond: pps))
        Task { @MainActor in
            let assets = await store.importAssets(urls: urls)
            var cursor = time
            for asset in assets where (track.kind == .audio) == (asset.kind == .audio) {
                store.addMediaClip(assetID: asset.id, trackID: track.id, at: cursor)
                cursor += asset.kind == .image ? 5 : asset.duration
            }
        }
    }
}

// MARK: - 目盛り

private struct RulerView: View {
    @Bindable var store: EditorStore
    let scrollX: Double
    /// 吸着の設定。実際に効かせるかは、ドラッグの最中に ⌥ を見て決める。
    let snappingEnabled: Bool

    /// マーカーのドラッグはここを基準に測る。マーカー自身のローカル座標で
    /// 測ると、動かした結果が次の入力に混ざって振動する。
    private static let spaceName = "nanovid.timeline.ruler"

    /// 掴んだ点とマーカーのズレ。掴んだ瞬間に決めて、離すまで変えない。
    @State private var grabOffset: Double?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                SwiftUI.Canvas { context, size in
                    drawOutsideOutput(&context, size: size)
                    drawTicks(&context, size: size)
                }
                .contentShape(Rectangle())
                .gesture(seekGesture)

                marker(.start, height: Double(geo.size.height), width: Double(geo.size.width))
                marker(.end, height: Double(geo.size.height), width: Double(geo.size.width))
            }
            .coordinateSpace(.named(Self.spaceName))
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var pps: Double { store.pixelsPerSecond }

    private func viewportX(_ time: Double) -> Double {
        TimelineScroll.viewportX(forTime: time, scrollX: scrollX, pixelsPerSecond: pps)
    }

    // MARK: 描画

    /// 書き出す範囲の外を伏せる。範囲を決めていなくても、クリップの終わりから
    /// 先は「動画に入らないところ」なので同じ扱いにする。
    private func drawOutsideOutput(_ context: inout GraphicsContext, size: CGSize) {
        let wash = GraphicsContext.Shading.color(.secondary.opacity(0.22))
        let startX = viewportX(store.outputStart)
        let endX = viewportX(store.outputEnd)

        if startX > 0 {
            context.fill(Path(CGRect(x: 0, y: 0,
                                     width: min(startX, Double(size.width)),
                                     height: Double(size.height))),
                         with: wash)
        }
        if endX < Double(size.width) {
            let x = max(0, endX)
            context.fill(Path(CGRect(x: x, y: 0,
                                     width: Double(size.width) - x,
                                     height: Double(size.height))),
                         with: wash)
        }
    }

    private func drawTicks(_ context: inout GraphicsContext, size: CGSize) {
        let spec = TickSpec.forRuler(pixelsPerSecond: pps)
        // 画面に映る範囲は内容座標で [scrollX, scrollX + 表示幅]。
        let count = spec.minorCount(width: Double(size.width) + scrollX, pixelsPerSecond: pps)
        for i in 0...max(0, count) {
            let isMajor = spec.isMajor(index: i)
            if !isMajor && !spec.showsMinor { continue }
            let t = spec.time(index: i)
            let x = CGFloat(viewportX(t))
            if x < -60 { continue }
            if x > size.width { break }

            // 範囲外は目盛りも薄くする。背景の濃淡だけに頼らずに済む。
            let fade = store.project.isInsideOutput(t) ? 1.0 : 0.45
            var line = Path()
            line.move(to: CGPoint(x: x, y: isMajor ? 4 : 13))
            line.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(line,
                           with: .color(.secondary.opacity((isMajor ? 0.55 : 0.22) * fade)),
                           lineWidth: 1)

            if isMajor {
                let text = Text(Format.rulerLabel(t, step: spec.major))
                    .font(.system(size: 9, design: .monospaced))
                var resolved = context.resolve(text)
                resolved.shading = .color(.secondary.opacity(fade))
                context.draw(resolved, at: CGPoint(x: x + 3, y: 2), anchor: .topLeading)
            }
        }
    }

    // MARK: 範囲のマーカー

    private enum Edge {
        case start, end
        var isStart: Bool { self == .start }
    }

    private func time(of edge: Edge) -> Double {
        edge.isStart ? store.outputStart : store.outputEnd
    }

    private func marker(_ edge: Edge, height: Double, width: Double) -> some View {
        let tab: Double = 9
        let x = viewportX(time(of: edge))
        // 画面の外に出たマーカーは消す。clipped() は描画を隠すだけで
        // クリックは奪ったままなので、当たり判定ごと外しておく。
        let visible = x >= -tab && x <= width + tab
        // 旗は範囲の内側に出す。開始は右向き、終了は左向き。
        return MarkerShape(pointingRight: edge.isStart)
            .fill(Color.accentColor)
            .frame(width: tab, height: height)
            .contentShape(Rectangle().inset(by: -4))
            .offset(x: edge.isStart ? x : x - tab)
            .gesture(dragGesture(edge))
            .help(edge.isStart ? "動画の開始位置" : "動画の終了位置")
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
    }

    private func dragGesture(_ edge: Edge) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.spaceName))
            .onChanged { value in
                // 掴んだ点は startLocation で決める。value.location だと
                // minimumDistance ぶんだけ掴み位置がずれて、最初に飛ぶ。
                let grab: Double
                if let existing = grabOffset {
                    grab = existing
                } else {
                    let startTime = TimelineScroll.time(atViewportX: Double(value.startLocation.x),
                                                        scrollX: scrollX, pixelsPerSecond: pps)
                    grab = startTime - time(of: edge)
                    grabOffset = grab
                }
                let pointer = TimelineScroll.time(atViewportX: Double(value.location.x),
                                                  scrollX: scrollX, pixelsPerSecond: pps)
                let target = TimelineSnap.resolve(pointerTime: pointer, grabOffset: grab,
                                                  targets: snapTargets(for: edge),
                                                  threshold: TimelineView.liveSnapThreshold(
                                                      pixelsPerSecond: pps,
                                                      enabled: snappingEnabled),
                                                  frameDuration: store.project.canvas.frameDuration)
                if edge.isStart {
                    store.setOutputStart(target, coalescing: "outputStart")
                } else {
                    store.setOutputEnd(target, coalescing: "outputEnd")
                }
            }
            .onEnded { _ in grabOffset = nil }
    }

    /// 吸着先はクリップの端と、もう一方のマーカー。
    private func snapTargets(for edge: Edge) -> [Double] {
        var targets: [Double] = [0, store.contentEnd]
        targets.append(edge.isStart ? store.outputEnd : store.outputStart)
        for track in store.project.tracks {
            for clip in track.clips {
                targets.append(clip.start)
                targets.append(clip.end)
            }
        }
        return targets
    }

    // MARK: 再生ヘッドの移動

    private var seekGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                store.pause()
                let t = TimelineScroll.time(atViewportX: Double(value.location.x),
                                            scrollX: scrollX, pixelsPerSecond: pps)
                store.seek(to: store.project.canvas.snap(t))
            }
    }
}

/// 範囲マーカーの旗。範囲の内側を向いた直角三角形と縦棒。
private struct MarkerShape: Shape {
    let pointingRight: Bool

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width
        let head = min(rect.height * 0.55, w * 1.2)
        if pointingRight {
            p.addRect(CGRect(x: 0, y: 0, width: 2, height: rect.height))
            p.move(to: CGPoint(x: 0, y: 0))
            p.addLine(to: CGPoint(x: w, y: 0))
            p.addLine(to: CGPoint(x: 0, y: head))
        } else {
            p.addRect(CGRect(x: w - 2, y: 0, width: 2, height: rect.height))
            p.move(to: CGPoint(x: w, y: 0))
            p.addLine(to: CGPoint(x: 0, y: 0))
            p.addLine(to: CGPoint(x: w, y: head))
        }
        p.closeSubpath()
        return p
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
                    mutate { $0.isHidden.toggle() }
                }
            }
            toggle(systemImage: track.isMuted ? "speaker.slash" : "speaker.wave.2", isOn: !track.isMuted) {
                mutate { $0.isMuted.toggle() }
            }
            toggle(systemImage: track.isLocked ? "lock" : "lock.open", isOn: !track.isLocked) {
                mutate { $0.isLocked.toggle() }
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

    private func mutate(_ body: @escaping (inout Track) -> Void) {
        store.edit { p in
            if let i = p.tracks.firstIndex(where: { $0.id == track.id }) {
                body(&p.tracks[i])
            }
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
