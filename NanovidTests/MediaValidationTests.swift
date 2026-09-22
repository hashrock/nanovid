import Testing
import Foundation
import AVFoundation
@testable import Nanovid

/// 再生できない素材を、取り込みと組み立ての段階で言えること。
///
/// AVPlayer は対応外のコーデックでも readyToPlay を返し、途中で切れたファイルでも
/// 最後まで時間を進める。どちらもエラーは出ず、画が黒いだけ。だからここで弾く。
struct MediaValidationTests {

    /// テストのソースと同じ場所にある素材。バンドルの設定に頼らない。
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("Fixtures")

    private static func fixture(_ name: String) -> URL {
        fixtures.appendingPathComponent(name)
    }

    /// 作業用のコピー。壊すテストで元の素材を汚さない。
    private static func scratchCopy(of name: String, truncatedTo ratio: Double? = nil) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nanovid-media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var data = try Data(contentsOf: fixture(name))
        if let ratio { data = data.prefix(Int(Double(data.count) * ratio)) }
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    @Test("普通の H.264 はそのまま取り込める")
    func acceptsPlainH264() async throws {
        let url = try Self.scratchCopy(of: "tiny-h264.mp4")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let asset = try await AssetCache.shared.inspect(url: url)
        #expect(asset.kind == .video)
        #expect(abs(asset.duration - 2.0) < 0.1)
    }

    @Test("この Mac で再生できない形式は取り込みで弾く")
    func rejectsUndecodableCodec() async throws {
        let url = try Self.scratchCopy(of: "undecodable-ffv1.mov")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        await #expect(throws: MediaProblem.self) {
            _ = try await AssetCache.shared.inspect(url: url)
        }
        do {
            _ = try await AssetCache.shared.inspect(url: url)
        } catch let problem as MediaProblem {
            guard case .undecodable(_, let codec) = problem else {
                Issue.record("undecodable のはずが \(problem)")
                return
            }
            #expect(codec == "FFV1", "コーデック名が \(codec)")
            #expect(problem.localizedDescription.contains("再生できない形式"))
        }
    }

    @Test("途中で切れたファイルは取り込みで弾く")
    func rejectsTruncatedFile() async throws {
        // moov が先頭にあるので、切ってもメタデータは読める。読めるのに末尾が復号できない、
        // というのが「途中で切れたファイル」の形。
        let url = try Self.scratchCopy(of: "tiny-h264.mp4", truncatedTo: 0.5)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            _ = try await AssetCache.shared.inspect(url: url)
            Issue.record("切れたファイルを取り込んでしまった")
        } catch let problem as MediaProblem {
            guard case .truncated = problem else {
                Issue.record("truncated のはずが \(problem)")
                return
            }
            #expect(problem.localizedDescription.contains("最後まで読めません"))
        }
    }

    @Test("組み立ての段階でも再生できない形式を言う")
    func buildRefusesUndecodableAsset() async throws {
        // 取り込みの検査を通さずにプロジェクトへ入っている状態。
        // 別の Mac で作ったプロジェクトを開いたときがこれ。
        let url = try Self.scratchCopy(of: "undecodable-ffv1.mov")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var project = Project.starter()
        let asset = MediaAsset(path: url.path, displayName: "対応外", kind: .video, duration: 1,
                               naturalSize: CGSize(width: 16, height: 16),
                               hasAudio: false, hasVideo: true)
        project.assets = [asset]
        project.tracks[0].clips = [Clip(start: 0, duration: 1,
                                        content: .media(assetID: asset.id, sourceStart: 0))]

        do {
            _ = try await CompositionBuilder.build(project: project, baseURL: nil)
            Issue.record("組み立てが通ってしまった")
        } catch let error as BuildError {
            guard case .undecodable(let name) = error else {
                Issue.record("undecodable のはずが \(error)")
                return
            }
            #expect(name == "対応外")
        }
    }

    @Test("メッセージには変換先の案内が入る")
    func messageSuggestsConversion() {
        let text = MediaProblem.undecodable(name: "x", codec: "vp09").localizedDescription
        #expect(text.contains("H.264"))
        #expect(text.contains("vp09"))
    }
}
