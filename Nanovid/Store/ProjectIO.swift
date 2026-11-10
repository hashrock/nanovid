import Foundation
import UniformTypeIdentifiers

/// `.nanovid` の読み書き。
///
/// 書類はパッケージ（Finder では 1 つのファイルに見えるフォルダ）。
///
///     作品.nanovid/
///       project.json     編集内容（Project）
///       Recordings/      このアプリで録音した音声
///
/// 以前の版は `.nanovid` が JSON 1 ファイルで、録音は隣の `Recordings/` や
/// ユーザーが選んだフォルダに置いていた。App Sandbox の下では「開いた書類の隣」に
/// 書けないので、録音を書類の中へ入れた。書類の中ならいつでも書ける。
/// 古い 1 ファイルの形式は読める。開いて保存すると、その場でパッケージになる
/// （古い形式へは書き戻さない）。
///
/// 取り込んだ素材（動画・画像・音声）は今までどおり外に置いたまま参照する。
enum ProjectIO {
    static let fileExtension = "nanovid"
    /// 書き出し宣言している UTI（Info.plist の UTExportedTypeDeclarations）。
    static let typeIdentifier = "com.hashrock.nanovid.project"
    static var contentType: UTType {
        UTType(typeIdentifier) ?? UTType(filenameExtension: fileExtension) ?? .package
    }

    /// 開くパネルで選べる種類。パッケージと、古い 1 ファイルの形式。
    ///
    /// 拡張子は同じでも、フォルダでない `.nanovid` はパッケージの種類に当たらない
    /// （システムは dyn.… という別の種類を振る）。足しておかないと、古い形式の
    /// 書類がパネルで灰色になって選べない。
    static var openableTypes: [UTType] {
        [contentType, UTType(filenameExtension: fileExtension, conformingTo: .data)]
            .compactMap { $0 }
    }

    /// パッケージの中のファイル名。書類の名前に引きずられないよう固定。
    static let projectFileName = "project.json"
    static let recordingsDirectoryName = "Recordings"

    static let mediaTypes: [UTType] = [
        .movie, .video, .mpeg4Movie, .quickTimeMovie, .audio, .mp3, .wav, .mpeg4Audio,
        .png, .jpeg, .heic, .tiff, .gif,
    ]

    // MARK: - 場所

    /// パッケージの中の録音の置き場。
    static func recordingsDirectory(in package: URL) -> URL {
        package.appendingPathComponent(recordingsDirectoryName, isDirectory: true)
    }

