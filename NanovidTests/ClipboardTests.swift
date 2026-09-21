import Testing
import Foundation
@testable import Nanovid

/// クリップのコピーと貼り付け。
/// 実際のクリップボードには触らず、中身（ClipboardPayload）だけで確かめる。
@MainActor
struct ClipboardTests {

    private func makeStore() -> (EditorStore, MediaAsset) {
        var project = Project.starter()
        let asset = MediaAsset(path: "/tmp/x.mp4", displayName: "素材", kind: .video,
                               duration: 60, naturalSize: CGSize(width: 1920, height: 1080),
                               hasAudio: false, hasVideo: true)
        project.assets = [asset]
        project.tracks[0].clips = [
            Clip(start: 0, duration: 2, content: .media(assetID: asset.id, sourceStart: 0)),
            Clip(start: 3, duration: 2, content: .media(assetID: asset.id, sourceStart: 0)),
        ]
        let template = project.textTemplates[0]
        project.tracks[1].clips = [
            Clip(start: 1, duration: 1,
                 content: .text(TextInstance(templateID: template.id,
                                             props: ["text": .string("もとの文字")]))),
        ]
        return (EditorStore(project: project), asset)
    }

    private func allClips(_ store: EditorStore) -> [Clip] {
        store.project.tracks.flatMap(\.clips).sorted { $0.start < $1.start }
    }

    // MARK: - コピー

    @Test("参照しているテンプレートと素材も一緒に載せる")
    func payloadCarriesReferences() throws {
        let (store, asset) = makeStore()
        store.selectAll()
        let payload = try #require(store.makePayload(of: store.selectedClipIDs))

        #expect(payload.entries.count == 3)
        #expect(payload.assets.map(\.id) == [asset.id])
        #expect(payload.templates.count == 1, "テキストクリップのテンプレートが要る")
        #expect(payload.entries.first?.trackKind == .video)
    }

    @Test("いちばん早いクリップが基準になる")
    func payloadAnchorIsEarliest() throws {
        let (store, _) = makeStore()
        store.selectAll()
        let payload = try #require(store.makePayload(of: store.selectedClipIDs))
        #expect(payload.anchor == 0)
    }

    @Test("何も選んでいなければ中身は作らない")
    func payloadIsNilWhenNothingSelected() {
        let (store, _) = makeStore()
        #expect(store.makePayload(of: []) == nil)
    }

    @Test("切り取るともとのクリップは消える")
    func cutRemovesClips() throws {
        let (store, _) = makeStore()
        let target = try #require(store.project.tracks[0].clips.first)
        store.selectedClipIDs = [target.id]
        let payload = try #require(store.makePayload(of: store.selectedClipIDs))
        store.deleteSelection()

        #expect(store.project.tracks[0].clips.count == 1)
        #expect(payload.entries.count == 1)
    }

    // MARK: - 貼り付け

    @Test("再生ヘッドの位置に、位置関係を保って貼る")
    func pasteKeepsRelativePositions() throws {
        let (store, _) = makeStore()
        store.selectedClipIDs = Set(store.project.tracks[0].clips.map(\.id))   // 0-2 と 3-5
        let payload = try #require(store.makePayload(of: store.selectedClipIDs))

        store.seek(to: 10)
        store.paste(payload)

        let starts = store.project.tracks[0].clips.map(\.start).sorted()
        #expect(starts == [0, 3, 10, 13], "10 秒の位置に 0 と 3 秒ぶんの間隔で並ぶ")
    }

    @Test("貼ったものが新しい選択になる")
    func pasteSelectsWhatWasPasted() throws {
        let (store, _) = makeStore()
        let original = try #require(store.project.tracks[0].clips.first)
        store.selectedClipIDs = [original.id]
        let payload = try #require(store.makePayload(of: store.selectedClipIDs))

        store.seek(to: 8)
        store.paste(payload)

        #expect(store.selectedClipIDs.count == 1)
        #expect(!store.selectedClipIDs.contains(original.id), "もとのクリップではない")
        let pasted = store.project.clip(store.selectedClipIDs.first!)
        #expect(abs((pasted?.start ?? -1) - 8) < 1e-9)
    }

    @Test("貼り付けは別の id になる")
    func pasteAssignsNewIdentity() throws {
        let (store, _) = makeStore()
        store.selectAll()
        let payload = try #require(store.makePayload(of: store.selectedClipIDs))
        let before = Set(allClips(store).map(\.id))

        store.seek(to: 20)
        store.paste(payload)

        let after = Set(allClips(store).map(\.id))
        #expect(after.count == before.count * 2)
        #expect(before.isSubset(of: after), "もとのクリップはそのまま残る")
    }

