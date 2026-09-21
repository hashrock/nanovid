import Testing
import Foundation
import CoreMedia
@testable import Nanovid

/// 分割・トリム・移動などタイムライン編集の中身。
@MainActor
struct EditingTests {

    /// 4 秒の素材を 1 本だけ置いたプロジェクト。
    private func makeStore() -> (EditorStore, MediaAsset, UUID) {
        var project = Project.starter()
        let asset = MediaAsset(path: "/tmp/does-not-need-to-exist.mp4", displayName: "素材",
                               kind: .video, duration: 10, naturalSize: CGSize(width: 1920, height: 1080),
                               hasAudio: true, hasVideo: true)
        project.assets = [asset]
        let clip = Clip(name: "素材", start: 0, duration: 4,
                        content: .media(assetID: asset.id, sourceStart: 0))
        project.tracks[0].clips = [clip]
        let store = EditorStore(project: project)
        return (store, asset, clip.id)
    }

    @Test("分割すると素材内の開始位置もずれる")
    func splitAdjustsSourceStart() {
        let (store, _, clipID) = makeStore()
        store.selectedClipIDs = [clipID]
        store.currentTime = 1.5
        store.splitAtPlayhead()

        let clips = store.project.tracks[0].clips.sorted { $0.start < $1.start }
        #expect(clips.count == 2)
        #expect(abs(clips[0].start - 0) < 1e-9)
        #expect(abs(clips[0].duration - 1.5) < 1e-9)
        #expect(abs(clips[1].start - 1.5) < 1e-9)
        #expect(abs(clips[1].duration - 2.5) < 1e-9)

        guard case .media(_, let leftSource) = clips[0].content,
              case .media(_, let rightSource) = clips[1].content else {
            Issue.record("メディアクリップのままであるべき")
            return
        }
        #expect(abs(leftSource - 0) < 1e-9)
        #expect(abs(rightSource - 1.5) < 1e-9)
    }

    @Test("クリップの外では分割されない")
    func splitOutsideClipDoesNothing() {
        let (store, _, clipID) = makeStore()
        store.selectedClipIDs = [clipID]
        store.currentTime = 9.0
        store.splitAtPlayhead()
        #expect(store.project.tracks[0].clips.count == 1)
    }

    @Test("端ちょうどでは分割されない（長さ 0 のクリップを作らない）")
    func splitAtEdgeDoesNothing() {
        let (store, _, clipID) = makeStore()
        store.selectedClipIDs = [clipID]
        store.currentTime = 0
        store.splitAtPlayhead()
        #expect(store.project.tracks[0].clips.count == 1)

        store.currentTime = 4
        store.splitAtPlayhead()
        #expect(store.project.tracks[0].clips.count == 1)
    }

    @Test("フェードは分割で内側が消える")
    func splitDropsInnerFades() {
        let (store, _, clipID) = makeStore()
        store.updateSelectedClipsForTest(clipID) { $0.fade = Fade(inDuration: 0.5, outDuration: 0.5) }
        store.selectedClipIDs = [clipID]
        store.currentTime = 2
        store.splitAtPlayhead()

        let clips = store.project.tracks[0].clips.sorted { $0.start < $1.start }
        #expect(clips[0].fade.inDuration == 0.5)
        #expect(clips[0].fade.outDuration == 0)
        #expect(clips[1].fade.inDuration == 0)
        #expect(clips[1].fade.outDuration == 0.5)
    }

    @Test("左トリムは素材内の開始位置を同じだけ進める")
    func trimLeftShiftsSource() {
        let (store, _, clipID) = makeStore()
        store.trimLeft(clipID: clipID, to: 1.0)

        let clip = store.project.clip(clipID)!
        #expect(abs(clip.start - 1.0) < 1e-9)
        #expect(abs(clip.duration - 3.0) < 1e-9)
        guard case .media(_, let source) = clip.content else {
            Issue.record("メディアクリップのまま")
            return
        }
        #expect(abs(source - 1.0) < 1e-9)
    }

    @Test("左トリムは素材の先頭より手前へは戻れない")
    func trimLeftClampsAtSourceHead() {
        let (store, _, clipID) = makeStore()
        store.trimLeft(clipID: clipID, to: -5.0)
        let clip = store.project.clip(clipID)!
        #expect(clip.start >= 0)
        guard case .media(_, let source) = clip.content else { return }
        #expect(source >= 0)
    }

    @Test("右トリムは素材の残り尺で頭打ちになる")
    func trimRightClampsAtAssetEnd() {
        let (store, _, clipID) = makeStore()   // 素材 10 秒、クリップは 0..4
        store.trimRight(clipID: clipID, to: 999)
        let clip = store.project.clip(clipID)!
        #expect(abs(clip.duration - 10.0) < 1e-6)
    }

    @Test("トリムで 1 フレーム未満にはならない")
    func trimKeepsMinimumLength() {
        let (store, _, clipID) = makeStore()
        store.trimRight(clipID: clipID, to: 0)
        let clip = store.project.clip(clipID)!
        #expect(clip.duration >= store.project.canvas.frameDuration - 1e-9)
    }

