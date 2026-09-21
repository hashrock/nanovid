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
    @State private var drag: ClipDrag?
    @State private var dropTargetTrack: UUID?
    @State private var hoveredClipID: UUID?

    private var pps: Double { store.pixelsPerSecond }

    /// 表示順。映像は前面が上、音声はその下にまとめる。
    private var lanes: [Track] {
        let video = store.project.tracks.filter { $0.kind == .video }.reversed()
        let audio = store.project.tracks.filter { $0.kind == .audio }
        return Array(video) + audio
    }

    private var contentWidth: CGFloat {
        // 末尾にも少し余白を持たせて、終端の先へ置けるようにする。
        CGFloat(TimelineScroll.contentX(forTime: max(store.duration, 10),
                                        pixelsPerSecond: pps)) + 400
    }

    private var lanesHeight: CGFloat {
        CGFloat(lanes.count) * (Self.laneHeight + Self.laneGap)
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
            BottomTabPicker(selection: $bottomTab, textCount: store.project.allTextClips.count)

            Divider().frame(height: 16)

            Text(Format.timecode(store.currentTime, fps: store.project.canvas.fps))
                .font(.system(.callout, design: .monospaced))
            Text("/ \(Format.timecode(store.duration, fps: store.project.canvas.fps))")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

            Divider().frame(height: 16)

            Button { store.splitAtPlayhead() } label: { Label("分割", systemImage: "scissors") }
                .help("再生ヘッドの位置でクリップを分割 (S)")
            Button { store.deleteSelection() } label: { Label("削除", systemImage: "trash") }
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

    // MARK: - トラックヘッダ

    private var headerColumn: some View {
        VStack(spacing: 0) {
            Color.clear.frame(width: Self.headerWidth, height: Self.rulerHeight)
            VStack(spacing: 0) {
                ForEach(lanes) { track in
                    TrackHeaderView(store: store, track: track)
                        .frame(width: Self.headerWidth, height: Self.laneHeight)
                        .padding(.bottom, Self.laneGap)
                }
            }
            .offset(y: -offsetY)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .clipped()
        }
        .frame(width: Self.headerWidth)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - レーン表示領域

    private var laneArea: some View {
        GeometryReader { geo in
            // レーンの中身はビューポートより広いので、各段に実寸の幅を与えて左端に固定する。
            // maxWidth: .infinity だけだと VStack が内容幅まで広がり、目盛りが中央寄せされてしまう。
            VStack(alignment: .leading, spacing: 0) {
                // 目盛りは縦スクロールしない。横だけ追従させる。
                RulerView(store: store, scrollX: offsetX)
                    .frame(width: geo.size.width, height: Self.rulerHeight, alignment: .topLeading)
                    .clipped()

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
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .overlay(alignment: .topLeading) { playhead }
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
                .onTapGesture { store.selectedClipIDs = [] }
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
                     isSelected: isSelected, isDragging: drag?.clipID == clip.id)
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
        .offset(y: drag?.clipID == clip.id ? CGFloat(drag?.laneOffset ?? 0) : 0)
        .zIndex(drag?.clipID == clip.id ? 10 : 0)
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
                            targets: snapTargets(excluding: clip.id), threshold: snapThreshold,
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
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.laneSpaceName))
            .onChanged { value in
                guard !track.isLocked else { return }
                let pointer = pointerTime(value.location)
                if drag == nil {
                    // 掴んだ基準は startLocation から取る。最初の onChanged が届く時点では
                    // ポインタが minimumDistance ぶん進んでいるので、location だと
                    // その移動量を飲み込んでカーソルから遅れてしまう。
                    drag = ClipDrag(clipID: clip.id, mode: .move,
                                    grabOffset: pointerTime(value.startLocation) - clip.start,
                                    grabY: Double(value.startLocation.y))
                    if !store.selectedClipIDs.contains(clip.id) {
                        store.select(clipID: clip.id, extend: false)
                    }
                }
                guard var current = drag, current.mode == .move, current.clipID == clip.id else { return }
                let resolved = TimelineSnap.resolve(
                    pointerTime: pointer, grabOffset: current.grabOffset,
                    targets: snapTargets(excluding: clip.id), threshold: snapThreshold,
                    frameDuration: store.project.canvas.frameDuration)
                current.deltaSeconds = resolved - clip.start
                let laneStep = Double(Self.laneHeight + Self.laneGap)
                current.laneDelta = Int(((Double(value.location.y) - current.grabY) / laneStep).rounded())
                drag = current
            }
            .onEnded { _ in
                defer { drag = nil }
                guard let d = drag, d.clipID == clip.id, d.mode == .move else { return }
                let newStart = max(0, clip.start + d.deltaSeconds)
                let targetTrack = laneTrack(from: track, offset: d.laneDelta) ?? track
                store.move(clipID: clip.id, toTrack: targetTrack.id, start: newStart)
            }
    }

    private func laneTrack(from track: Track, offset: Int) -> Track? {
        guard let index = lanes.firstIndex(where: { $0.id == track.id }) else { return nil }
        let target = index + offset
        guard lanes.indices.contains(target) else { return nil }
        return lanes[target]
    }

    // MARK: - スナップ

    /// 吸着が効く距離。画面上 8pt ぶんを時間に直す。
    private var snapThreshold: Double { 8.0 / pps }

    /// 吸着先。自分以外のクリップ端・再生ヘッド・原点。
    private func snapTargets(excluding clipID: UUID) -> [Double] {
        var targets: [Double] = [0, store.currentTime]
        for track in store.project.tracks {
            for c in track.clips where c.id != clipID {
                targets.append(c.start)
                targets.append(c.end)
            }
        }
        return targets
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
        guard store.duration > 0, viewport.width > 0 else { return }
        let target = (Double(viewport.width) - 40) / store.duration
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

        var dx = -rawX
        var dy = -rawY
        if flags.contains(.shift) {
            // ⇧ で横パン固定。
            dx = -(abs(rawX) > abs(rawY) ? rawX : rawY)
            dy = 0
        } else if abs(rawX) < 0.01 && maxScrollY <= 0 {
            // 縦に動かす先が無いマウスホイールは横パンに回す。
            dx = -rawY
            dy = 0
        }
        let scale = precise ? 1.0 : 6.0
        pan(dx: dx * scale, dy: dy * scale)
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
        case "=", "+": zoomStep(1.25); return .handled
        case "-": zoomStep(0.8); return .handled
        case "f": zoomToFit(); return .handled
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

    var body: some View {
        let pps = store.pixelsPerSecond
        let spec = TickSpec.forRuler(pixelsPerSecond: pps)
        SwiftUI.Canvas { context, size in
            let labelColor = Color.secondary
            // 画面に映る範囲は内容座標で [scrollX, scrollX + 表示幅]。
            let count = spec.minorCount(width: Double(size.width) + scrollX, pixelsPerSecond: pps)
            for i in 0...max(0, count) {
                let isMajor = spec.isMajor(index: i)
                if !isMajor && !spec.showsMinor { continue }
                let t = spec.time(index: i)
                let x = CGFloat(TimelineScroll.viewportX(forTime: t, scrollX: scrollX,
                                                        pixelsPerSecond: pps))
                if x < -60 { continue }
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
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    store.pause()
                    let t = TimelineScroll.time(atViewportX: Double(value.location.x),
                                                scrollX: scrollX, pixelsPerSecond: pps)
                    store.seek(to: store.project.canvas.snap(t))
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