    /// パッケージ（フォルダ）になっているか。古い 1 ファイルの形式なら false。
    static func isPackage(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    // MARK: - 保存

    /// パッケージとして保存する。
    ///
    /// - Parameters:
    ///   - url: 保存先の `.nanovid`。
    ///   - previous: いま開いている書類の場所（未保存なら nil）。相対パスの素材は
    ///     ここを基準に探す。別名で保存するときは、前の書類の中にある録音を
    ///     新しい書類の中へ写す。
    /// - Returns: 保存した先から読み直したのと同じ Project。素材の path が保存先を
    ///   基準にしたものに変わるので、別名で保存したあとはこちらを使う。
    @discardableResult
    static func save(_ project: Project, to url: URL, previous: URL? = nil) throws -> Project {
        let fm = FileManager.default
        let url = url.standardizedFileURL
        let previous = (previous ?? url).standardizedFileURL
        let oldBase = previous.deletingLastPathComponent()
        let newBase = url.deletingLastPathComponent()
        let previousPackage = isPackage(previous) ? previous : nil

        // すでにパッケージがあるところへ上書きするときは、中の project.json だけを
        // 差し替える（録音を巻き込まない）。それ以外で何か置いてあるとき
        // （古い 1 ファイルの形式、別名で保存で選んだ別の書類）は丸ごと置き換える。
        let exists = fm.fileExists(atPath: url.path)
        // URL は末尾のスラッシュの有無で別物になるので、path で比べる。
        let samePlace = previous.path == url.path
        let inPlace = isPackage(url) && samePlace
        let target: URL
        if inPlace || !exists {
            target = url
        } else {
            // 置き換えは「隣に作ってから差し替える」。途中で失敗しても元が残る。
            let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                     appropriateFor: url, create: true)
            target = staging.appendingPathComponent(url.lastPathComponent, isDirectory: true)
        }
        try fm.createDirectory(at: target, withIntermediateDirectories: true)

        var onDisk = project
        var inMemory = project
        for i in project.assets.indices {
            let asset = project.assets[i]
            var full = asset.url(relativeTo: oldBase).standardizedFileURL

            // 前の書類の中にあるもの（録音）は、新しい書類の中へ写す。
            if let previousPackage, !samePlace,
               let inside = relativePath(of: full, from: previousPackage) {
                let copy = appending(inside, to: target)
                try fm.createDirectory(at: copy.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                if fm.fileExists(atPath: full.path), !fm.fileExists(atPath: copy.path) {
                    try fm.copyItem(at: full, to: copy)
                }
                full = appending(inside, to: url)
            }

            if let inside = relativePath(of: full, from: url) {
                // 書類の中にあるもの。書類からの相対パスで持つ。書類を開けば中まで
                // 読めるので bookmark は要らない。持たせると、複製した書類が
                // 元の書類の中の録音を指してしまう。
                onDisk.assets[i].path = inside
                onDisk.assets[i].embedded = true
                onDisk.assets[i].bookmark = nil
                inMemory.assets[i].path = full.path
                inMemory.assets[i].embedded = nil
                inMemory.assets[i].bookmark = nil
                continue
            }

            var a = asset
            a.embedded = nil
            // 書類と同じ階層以下の素材は相対パスにして、フォルダごと移動できるようにする。
            a.path = relativePath(of: full, from: newBase) ?? full.path
            // 以前の版で取り込んだ素材には bookmark が無い。いま読めるなら作っておく。
            // 読めないものは作れないので、あるものはそのまま持ち越す。
            if a.bookmark == nil, MediaAccess.isReachable(full) {
                a.bookmark = MediaBookmark.make(for: full)
            }
            onDisk.assets[i] = a
            inMemory.assets[i] = a
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(onDisk)
            .write(to: target.appendingPathComponent(projectFileName), options: .atomic)

        if target.path != url.path {
            _ = try fm.replaceItemAt(url, withItemAt: target)
            try? fm.removeItem(at: target.deletingLastPathComponent())
        }
        return inMemory
    }

    // MARK: - 読み込み

    /// パッケージでも、古い 1 ファイルの形式でも読む。
    ///
    /// 書類の中にある素材（録音）の path は絶対パスにして返す。それ以外の相対パスは
    /// 今までどおり「書類のあるフォルダ」からの相対（`MediaAsset.url(relativeTo:)`）。
    static func load(from url: URL) throws -> Project {
        let url = url.standardizedFileURL
        guard isPackage(url) else {
            // 古い形式。JSON 1 ファイル。
            var project = try JSONDecoder().decode(Project.self, from: Data(contentsOf: url))
            for i in project.assets.indices { project.assets[i].embedded = nil }
            return project
        }
        let data = try Data(contentsOf: url.appendingPathComponent(projectFileName))
        var project = try JSONDecoder().decode(Project.self, from: data)
        for i in project.assets.indices where project.assets[i].embedded == true {
            project.assets[i].path = appending(project.assets[i].path, to: url).path
            project.assets[i].embedded = nil
        }
        return project
    }

    // MARK: - パス

    /// base 配下にある場合のみ相対パスを返す。上位へ遡る ../ は作らない。
    private static func relativePath(of url: URL, from base: URL) -> String? {
        let u = url.standardizedFileURL.pathComponents
        let b = base.standardizedFileURL.pathComponents
        guard u.count > b.count, Array(u.prefix(b.count)) == b else { return nil }
        return u.dropFirst(b.count).joined(separator: "/")
    }

    /// 相対パスを base につなぐ。`..` は捨てる（書類の外を指させない）。
    private static func appending(_ relative: String, to base: URL) -> URL {
        var url = base
        for component in relative.split(separator: "/") where component != "." && component != ".." {
            url.appendPathComponent(String(component))
        }
        return url.standardizedFileURL
    }
}
