import Foundation
import UniformTypeIdentifiers

enum ProjectIO {
    static let fileExtension = "nanovid"
    static var contentType: UTType { UTType(filenameExtension: fileExtension) ?? .json }

    static let mediaTypes: [UTType] = [
        .movie, .video, .mpeg4Movie, .quickTimeMovie, .audio, .mp3, .wav, .mpeg4Audio,
        .png, .jpeg, .heic, .tiff, .gif,
    ]

    static func save(_ project: Project, to url: URL) throws {
        var copy = project
        // プロジェクトファイルと同じ階層以下の素材は相対パスにして、フォルダごと移動できるようにする。
        let base = url.deletingLastPathComponent().standardizedFileURL
        copy.assets = project.assets.map { asset in
            var a = asset
            let full = asset.url(relativeTo: base).standardizedFileURL
            if let rel = relativePath(of: full, from: base) { a.path = rel }
            return a
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(copy).write(to: url, options: .atomic)
    }

    static func load(from url: URL) throws -> Project {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Project.self, from: data)
    }

    /// base 配下にある場合のみ相対パスを返す。上位へ遡る ../ は作らない。
    private static func relativePath(of url: URL, from base: URL) -> String? {
        let u = url.standardizedFileURL.pathComponents
        let b = base.standardizedFileURL.pathComponents
        guard u.count > b.count, Array(u.prefix(b.count)) == b else { return nil }
        return u.dropFirst(b.count).joined(separator: "/")
    }
}
