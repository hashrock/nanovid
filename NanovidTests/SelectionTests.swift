import Testing
import Foundation
@testable import Nanovid

/// 複数選択と、そこから使う操作。
@MainActor
struct SelectionTests {

    /// 映像トラックに 0-2 / 3-5 / 6-8、テロップに 1-2 / 5.5-6.5 を置いたもの。
    private func makeStore() -> EditorStore {
        var project = Project.starter()
        let asset = MediaAsset(path: "/tmp/x.mp4", displayName: "素材", kind: .video,
                               duration: 60, naturalSize: CGSize(width: 1920, height: 1080),
                               hasAudio: false, hasVideo: true)
        project.assets = [asset]
        project.tracks[0].clips = [
            Clip(start: 0, duration: 2, content: .media(assetID: asset.id, sourceStart: 0)),
            Clip(start: 3, duration: 2, content: .media(assetID: asset.id, sourceStart: 0)),
            Clip(start: 6, duration: 2, content: .media(assetID: asset.id, sourceStart: 0)),
        ]
        let template = project.textTemplates[0]
        project.tracks[1].clips = [
            Clip(start: 1, duration: 1, content: .text(TextInstance(templateID: template.id))),
            Clip(start: 5.5, duration: 1, content: .text(TextInstance(templateID: template.id))),
        ]
        return EditorStore(project: project)
    }

    /// 画面の表示順（映像は前面が上、音声はその下）。
    private func laneOrder(_ store: EditorStore) -> [UUID] {
        let video = store.project.tracks.filter { $0.kind == .video }.reversed()
        let audio = store.project.tracks.filter { $0.kind == .audio }
        return (Array(video) + audio).map(\.id)
    }

    private func clip(_ store: EditorStore, track: Int, at start: Double) -> Clip? {
        store.project.tracks[track].clips.first { abs($0.start - start) < 1e-6 }
    }

    // MARK: - 選択

    @Test("すべて選択")
    func selectAll() {
        let store = makeStore()
        store.selectAll()
        #expect(store.selectedClipIDs.count == 5)
    }

    @Test("ロックしたトラックは選ばれない")
    func lockedTracksAreSkipped() {
        let store = makeStore()
        store.edit { $0.tracks[1].isLocked = true }
        store.selectAll()
        #expect(store.selectedClipIDs.count == 3)
    }

    @Test("囲んだ時間と重なるクリップが選ばれる")
    func marqueeSelectsOverlapping() {
        let store = makeStore()
        let videoTrack = store.project.tracks[0]
        store.selectClips(inTimeRange: 2.5...5.5, trackIDs: [videoTrack.id], additive: false)
        #expect(store.selectedClipIDs.count == 1)
        #expect(store.selectedClipIDs.contains(clip(store, track: 0, at: 3)!.id))
    }

    @Test("端がかすっただけでも選ばれる")
    func marqueeIncludesPartialOverlap() {
        let store = makeStore()
        store.selectClips(inTimeRange: 1.5...3.5,
                          trackIDs: [store.project.tracks[0].id], additive: false)
        // 0-2 と 3-5 の両方にかかる
        #expect(store.selectedClipIDs.count == 2)
    }

    @Test("囲みに入っていないトラックは無視する")
    func marqueeRespectsTracks() {
        let store = makeStore()
        store.selectClips(inTimeRange: 0...10,
                          trackIDs: [store.project.tracks[1].id], additive: false)
        #expect(store.selectedClipIDs.count == 2)
    }

    @Test("複数トラックにまたがって囲める")
    func marqueeSpansTracks() {
        let store = makeStore()
        store.selectClips(inTimeRange: 0.5...1.5,
                          trackIDs: [store.project.tracks[0].id, store.project.tracks[1].id],
                          additive: false)
        #expect(store.selectedClipIDs.count == 2)
    }

    @Test("⇧ドラッグはもとの選択に足す")
    func marqueeIsAdditive() {
        let store = makeStore()
        let first = clip(store, track: 0, at: 0)!.id
        store.selectedClipIDs = [first]
        store.selectClips(inTimeRange: 6.5...7.5,
                          trackIDs: [store.project.tracks[0].id],
                          additive: true, base: [first])
        #expect(store.selectedClipIDs.count == 2)
        #expect(store.selectedClipIDs.contains(first))
    }

    @Test("囲み直すと前の選択は消える")
    func marqueeReplacesByDefault() {
        let store = makeStore()
        store.selectedClipIDs = [clip(store, track: 0, at: 0)!.id]
        store.selectClips(inTimeRange: 6.5...7.5,
                          trackIDs: [store.project.tracks[0].id], additive: false)
        #expect(store.selectedClipIDs.count == 1)
        #expect(store.selectedClipIDs.contains(clip(store, track: 0, at: 6)!.id))
    }

    // MARK: - まとめて移動

    @Test("互いの位置関係を保ったまま動く")
    func moveKeepsRelativePositions() {
        let store = makeStore()
        let ids: Set<UUID> = [clip(store, track: 0, at: 0)!.id, clip(store, track: 0, at: 3)!.id]
        store.moveClips(ids, deltaSeconds: 1, laneDelta: 0, laneOrder: laneOrder(store))

        #expect(clip(store, track: 0, at: 1) != nil)
        #expect(clip(store, track: 0, at: 4) != nil)
        #expect(clip(store, track: 0, at: 6) != nil, "選んでいないものは動かない")
    }

    @Test("先頭が 0 より手前へ出ないように寄せる")
    func moveClampsAtZero() {
        let store = makeStore()
        let ids: Set<UUID> = [clip(store, track: 0, at: 3)!.id, clip(store, track: 0, at: 6)!.id]
        store.moveClips(ids, deltaSeconds: -10, laneDelta: 0, laneOrder: laneOrder(store))
        // 3 が 0 まで下がるぶん（-3）しか動かない。6 は 3 へ。
        #expect(clip(store, track: 0, at: 0) != nil)
        #expect(clip(store, track: 0, at: 3) != nil)
    }

