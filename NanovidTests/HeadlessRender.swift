import CoreGraphics
import CoreMedia
import Foundation
@testable import Nanovid

/// プロジェクトを組んで、実際に 1 フレーム描くところまでを通す道具。
///
/// 再生も書き出しも通さない。中身は `FrameRenderer` の `direct` 経路で、
/// `CompositionBuilder` が出した命令を `NanovidCompositor` にそのまま渡す。
/// 素材のフレームは合成トラックごとの単色で代用する（読み込みを挟まない）。
@MainActor
enum HeadlessRender {

    typealias Frame = RGBAFrame

    static func stubColor(for trackID: CMPersistentTrackID) -> (r: UInt8, g: UInt8, b: UInt8) {
        FrameRenderer.stubColor(for: trackID)
    }

    /// 組み立てを 1 回で済ませて、好きな時刻を何枚でも描ける入れ物。
    /// フレームごとに組み直すと、合成の組み立てが支配的になって遅い。
    @MainActor
    struct Renderer {
        let renderer: FrameRenderer

        /// 指定時刻の絵を描く。命令が見つからなければ nil。
        func frame(at time: Double) -> Frame? {
            guard let image = try? renderer.renderDirect(at: time, sources: .stub) else { return nil }
            return Frame(image)
        }
    }

    static func renderer(for project: Project, constantFrameRate: Bool = true) async throws -> Renderer {
        Renderer(renderer: try await FrameRenderer.make(project: project, baseURL: nil,
                                                        constantFrameRate: constantFrameRate))
    }

    /// 1 枚だけ欲しいとき。
    static func frame(of project: Project, at time: Double,
                      constantFrameRate: Bool = true) async throws -> Frame? {
        try await renderer(for: project, constantFrameRate: constantFrameRate).frame(at: time)
    }
}
