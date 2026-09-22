import AVFoundation
import Combine
import Foundation
import Observation

/// 編集状態の唯一の持ち主。Project は値型なので、スナップショットを積むだけで undo になる。
@Observable
final class EditorStore {

    // MARK: 状態

    var project: Project {
        didSet { if project != oldValue { scheduleRebuild() } }
    }
    var documentURL: URL?
    var hasUnsavedChanges = false

    /// 選択中のクリップ。複数選択で一括編集する。
    var selectedClipIDs: Set<UUID> = []
    var selectedTrackID: UUID?

    var currentTime: Double = 0
    var isPlaying = false

    /// タイムラインの拡大率（1 秒あたりのポイント数）。
    var pixelsPerSecond: Double = 80

    var buildError: String?
    var isBuilding = false
    /// 切り抜きの開始点。打っている間だけタイムラインに範囲が出る。
    /// プロジェクトには保存しない（編集中の目印なので）。
    var extractStart: Double?

    /// 字幕の自動生成の進み具合。nil なら動いていない。
    var subtitleProgress: SubtitleProgress?
    /// 動いている書き起こし。中止のために持っておく（型は macOS 26 限定なので AnyObject）。
    @ObservationIgnored var transcriberHandle: AnyObject?

    // 取り消しの可否。スタック自体は観測の対象外なので、
    // メニューの有効・無効が追従するようここに写しておく。
    private(set) var canUndo = false
    private(set) var canRedo = false

    @ObservationIgnored let player = AVPlayer()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var itemStatusObservation: NSKeyValueObservation?
    @ObservationIgnored private var playbackFailureObserver: NSObjectProtocol?
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    @ObservationIgnored private var lastCoalesceKey: String?
    @ObservationIgnored private var lastCoalesceAt: Date = .distantPast
    @ObservationIgnored private var undoStack: [Project] = []
    @ObservationIgnored private var redoStack: [Project] = []
    @ObservationIgnored private let undoLimit = 100
    /// rebuild を待たずに済む編集（再生位置の移動など）と区別するための世代番号。
    @ObservationIgnored private var buildGeneration = 0

    var baseURL: URL? { documentURL?.deletingLastPathComponent() }

    /// 書き出される動画の尺。範囲を決めていなければクリップの終端まで。
    var duration: Double { project.duration }

    /// クリップが置かれている末尾。
    var contentEnd: Double { project.contentEnd }

    /// 書き出す範囲。
    var outputStart: Double { project.outputStart }
    var outputEnd: Double { project.outputEnd }

    /// タイムラインの末尾に足す余白(pt)。ここまで再生ヘッドを動かせる。
    /// 末尾より先にクリップを置きたいことがあるため。
    static let trailingSlack: Double = 400

    /// 再生ヘッドを動かせる上限。描画しているタイムラインの範囲と一致させてある。
    var timelineEnd: Double {
        max(max(contentEnd, outputEnd), 10) + Self.trailingSlack / max(pixelsPerSecond, 1)
    }

    // MARK: 初期化

    init(project: Project = .starter()) {
        self.project = project
        player.actionAtItemEnd = .pause
        installTimeObserver()
        scheduleRebuild()
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        itemStatusObservation?.invalidate()
        if let playbackFailureObserver { NotificationCenter.default.removeObserver(playbackFailureObserver) }
    }