    @Test("映像クリップは音声トラックへ移せない")
    func videoClipCannotMoveToAudioTrack() {
        let (store, _, clipID) = makeStore()
        let audioTrack = store.project.tracks.first { $0.kind == .audio }!
        store.move(clipID: clipID, toTrack: audioTrack.id, start: 0)
        #expect(store.project.track(containing: clipID)?.kind == .video)
    }

    @Test("別の映像トラックへは移せる")
    func videoClipMovesBetweenVideoTracks() {
        let (store, _, clipID) = makeStore()
        let target = store.project.tracks.filter { $0.kind == .video }[1]
        store.move(clipID: clipID, toTrack: target.id, start: 2.0)
        #expect(store.project.track(containing: clipID)?.id == target.id)
        #expect(abs(store.project.clip(clipID)!.start - 2.0) < 1e-9)
    }

    @Test("テキストクリップの既定フェードは 0")
    func textClipHasNoFadeByDefault() {
        let (store, _, _) = makeStore()
        let template = store.project.textTemplates[0]
        let track = store.project.tracks.filter { $0.kind == .video }[1]
        store.addTextClip(templateID: template.id, trackID: track.id, at: 0)

        let clip = store.project.tracks.first { $0.id == track.id }?.clips.first
        #expect(clip?.fade.inDuration == 0)
        #expect(clip?.fade.outDuration == 0)
    }

    @Test("再生ヘッドは尺の先へも出せる")
    func playheadCanGoPastTheEnd() {
        let (store, _, _) = makeStore()      // 4 秒のクリップが 1 本
        #expect(abs(store.duration - 4) < 1e-9)

        store.seek(to: 8)
        #expect(abs(store.currentTime - 8) < 1e-9, "尺を超えた位置で止まれるべき")
        #expect(store.isPastEnd)

        store.seek(to: 2)
        #expect(!store.isPastEnd)
    }

    @Test("再生ヘッドはタイムラインの描画範囲までで止まる")
    func playheadStopsAtTimelineEnd() {
        let (store, _, _) = makeStore()
        // 末尾の余白は拡大率で決まる。描いていない先へは行かせない。
        let expected = max(store.duration, 10) + EditorStore.trailingSlack / store.pixelsPerSecond
        store.seek(to: 9999)
        #expect(abs(store.currentTime - expected) < 1e-9)
        #expect(abs(store.timelineEnd - expected) < 1e-9)
    }

    @Test("拡大すると末尾の余白は狭くなる")
    func trailingSlackFollowsZoom() {
        let (store, _, _) = makeStore()
        store.pixelsPerSecond = 80
        let wide = store.timelineEnd
        store.pixelsPerSecond = 400
        #expect(store.timelineEnd < wide)
    }

    @Test("再生ヘッドは 0 より手前へは出ない")
    func playheadStopsAtZero() {
        let (store, _, _) = makeStore()
        store.seek(to: -5)
        #expect(store.currentTime == 0)
    }

    @Test("尺の先からでも再生は頭から始まる")
    func playFromPastEndRestarts() {
        let (store, _, _) = makeStore()
        store.seek(to: 8)
        store.play()
        #expect(store.currentTime == 0)
        store.pause()
    }

    @Test("尺の先にクリップを置ける")
    func canPlaceClipPastTheEnd() {
        let (store, _, _) = makeStore()
        let template = store.project.textTemplates[0]
        let track = store.project.tracks.filter { $0.kind == .video }[1]
        store.seek(to: 8)
        store.addTextClip(templateID: template.id, trackID: track.id, at: store.currentTime)

        let clip = store.project.tracks.first { $0.id == track.id }?.clips.first
        #expect(abs((clip?.start ?? -1) - 8) < 1e-9)
        #expect(store.duration > 8, "置いたぶん尺が伸びる")
    }

    @Test("undo で 1 操作ぶん戻る")
    func undoRestoresPreviousState() {
        let (store, _, clipID) = makeStore()
        store.selectedClipIDs = [clipID]
        store.currentTime = 2
        store.splitAtPlayhead()
        #expect(store.project.tracks[0].clips.count == 2)

        store.undo()
        #expect(store.project.tracks[0].clips.count == 1)

        store.redo()
        #expect(store.project.tracks[0].clips.count == 2)
    }

    @Test("文字入力のような連続編集は 1 つの undo にまとまる")
    func coalescedEditsCollapseIntoOneUndo() {
        var project = Project.starter()
        let template = project.textTemplates[0]
        let clip = Clip(start: 0, duration: 3,
                        content: .text(TextInstance(templateID: template.id)))
        project.tracks[1].clips = [clip]
        let store = EditorStore(project: project)

        let key = "bulk:\(clip.id):text"
        for text in ["あ", "あい", "あいう"] {
            store.setTextProp("text", to: .string(text), clipIDs: [clip.id], coalesceKey: key)
        }
        store.undo()

        let inst = store.project.clip(clip.id)?.content.textInstance
        #expect(inst?.props["text"] == nil, "3 回の入力がまとめて 1 回の undo で消えるべき")
    }
}

// テストから 1 クリップだけ書き換えるための補助。
extension EditorStore {
    func updateSelectedClipsForTest(_ id: UUID, _ body: (inout Clip) -> Void) {
        edit { p in
            for ti in p.tracks.indices {
                for ci in p.tracks[ti].clips.indices where p.tracks[ti].clips[ci].id == id {
                    body(&p.tracks[ti].clips[ci])
                }
            }
        }
    }
}
