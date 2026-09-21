import Testing
import Foundation
import CoreMedia
@testable import Nanovid

/// 書き出す範囲（動画のスタート位置・終了位置）。
struct OutputRangeTests {

    /// 0-4 秒と 6-10 秒に映像を置いたプロジェクト。
    private func makeProject() -> Project {
        var project = Project.starter()
        let asset = MediaAsset(path: "/tmp/does-not-need-to-exist.mp4", displayName: "素材",
                               kind: .video, duration: 30, naturalSize: CGSize(width: 1920, height: 1080),
                               hasAudio: true, hasVideo: true)
        project.assets = [asset]
        var first = Clip(name: "A", start: 0, duration: 4,
                         content: .media(assetID: asset.id, sourceStart: 2))
        first.fade = Fade(inDuration: 0.5, outDuration: 0.5)
        let second = Clip(name: "B", start: 6, duration: 4,
                          content: .media(assetID: asset.id, sourceStart: 0))
        project.tracks[0].clips = [first, second]
        return project
    }

    // MARK: 既定は追従

    @Test("範囲を決めていなければクリップの終わりが動画の終わり")
    func followsClipsByDefault() {
        let project = makeProject()
        #expect(project.outputRange == nil)
        #expect(project.outputStart == 0)
        #expect(project.outputEnd == 10)
        #expect(project.duration == 10)
        #expect(project.contentEnd == 10)
        #expect(!project.hasExplicitOutputRange)
    }

    @Test("範囲を決めたらクリップを足しても伸びない")
    func explicitRangeDoesNotFollowClips() {
        var project = makeProject()
        project.outputRange = OutputRange(start: 1, end: 5)
        project.tracks[0].clips.append(Clip(name: "C", start: 20, duration: 4,
                                            content: .text(TextInstance(templateID: UUID(), props: [:]))))
        #expect(project.contentEnd == 24)
        #expect(project.outputEnd == 5)
        #expect(project.duration == 4)
    }

    @Test("終了が開始より前に来たら開始で止める")
    func endNeverPrecedesStart() {
        var project = makeProject()
        project.outputRange = OutputRange(start: 6, end: 2)
        #expect(project.outputStart == 6)
        #expect(project.outputEnd == 6)
        #expect(project.duration == 0)
    }

    @Test("範囲の内と外を見分けられる")
    func knowsWhatIsInside() {
        var project = makeProject()
        project.outputRange = OutputRange(start: 2, end: 8)
        #expect(!project.isInsideOutput(1.9))
        #expect(project.isInsideOutput(2))
        #expect(project.isInsideOutput(5))
        #expect(project.isInsideOutput(8))
        #expect(!project.isInsideOutput(8.1))
    }

    // MARK: 切り出し

    @Test("範囲の外のクリップは落ちる")
    func cropDropsClipsOutside() {
        var project = makeProject()
        project.outputRange = OutputRange(start: 6, end: 10)
        let cropped = project.croppedToOutputRange()
        #expect(cropped.tracks[0].clips.map(\.name) == ["B"])
    }

    @Test("またがるクリップは切り詰められ、素材内の開始位置もずれる")
    func cropAdjustsSourceStart() throws {
        var project = makeProject()
        // フェードは邪魔なので外す。フェードの扱いは別のテストで見る。
        project.tracks[0].clips[0].fade = .none
        project.outputRange = OutputRange(start: 1, end: 3)
        let cropped = project.croppedToOutputRange()
        let clip = try #require(cropped.tracks[0].clips.first)
        // 時刻はそのまま。範囲の頭出しは書き出し側でそろえる。
        #expect(clip.start == 1)
        #expect(clip.duration == 2)
        // 頭を 1 秒落としたぶん、素材の読み出し位置も 1 秒進む。
        if case .media(_, let sourceStart) = clip.content {
            #expect(sourceStart == 3)
        } else {
            Issue.record("メディアクリップのはず")
        }
    }

    @Test("フェードの途中では端を落とさない")
    func cropKeepsClipsWhoseFadeWouldBeCut() throws {
        var project = makeProject()
        // A(0-4, フェード 0.5/0.5)。頭を 0.2 秒落とすとフェードインの最中になる。
        project.outputRange = OutputRange(start: 0.2, end: 3.0)
        let clip = try #require(project.croppedToOutputRange().tracks[0].clips.first)
        // 切ると、切った先から改めて 0 から立ち上がってしまう。だから切らない。
        #expect(clip.start == 0)
        #expect(abs(clip.fade.inDuration - 0.5) < 1e-9)
        // 尻は 1 秒落とす。フェードアウト(0.5)より長いので、切っても見え方は変わらない。
        #expect(abs(clip.duration - 3.0) < 1e-9)
        #expect(clip.fade.outDuration == 0)
    }

    @Test("フェードより外側なら端を落とす")
    func cropTrimsBeyondTheFade() throws {
        var project = makeProject()
        // A(0-4, フェード 0.5/0.5) の頭 1 秒を落とす。フェードインは済んでいる。
        project.outputRange = OutputRange(start: 1.0, end: 4.0)
        let clip = try #require(project.croppedToOutputRange().tracks[0].clips.first)
        #expect(clip.start == 1.0)
        #expect(abs(clip.duration - 3.0) < 1e-9)
        #expect(clip.fade.inDuration == 0)
        if case .media(_, let sourceStart) = clip.content {
            #expect(abs(sourceStart - 3.0) < 1e-9, "素材の読み出し位置も 1 秒進む")
        }
    }