    @Test("テンプレートが無いプロジェクトへ貼ると一緒に取り込まれる")
    func pasteImportsMissingTemplate() throws {
        let (source, _) = makeStore()
        let textClip = try #require(source.project.tracks[1].clips.first)
        source.selectedClipIDs = [textClip.id]
        let payload = try #require(source.makePayload(of: source.selectedClipIDs))

        // テンプレートを 1 つも持たない別プロジェクト
        var empty = Project.starter()
        empty.textTemplates = []
        let target = EditorStore(project: empty)

        target.seek(to: 0)
        target.paste(payload)

        #expect(target.project.textTemplates.count == 1)
        let pasted = target.project.tracks.flatMap(\.clips).first
        let templateID = try #require(pasted?.content.textInstance?.templateID)
        #expect(target.project.template(templateID) != nil, "参照が解決できる")
        #expect(pasted?.content.textInstance?.props["text"]?.stringValue == "もとの文字")
    }

    @Test("素材が無いプロジェクトへ貼ると一緒に取り込まれる")
    func pasteImportsMissingAsset() throws {
        let (source, asset) = makeStore()
        let mediaClip = try #require(source.project.tracks[0].clips.first)
        source.selectedClipIDs = [mediaClip.id]
        let payload = try #require(source.makePayload(of: source.selectedClipIDs))

        let target = EditorStore(project: Project.starter())
        target.paste(payload)

        #expect(target.project.asset(asset.id) != nil)
    }

    @Test("同じ素材を二重に取り込まない")
    func pasteDoesNotDuplicateAssets() throws {
        let (store, _) = makeStore()
        store.selectedClipIDs = [try #require(store.project.tracks[0].clips.first).id]
        let payload = try #require(store.makePayload(of: store.selectedClipIDs))

        store.seek(to: 10)
        store.paste(payload)
        store.seek(to: 20)
        store.paste(payload)

        #expect(store.project.assets.count == 1)
        #expect(store.project.textTemplates.count == Project.starter().textTemplates.count)
    }

    @Test("0 より手前へは貼れない")
    func pasteClampsAtZero() throws {
        let (store, _) = makeStore()
        store.selectedClipIDs = [try #require(store.project.tracks[0].clips.last).id]
        let payload = try #require(store.makePayload(of: store.selectedClipIDs))

        store.currentTime = 0
        store.paste(payload)
        #expect(allClips(store).allSatisfy { $0.start >= 0 })
    }

    // MARK: - 貼り付け先の選び方

    @Test("同じ名前のトラックがあればそこへ戻る")
    func pasteTargetPrefersSameName() {
        let project = Project.starter()
        let entry = ClipboardPayload.Entry(
            clip: Clip(start: 0, duration: 1, content: .text(TextInstance(templateID: UUID()))),
            trackName: "テロップ", trackKind: .video)
        let index = EditorStore.pasteTarget(for: entry, in: project, preferring: nil)
        #expect(project.tracks[index!].name == "テロップ")
    }

    @Test("名前が合わなければ選択中のトラックへ")
    func pasteTargetFallsBackToSelected() {
        let project = Project.starter()
        let selected = project.tracks[1].id
        let entry = ClipboardPayload.Entry(
            clip: Clip(start: 0, duration: 1, content: .text(TextInstance(templateID: UUID()))),
            trackName: "存在しないトラック", trackKind: .video)
        let index = EditorStore.pasteTarget(for: entry, in: project, preferring: selected)
        #expect(project.tracks[index!].id == selected)
    }

    @Test("どちらも無ければ同じ種類の最初のトラックへ")
    func pasteTargetFallsBackToKind() {
        let project = Project.starter()
        let entry = ClipboardPayload.Entry(
            clip: Clip(start: 0, duration: 1, content: .media(assetID: UUID(), sourceStart: 0)),
            trackName: "存在しないトラック", trackKind: .audio)
        let index = EditorStore.pasteTarget(for: entry, in: project, preferring: nil)
        #expect(project.tracks[index!].kind == .audio)
    }

    @Test("ロックしたトラックへは貼らない")
    func pasteTargetSkipsLockedTracks() {
        var project = Project.starter()
        project.tracks[1].isLocked = true      // テロップ
        let entry = ClipboardPayload.Entry(
            clip: Clip(start: 0, duration: 1, content: .text(TextInstance(templateID: UUID()))),
            trackName: "テロップ", trackKind: .video)
        let index = EditorStore.pasteTarget(for: entry, in: project, preferring: nil)
        #expect(project.tracks[index!].name != "テロップ")
    }
}