    @Test("段の移動は全部が移せるときだけ通る")
    func laneMoveIsAllOrNothing() {
        let store = makeStore()
        // テロップ(段 0) と 映像1(段 1) から 1 段下げると、映像のクリップが音声トラックへ行く。
        let ids: Set<UUID> = [clip(store, track: 1, at: 1)!.id, clip(store, track: 0, at: 0)!.id]
        store.moveClips(ids, deltaSeconds: 0, laneDelta: 1, laneOrder: laneOrder(store))

        #expect(store.project.track(containing: clip(store, track: 1, at: 1)!.id)?.kind == .video)
        #expect(store.project.tracks[2].clips.isEmpty, "音声トラックへは落ちない")
    }

    @Test("移せる段なら全部が移る")
    func laneMoveSucceedsWhenValid() {
        let store = makeStore()
        // テロップ(段 0) のクリップだけを 1 段下げる → 映像1 へ
        let id = clip(store, track: 1, at: 1)!.id
        let target = store.project.tracks[0].id
        store.moveClips([id], deltaSeconds: 0, laneDelta: 1, laneOrder: laneOrder(store))
        #expect(store.project.track(containing: id)?.id == target)
    }

    @Test("ロックしたトラックのものは動かさない")
    func lockedClipsDoNotMove() {
        let store = makeStore()
        store.edit { $0.tracks[0].isLocked = true }
        let id = clip(store, track: 0, at: 3)!.id
        store.moveClips([id], deltaSeconds: 2, laneDelta: 0, laneOrder: laneOrder(store))
        #expect(clip(store, track: 0, at: 3) != nil)
    }

    // MARK: - 削除して詰める

    @Test("消したぶんだけ後ろが前へ詰まる")
    func rippleDeleteShiftsLaterClips() {
        let store = makeStore()
        store.selectedClipIDs = [clip(store, track: 0, at: 3)!.id]   // 3-5 を抜く
        store.rippleDeleteSelection()

        #expect(store.project.tracks[0].clips.count == 2)
        #expect(clip(store, track: 0, at: 0) != nil)
        #expect(clip(store, track: 0, at: 4) != nil, "6-8 が 2 秒ぶん前へ")
        // 別トラックもそろえて詰まる
        #expect(clip(store, track: 1, at: 1) != nil)
        #expect(clip(store, track: 1, at: 3.5) != nil, "5.5 が 2 秒ぶん前へ")
        #expect(store.selectedClipIDs.isEmpty)
    }

    @Test("離れた複数の区間をまとめて抜ける")
    func rippleDeleteHandlesMultipleRanges() {
        let store = makeStore()
        store.selectedClipIDs = [clip(store, track: 0, at: 0)!.id,
                                 clip(store, track: 0, at: 3)!.id]
        store.rippleDeleteSelection()
        // 0-2 と 3-5 が消え、6-8 は合計 4 秒ぶん前へ
        #expect(store.project.tracks[0].clips.count == 1)
        #expect(clip(store, track: 0, at: 2) != nil)
    }

    // MARK: - 隙間を詰める

    @Test("選んだクリップを前から詰める")
    func packRemovesGaps() {
        let store = makeStore()
        store.selectedClipIDs = [clip(store, track: 0, at: 0)!.id,
                                 clip(store, track: 0, at: 3)!.id,
                                 clip(store, track: 0, at: 6)!.id]
        store.packSelection()
        #expect(clip(store, track: 0, at: 0) != nil, "先頭は動かさない")
        #expect(clip(store, track: 0, at: 2) != nil)
        #expect(clip(store, track: 0, at: 4) != nil)
    }

    @Test("1 つだけの選択では何も起きない")
    func packNeedsTwoOrMore() {
        let store = makeStore()
        store.selectedClipIDs = [clip(store, track: 0, at: 3)!.id]
        store.packSelection()
        #expect(clip(store, track: 0, at: 3) != nil)
    }

    // MARK: - 範囲

    @Test("重なった区間はひとつにまとめる")
    func mergedRangesJoinsOverlaps() {
        let store = makeStore()
        // 映像 0-2 とテロップ 1-2 は重なっている
        let ids: Set<UUID> = [clip(store, track: 0, at: 0)!.id, clip(store, track: 1, at: 1)!.id]
        let ranges = store.mergedRanges(of: ids)
        #expect(ranges.count == 1)
        #expect(abs(ranges[0].lowerBound - 0) < 1e-9)
        #expect(abs(ranges[0].upperBound - 2) < 1e-9)
    }

    @Test("離れた区間は分かれたまま")
    func mergedRangesKeepsGaps() {
        let store = makeStore()
        let ids: Set<UUID> = [clip(store, track: 0, at: 0)!.id, clip(store, track: 0, at: 6)!.id]
        #expect(store.mergedRanges(of: ids).count == 2)
    }

    @Test("選択全体の端から端")
    func selectionSpanCoversAll() {
        let store = makeStore()
        store.selectedClipIDs = [clip(store, track: 0, at: 0)!.id, clip(store, track: 0, at: 6)!.id]
        let span = store.selectionSpan
        #expect(abs((span?.lowerBound ?? -1) - 0) < 1e-9)
        #expect(abs((span?.upperBound ?? -1) - 8) < 1e-9)
    }

    @Test("何も選んでいなければ範囲は無い")
    func selectionSpanIsNilWhenEmpty() {
        let store = makeStore()
        #expect(store.selectionSpan == nil)
    }
}
