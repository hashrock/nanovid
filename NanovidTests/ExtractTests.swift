import Testing
import Foundation
@testable import Nanovid

/// 範囲を決めて抜き、時間を詰める操作。
@MainActor
struct ExtractTests {

    /// 映像 0-10（ひと続き）、テロップ 1-2 / 6-7、音声 0-10。
    private func makeStore() -> EditorStore {
        var project = Project.starter()
        let video = MediaAsset(path: "/tmp/v.mp4", displayName: "映像", kind: .video,
                               duration: 60, naturalSize: CGSize(width: 1920, height: 1080),
                               hasAudio: false, hasVideo: true)
        let audio = MediaAsset(path: "/tmp/a.wav", displayName: "音声", kind: .audio,
                               duration: 60, naturalSize: nil, hasAudio: true, hasVideo: false)
        project.assets = [video, audio]
        project.tracks[0].clips = [
            Clip(start: 0, duration: 10, content: .media(assetID: video.id, sourceStart: 0))
        ]
        let template = project.textTemplates[0]
        project.tracks[1].clips = [
            Clip(start: 1, duration: 1, content: .text(TextInstance(templateID: template.id))),
            Clip(start: 6, duration: 1, content: .text(TextInstance(templateID: template.id))),
        ]
        project.tracks[2].clips = [
            Clip(start: 0, duration: 10, content: .media(assetID: audio.id, sourceStart: 0))
        ]
        return EditorStore(project: project)
    }

    private func clips(_ store: EditorStore, _ track: Int) -> [Clip] {
        store.project.tracks[track].clips.sorted { $0.start < $1.start }
    }

    // MARK: - 印と範囲

    @Test("開始を打つと再生ヘッドまでが範囲になる")
    func markMakesRange() {
        let store = makeStore()
        store.seek(to: 2)
        store.markExtractStart()
        store.seek(to: 5)

        let range = store.pendingExtractRange
        #expect(abs((range?.lowerBound ?? -1) - 2) < 1e-9)
        #expect(abs((range?.upperBound ?? -1) - 5) < 1e-9)
    }

    @Test("開始より手前へ戻しても向きはそろう")
    func rangeIsNormalized() {
        let store = makeStore()
        store.seek(to: 5)
        store.markExtractStart()
        store.seek(to: 2)

        let range = store.pendingExtractRange
        #expect(abs((range?.lowerBound ?? -1) - 2) < 1e-9)
        #expect(abs((range?.upperBound ?? -1) - 5) < 1e-9)
    }

    @Test("やめれば範囲は消える")
    func cancelClearsRange() {
        let store = makeStore()
        store.seek(to: 2)
        store.markExtractStart()
        store.cancelExtract()
        #expect(store.pendingExtractRange == nil)
    }

    @Test("打っていなければ何も起きない")
    func extractWithoutMarkDoesNothing() {
        let store = makeStore()
        store.extractMarkedRange()
        #expect(abs(store.duration - 10) < 1e-9)
    }

    // MARK: - 切り抜き

    @Test("またがるクリップは範囲の分だけ切り取ってつなぐ")
    func extractSplicesSpanningClip() {
        let store = makeStore()
        store.extract(range: 3...5)      // 2 秒ぶん抜く

        let video = clips(store, 0)
        #expect(video.count == 2)
        #expect(abs(video[0].start - 0) < 1e-9)
        #expect(abs(video[0].duration - 3) < 1e-9)
        #expect(abs(video[1].start - 3) < 1e-9, "後ろの断片が切れ目へ寄る")
        #expect(abs(video[1].duration - 5) < 1e-9)

        // 素材の中も抜いたぶんだけ進む
        guard case .media(_, let sourceStart) = video[1].content else {
            Issue.record("メディアクリップのまま")
            return
        }
        #expect(abs(sourceStart - 5) < 1e-9)
    }

    @Test("全トラックが同じだけ縮む")
    func allTracksShrinkTogether() {
        let store = makeStore()
        store.extract(range: 3...5)

        #expect(abs(store.duration - 8) < 1e-9)
        #expect(abs(clips(store, 0).map(\.end).max()! - 8) < 1e-9)
        #expect(abs(clips(store, 2).map(\.end).max()! - 8) < 1e-9, "音声もそろって縮む")
    }

    @Test("範囲にすっぽり入ったクリップは消える")
    func clipInsideRangeIsRemoved() {
        let store = makeStore()
        store.extract(range: 5.5...7.5)   // テロップ 6-7 を含む

        let captions = clips(store, 1)
        #expect(captions.count == 1)
        #expect(abs(captions[0].start - 1) < 1e-9, "手前のテロップは動かない")
    }

    @Test("範囲より後ろのクリップは前へ詰まる")
    func laterClipsShiftLeft() {
        let store = makeStore()
        store.extract(range: 2...4)       // テロップ 1-2 の直後を 2 秒抜く

        let captions = clips(store, 1)
        #expect(captions.count == 2)
        #expect(abs(captions[0].start - 1) < 1e-9)
        #expect(abs(captions[1].start - 4) < 1e-9, "6 が 2 秒ぶん前へ")
    }

    @Test("範囲より手前のクリップは動かない")
    func earlierClipsStay() {
        let store = makeStore()
        store.extract(range: 8...9)
        let captions = clips(store, 1)
        #expect(abs(captions[0].start - 1) < 1e-9)
        #expect(abs(captions[1].start - 6) < 1e-9)
    }

    @Test("ロックしたトラックは抜かない")
    func lockedTracksAreLeftAlone() {
        let store = makeStore()
        store.edit { $0.tracks[2].isLocked = true }
        store.extract(range: 3...5)

        #expect(abs(clips(store, 0).map(\.end).max()! - 8) < 1e-9)
        #expect(abs(clips(store, 2).map(\.end).max()! - 10) < 1e-9, "ロック中はそのまま")
    }

    @Test("フェードは切り目で消える")
    func fadesAreDroppedAtTheCut() {
        let store = makeStore()
        store.edit { $0.tracks[0].clips[0].fade = Fade(inDuration: 0.5, outDuration: 0.5) }
        store.extract(range: 3...5)

        let video = clips(store, 0)
        #expect(video[0].fade.inDuration == 0.5)
        #expect(video[0].fade.outDuration == 0, "切り目側は消す")
        #expect(video[1].fade.inDuration == 0)
        #expect(video[1].fade.outDuration == 0.5)
    }

    @Test("切り抜いたあと再生ヘッドは切れ目へ行く")
    func playheadMovesToTheCut() {
        let store = makeStore()
        store.seek(to: 3)
        store.markExtractStart()
        store.seek(to: 5)
        store.extractMarkedRange()

        #expect(abs(store.currentTime - 3) < 1e-9)
        #expect(store.pendingExtractRange == nil, "印は消える")
    }

    @Test("長さゼロの範囲では何も起きない")
    func zeroLengthDoesNothing() {
        let store = makeStore()
        store.seek(to: 4)
        store.markExtractStart()
        store.extractMarkedRange()
        #expect(abs(store.duration - 10) < 1e-9)
    }

    @Test("取り消しで元に戻る")
    func undoRestores() {
        let store = makeStore()
        store.extract(range: 3...5)
        #expect(abs(store.duration - 8) < 1e-9)
        store.undo()
        #expect(abs(store.duration - 10) < 1e-9)
        #expect(clips(store, 0).count == 1)
    }
}