    private func installTimeObserver() {
        let interval = CMTime(seconds: 1.0 / 60.0, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] t in
            guard let self, self.isPlaying else { return }
            self.currentTime = t.secondsOrZero
            if self.currentTime >= self.outputEnd - 1e-3 {
                self.pause()
            }
        }
    }

    // MARK: 再生

    func play() {
        guard duration > 0 else { return }
        // 範囲の外や末尾にいるときは範囲の頭から鳴らす。
        if currentTime < outputStart - 1e-9 || currentTime >= outputEnd - 1e-3 {
            seek(to: outputStart)
        }
        isPlaying = true
        player.play()
    }

    func pause() {
        isPlaying = false
        player.pause()
        currentTime = player.currentTime().secondsOrZero
    }

    func togglePlay() { isPlaying ? pause() : play() }

    func seek(to time: Double) {
        // 再生ヘッドは尺の先へも出せる。プレビューは AVPlayer 側で末尾に張り付くので、
        // 尺を超えた位置ではプレビューに「ここから先は空」と出す（PreviewPane）。
        let clamped = max(0, min(timelineEnd, time))
        currentTime = clamped
        player.seek(to: min(clamped, max(contentEnd, outputEnd)).cmTime,
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// 再生ヘッドが書き出す範囲の外にあるか。
    var isOutsideOutput: Bool { !project.isInsideOutput(currentTime) }

    func step(frames: Int) {
        pause()
        seek(to: project.canvas.snap(currentTime + Double(frames) * project.canvas.frameDuration))
    }

    // MARK: コンポジションの再構築

    /// 編集のたびに呼ばれる。連続操作でまとめて 1 回だけ組み直す。
    private func scheduleRebuild() {
        hasUnsavedChanges = true
        buildGeneration += 1
        let generation = buildGeneration
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self else { return }
            await self.rebuild(generation: generation)
        }
    }

    func rebuildNow() async {
        buildGeneration += 1
        await rebuild(generation: buildGeneration)
    }

    @MainActor
    private func rebuild(generation: Int) async {
        let snapshot = project
        let base = baseURL
        isBuilding = true
        defer { isBuilding = false }

        do {
            let built = try await Task.detached(priority: .userInitiated) {
                try await CompositionBuilder.build(project: snapshot, baseURL: base)
            }.value
            guard generation == buildGeneration else { return }

            let item = AVPlayerItem(asset: built.composition)
            item.videoComposition = built.videoComposition
            item.audioMix = built.audioMix
            item.seekingWaitsForVideoCompositionRendering = true

            let resume = isPlaying
            player.replaceCurrentItem(with: item)
            watchForPlaybackFailure(of: item)
            await seekBounded(to: min(currentTime, built.duration).cmTime)
            if resume { player.play() }
            buildError = nil
        } catch is CancellationError {
            return
        } catch {
            guard generation == buildGeneration else { return }
            if case BuildError.emptyProject = error {
                player.replaceCurrentItem(with: nil)
                stopWatchingPlaybackFailure()
                buildError = nil
            } else {
                buildError = error.localizedDescription
            }
        }
    }

    /// シークの完了を待つが、待ちすぎない。
    ///
    /// seekingWaitsForVideoCompositionRendering を立てていると、完了が二度と
    /// 呼ばれないことがある（FB9877123。Apple も「想定外の挙動」と認めている）。
    /// ここで待ち続けると rebuild が戻らず、isBuilding が立ったままになる。
    /// 普段は数十 ms で済むので、1 秒待って来なければ先へ進む。
    private func seekBounded(to time: CMTime) async {
        let player = self.player
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(1))
            }
            await group.next()
            group.cancelAll()
        }
    }

    // MARK: 再生の失敗

    /// 組み上がったあとで転ける経路を見張る。
    ///
    /// 組む時点で確かめられるのはファイルの存在まで。そのあとで素材を動かされたり、
    /// デコーダが対応していなかったりすると、AVPlayer は何も言わずに止まる。
    /// ここで拾って、組み立ての失敗と同じ場所（buildError）に出す。
    private func watchForPlaybackFailure(of item: AVPlayerItem) {
        stopWatchingPlaybackFailure()

        // 読み込みの失敗。status が .failed になるのは item ごとに一度きり。
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let message = item.error?.localizedDescription ?? "不明なエラー"
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem === item else { return }
                self.isPlaying = false
                self.buildError = "プレビューを再生できません: \(message)"
            }
        }

        // 途中まで再生できたあとの失敗。壊れた区間に差しかかったときなど。
        playbackFailureObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] note in
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isPlaying = false
                self.buildError = "再生の途中で止まりました: \(error?.localizedDescription ?? "不明なエラー")"
            }
        }
    }

    private func stopWatchingPlaybackFailure() {
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        if let playbackFailureObserver {
            NotificationCenter.default.removeObserver(playbackFailureObserver)
            self.playbackFailureObserver = nil
        }
    }

    // MARK: Undo / Redo

    /// 変更を加える前に呼ぶ。1 操作 = 1 スナップショット。
    func checkpoint() {
        lastCoalesceKey = nil
        undoStack.append(project)
        if undoStack.count > undoLimit { undoStack.removeFirst() }
        redoStack.removeAll()
        refreshHistoryFlags()
    }

    /// checkpoint とミューテーションをまとめて行う。
    func edit(_ body: (inout Project) -> Void) {
        edit(coalescing: nil, body)
    }

    /// 同じ key の連続編集（文字入力など）は 1 つの undo にまとめる。
    func edit(coalescing key: String?, _ body: (inout Project) -> Void) {
        let now = Date()
        let continues = key != nil && key == lastCoalesceKey
            && now.timeIntervalSince(lastCoalesceAt) < 1.5
        if !continues { checkpoint() }
        lastCoalesceKey = key
        lastCoalesceAt = now
        var copy = project
        body(&copy)
        project = copy
    }

    /// 取り消しの履歴を捨てる。別のプロジェクトを開いたあとに
    /// 前のプロジェクトへ戻れてしまわないようにする。
    func resetHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
        lastCoalesceKey = nil
        refreshHistoryFlags()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(project)
        project = previous
        refreshHistoryFlags()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(project)
        project = next
        refreshHistoryFlags()
    }

    private func refreshHistoryFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }
}