    @Test("範囲を決めていなければ切り出しても中身は変わらない")
    func cropIsIdentityWithoutRange() {
        let project = makeProject()
        #expect(project.croppedToOutputRange().tracks == project.tracks)
    }

    // MARK: 保存

    @Test("古いプロジェクトには範囲が無くても読める")
    func decodesFileWithoutRange() throws {
        var project = makeProject()
        project.outputRange = nil
        let data = try JSONEncoder().encode(project)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["outputRange"] == nil, "決めていない範囲は書き出さない")

        let reloaded = try JSONDecoder().decode(Project.self, from: data)
        #expect(reloaded.outputRange == nil)
        #expect(reloaded.outputEnd == 10)
    }

    @Test("決めた範囲は保存して読み戻せる")
    func roundTripsExplicitRange() throws {
        var project = makeProject()
        project.outputRange = OutputRange(start: 1.5, end: 7.25)
        let reloaded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        #expect(reloaded.outputRange == OutputRange(start: 1.5, end: 7.25))
    }
}

/// マーカーを動かす操作。
@MainActor
struct OutputRangeCommandTests {

    private func makeStore() -> EditorStore {
        var project = Project.starter()
        project.tracks[0].clips = [Clip(name: "A", start: 0, duration: 10,
                                        content: .text(TextInstance(templateID: UUID(), props: [:])))]
        return EditorStore(project: project)
    }

    @Test("開始を動かしても終了は動かない")
    func movingStartKeepsEnd() {
        let store = makeStore()
        store.setOutputStart(2)
        #expect(store.outputStart == 2)
        #expect(store.outputEnd == 10)
        #expect(store.duration == 8)
    }

    @Test("終了を動かしても開始は動かない")
    func movingEndKeepsStart() {
        let store = makeStore()
        store.setOutputStart(2)
        store.setOutputEnd(6)
        #expect(store.outputStart == 2)
        #expect(store.outputEnd == 6)
    }

    @Test("長さを決めると終了が動く")
    func settingDurationMovesEnd() {
        let store = makeStore()
        store.setOutputStart(1)
        store.setOutputDuration(3)
        #expect(store.outputStart == 1)
        #expect(store.outputEnd == 4)
        #expect(store.duration == 3)
    }

    @Test("開始は終了を追い越さない")
    func startCannotPassEnd() {
        let store = makeStore()
        store.setOutputEnd(4)
        store.setOutputStart(9)
        #expect(store.outputStart < store.outputEnd)
        #expect(abs(store.duration - store.project.canvas.frameDuration) < 1e-9)
    }

    @Test("終了は開始を追い越さない")
    func endCannotPassStart() {
        let store = makeStore()
        store.setOutputStart(4)
        store.setOutputEnd(1)
        #expect(store.outputStart == 4)
        #expect(abs(store.outputEnd - (4 + store.project.canvas.frameDuration)) < 1e-9)
    }

    @Test("負の時刻には行かない")
    func clampsAtZero() {
        let store = makeStore()
        store.setOutputStart(-5)
        #expect(store.outputStart == 0)
    }

    @Test("マーカーはフレーム境界に乗る")
    func snapsToFrames() {
        let store = makeStore()
        store.setOutputStart(1.0 / 60)      // 30fps の半フレーム
        #expect(abs(store.outputStart - store.project.canvas.frameDuration) < 1e-9)
    }

    @Test("自動に戻すとクリップに追従する")
    func resetReturnsToFollowingClips() {
        let store = makeStore()
        store.setOutputEnd(3)
        #expect(store.project.hasExplicitOutputRange)
        store.resetOutputRange()
        #expect(!store.project.hasExplicitOutputRange)
        #expect(store.outputEnd == 10)
    }

    @Test("マーカーを動かすのは取り消せる")
    func movingMarkersIsUndoable() {
        let store = makeStore()
        store.setOutputEnd(3)
        store.undo()
        #expect(store.project.outputRange == nil)
    }

    @Test("ドラッグ中の連続した移動は 1 回の取り消しにまとまる")
    func draggingCoalescesIntoOneUndo() {
        let store = makeStore()
        for t in stride(from: 9.0, through: 5.0, by: -0.5) {
            store.setOutputEnd(t, coalescing: "outputEnd")
        }
        #expect(store.outputEnd == 5)
        store.undo()
        #expect(store.project.outputRange == nil, "ドラッグ全体で 1 回ぶんのはず")
    }

    @Test("再生は範囲の頭から始まって終わりで止まる")
    func playbackStartsAtTheRangeStart() {
        let store = makeStore()
        store.setOutputStart(2)
        store.setOutputEnd(6)
        store.seek(to: 0)
        store.play()
        #expect(store.currentTime == 2, "範囲より手前にいたら頭出しする")
        store.pause()
    }
}
