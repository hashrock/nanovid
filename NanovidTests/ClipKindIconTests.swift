import Testing
import Foundation
@testable import Nanovid

/// トラックの見出しとクリップで、種類のアイコンがそろうこと。
struct ClipKindIconTests {

    private func project() -> (Project, MediaAsset, MediaAsset) {
        var p = Project.starter()
        let movie = MediaAsset(path: "/tmp/m.mp4", displayName: "m", kind: .video, duration: 10,
                               naturalSize: CGSize(width: 1920, height: 1080), hasAudio: false, hasVideo: true)
        let still = MediaAsset(path: "/tmp/s.png", displayName: "s", kind: .image, duration: 0,
                               naturalSize: CGSize(width: 1920, height: 1080), hasAudio: false, hasVideo: true)
        p.assets = [movie, still]
        return (p, movie, still)
    }

    @Test func テロップだけのトラックはあぁ() {
        var (p, _, _) = project()
        let t = p.textTemplates[0]
        p.tracks[1].clips = [Clip(start: 0, duration: 1, content: .text(TextInstance(templateID: t.id)))]
        let track = p.tracks[1]
        #expect(ClipKindIcon.name(for: track, project: p) == ClipKindIcon.text)
        #expect(ClipKindIcon.name(for: track.clips[0], in: track, project: p) == ClipKindIcon.text)
    }

    @Test func 映像と画像が混ざると映像() {
        var (p, movie, still) = project()
        p.tracks[0].clips = [
            Clip(start: 0, duration: 1, content: .media(assetID: movie.id, sourceStart: 0)),
            Clip(start: 1, duration: 1, content: .media(assetID: still.id, sourceStart: 0)),
        ]
        let track = p.tracks[0]
        #expect(ClipKindIcon.name(for: track, project: p) == ClipKindIcon.video)
        #expect(ClipKindIcon.name(for: track.clips[1], in: track, project: p) == ClipKindIcon.image)
    }

    @Test func 画像だけなら写真() {
        var (p, _, still) = project()
        p.tracks[0].clips = [Clip(start: 0, duration: 1, content: .media(assetID: still.id, sourceStart: 0))]
        #expect(ClipKindIcon.name(for: p.tracks[0], project: p) == ClipKindIcon.image)
    }

    @Test func 音声は波形_空の映像は映像() {
        let (p, _, _) = project()
        #expect(ClipKindIcon.name(for: p.tracks[2], project: p) == ClipKindIcon.audio)
        #expect(ClipKindIcon.name(for: p.tracks[0], project: p) == ClipKindIcon.video)
    }
}
