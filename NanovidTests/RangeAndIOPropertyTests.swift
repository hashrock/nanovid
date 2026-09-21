import Testing
import Foundation
@testable import Nanovid

// MARK: - ランダムなプロジェクトを作る

@MainActor
enum RandomProject {

    /// 操作列を流して作った、それらしいプロジェクト。
    /// 手で書いた 2〜3 本のクリップでは出てこない形（重なり・隙間・
    /// 素材の途中から始まるクリップ）がひととおり混ざる。
    static func make(seed: UInt64, steps: Int = 30) -> Project {
        var generator = SeededGenerator(seed: seed)
        let runner = EditRunner()
        for command in EditGen.commands(count: steps, using: &generator) {
            runner.apply(command)
        }
        return runner.store.project
    }
}

// MARK: - その時刻に見えるもの

/// ある時刻の「見え方」。切り出しの前後で変わってはいけないもの。
///
/// 素材のどこを映しているか（sourceStart + 経過）と、不透明度まで見る。
/// クリップの start や duration が変わるのは構わないが、
/// 画に出るものが変われば、プレビューと書き出しが食い違う。
struct VisibleAtTime: Equatable, CustomStringConvertible {
    var entries: [String]

    var description: String { entries.isEmpty ? "（何もない）" : entries.joined(separator: " | ") }

    /// - Parameter includingAlpha: 不透明度まで見るか。
    ///   書き出す範囲の切り出しは「同じ画になる」ことが要件なので true。
    ///   切り抜きは時間を抜く編集で、継ぎ目でフェードを切るのは意図した動きなので false。
    init(at time: Double, in project: Project, includingAlpha: Bool = true) {
        var found: [String] = []
        for (ti, track) in project.tracks.enumerated() where !track.isHidden {
            for clip in track.clips where clip.contains(time) {
                let elapsed = time - clip.start
                let alpha = clip.opacity * clip.fade.factor(at: elapsed, clipDuration: clip.duration)
                let what: String
                switch clip.content {
                case .media(let assetID, let sourceStart):
                    what = "素材\(assetID.uuidString.prefix(4))@\(Self.fmt(sourceStart + elapsed))"
                case .text(let instance):
                    what = "文字\(instance.templateID.uuidString.prefix(4))"
                }
                found.append(includingAlpha ? "t\(ti) \(what) α\(Self.fmt(alpha))"
                                            : "t\(ti) \(what)")
            }
        }
        entries = found.sorted()
    }

    private static func fmt(_ v: Double) -> String { String(format: "%.6f", v) }
}


/// クリップの端で区切った区間の中点を並べる。
///
/// 等間隔に舐めると、たまたまクリップの端ちょうどを踏む。
/// Clip.contains は半開区間なので、そこでは 1e-16 のずれで
/// 見えるものが変わってしまい、意味のない食い違いになる。
/// 区間の中点なら、どの端からも十分離れている。
@MainActor
func intervalMidpoints(of project: Project, within range: ClosedRange<Double>) -> [Double] {
    var edges: Set<Double> = [range.lowerBound, range.upperBound]
    for clip in project.tracks.flatMap(\.clips) {
        for edge in [clip.start, clip.end] where range.contains(edge) {
            edges.insert(edge)
        }
    }
    let sorted = edges.sorted()
    return (0..<max(0, sorted.count - 1)).map { (sorted[$0] + sorted[$0 + 1]) / 2 }
}

// MARK: - 書き出す範囲の切り出し

@MainActor
struct CropPropertyTests {

    @Test("切り出しても範囲の中の見え方は変わらない", arguments: 0..<120)
    func cropKeepsWhatYouSee(seed: Int) {
        var generator = SeededGenerator(seed: UInt64(seed) &+ 0x0C50)
        var project = RandomProject.make(seed: UInt64(seed))
        let end = project.contentEnd
        guard end > 0.2 else { return }

        let a = generator.double(in: 0...end), b = generator.double(in: 0...end)
        project.outputRange = OutputRange(start: min(a, b), end: max(a, b))
        guard project.duration > 1e-3 else { return }

        let cropped = project.croppedToOutputRange()
        let range = project.outputStart...project.outputEnd
        for t in intervalMidpoints(of: project, within: range) {
            let before = VisibleAtTime(at: t, in: project)
            let after = VisibleAtTime(at: t, in: cropped)
            #expect(before == after, """
                seed \(seed): \(String(format: "%.4f", t)) 秒の見え方が変わった
                範囲 \(String(format: "%.4f〜%.4f", project.outputStart, project.outputEnd))
                切り出し前: \(before)
                切り出し後: \(after)
                """)
        }
    }

    @Test("範囲にかからないクリップは残らない", arguments: 0..<120)
    func cropDropsEverythingOutside(seed: Int) {
        var generator = SeededGenerator(seed: UInt64(seed) &+ 0x0C51)
        var project = RandomProject.make(seed: UInt64(seed))
        let end = project.contentEnd
        guard end > 0.2 else { return }

        let a = generator.double(in: 0...end), b = generator.double(in: 0...end)
        project.outputRange = OutputRange(start: min(a, b), end: max(a, b))
        let cropped = project.croppedToOutputRange()

        // 端にかかるクリップは、フェードを壊さないために切らずに残すことがある。
        // 「範囲に少しも重なっていないもの」が残っていなければよい。
        for clip in cropped.tracks.flatMap(\.clips) {
            let overlap = min(clip.end, project.outputEnd) - max(clip.start, project.outputStart)
            #expect(overlap > 1e-9,
                    """
                    seed \(seed): 範囲に重ならないクリップが残っている
                    クリップ \(clip.start)〜\(clip.end) / 範囲 \(project.outputStart)〜\(project.outputEnd)
                    """)
        }

        // はみ出すぶんはフェードの長さまで。青天井に残っていないことを確かめる。
        let slack = cropped.tracks.flatMap(\.clips).map { clip in
            max(max(0, project.outputStart - clip.start), max(0, clip.end - project.outputEnd))
        }.max() ?? 0
        let longestFade = project.tracks.flatMap(\.clips)
            .map { max($0.fade.inDuration, $0.fade.outDuration) }.max() ?? 0
        #expect(slack <= longestFade + 1e-9,
                "seed \(seed): フェードの長さ (\(longestFade)) を超えてはみ出している (\(slack))")
    }

    @Test("切り出しは 2 度やっても 1 度と同じ", arguments: 0..<120)
    func cropIsIdempotent(seed: Int) {
        var generator = SeededGenerator(seed: UInt64(seed) &+ 0x0C52)
        var project = RandomProject.make(seed: UInt64(seed))
        let end = project.contentEnd
        guard end > 0.2 else { return }

        let a = generator.double(in: 0...end), b = generator.double(in: 0...end)
        project.outputRange = OutputRange(start: min(a, b), end: max(a, b))
        let once = project.croppedToOutputRange()
        #expect(ProjectShape.of(once.croppedToOutputRange()) == ProjectShape.of(once),
                "seed \(seed): 2 度切り出すと変わる")
    }

    @Test("切り出したプロジェクトも壊れていない", arguments: 0..<120)
    func cropKeepsProjectValid(seed: Int) {
        var generator = SeededGenerator(seed: UInt64(seed) &+ 0x0C53)
        var project = RandomProject.make(seed: UInt64(seed))
        let end = project.contentEnd
        guard end > 0.2 else { return }
        let a = generator.double(in: 0...end), b = generator.double(in: 0...end)
        project.outputRange = OutputRange(start: min(a, b), end: max(a, b))

        let found = ProjectInvariants.violations(in: project.croppedToOutputRange())
        #expect(found.isEmpty, "seed \(seed): \(found.joined(separator: " / "))")
    }
}

// MARK: - 切り抜き（範囲を抜いて詰める）

@MainActor
struct ExtractPropertyTests {

    @Test("抜いたぶんだけ、後ろがちょうど前へ詰まる", arguments: 0..<150)
    func extractShiftsLaterClipsExactly(seed: Int) {
        var generator = SeededGenerator(seed: UInt64(seed) &+ 0xEE00)
        let runner = EditRunner()
        for command in EditGen.commands(count: 30, using: &generator) { runner.apply(command) }

        let before = runner.store.project
        let end = max(before.contentEnd, 1)
        let a = generator.double(in: 0...end), b = generator.double(in: 0...end)
        let (from, to) = (min(a, b), max(a, b))
        guard to - from > 1e-6 else { return }
        let length = to - from

        // 範囲より後ろにあったクリップが、ちょうど length だけ前へ動くこと。
        let expected = before.tracks.map { track in
            track.isLocked ? [] : track.clips.filter { $0.start >= to - 1e-9 }
                                             .map { $0.start - length }
        }
        runner.store.extract(range: from...to)
        let after = runner.store.project

        for (ti, track) in after.tracks.enumerated() {
            let moved = expected[ti]
            guard !moved.isEmpty else { continue }
            let starts = track.clips.map(\.start)
            for start in moved {
                let where_ = String(format: "%.4f", start)
                let cut = String(format: "%.4f〜%.4f", from, to)
                #expect(starts.contains { abs($0 - start) < 1e-9 },
                        "seed \(seed): \(cut) を抜いたので \(where_) 秒へ詰まっているはず")
            }
        }
    }

    @Test("抜いたあとも範囲にかかっていたぶんだけ短くなる", arguments: 0..<150)
    func extractRemovesExactlyTheOverlap(seed: Int) {
        var generator = SeededGenerator(seed: UInt64(seed) &+ 0xEE01)
        let runner = EditRunner()
        for command in EditGen.commands(count: 30, using: &generator) { runner.apply(command) }

        let before = runner.store.project
        let end = max(before.contentEnd, 1)
        let a = generator.double(in: 0...end), b = generator.double(in: 0...end)
        let (from, to) = (min(a, b), max(a, b))
        guard to - from > 1e-6 else { return }

        // 各トラックで、範囲に重なっていた尺の合計。
        let removed = before.tracks.map { track -> Double in
            track.isLocked ? 0 : track.clips.reduce(0) { sum, clip in
                sum + max(0, min(clip.end, to) - max(clip.start, from))
            }
        }
        let totalBefore = before.tracks.map { $0.clips.reduce(0) { $0 + $1.duration } }

        runner.store.extract(range: from...to)
        let totalAfter = runner.store.project.tracks.map { $0.clips.reduce(0) { $0 + $1.duration } }

        for ti in totalBefore.indices {
            #expect(abs(totalAfter[ti] - (totalBefore[ti] - removed[ti])) < 1e-6,
                    """
                    seed \(seed): トラック \(ti) の尺が合わない
                    前 \(totalBefore[ti]) − 重なり \(removed[ti]) ≠ 後 \(totalAfter[ti])
                    """)
        }
    }

    /// 見るのは「どの素材のどこが映っているか」まで。不透明度は外す。
    /// 継ぎ目でフェードを切る（head の fadeOut と tail の fadeIn を 0 にする）のは
    /// ExtractCommands.cut の意図した動きで、そこだけは見え方が変わってよい。
    @Test("抜いても残った部分に映るものは変わらない", arguments: 0..<150)
    func extractKeepsWhatYouSeeOutsideTheRange(seed: Int) {
        var generator = SeededGenerator(seed: UInt64(seed) &+ 0xEE02)
        let runner = EditRunner()
        for command in EditGen.commands(count: 30, using: &generator) { runner.apply(command) }
        // ロックしたトラックがあると時間軸が揃わないので、ここでは扱わない。
        guard runner.store.project.tracks.allSatisfy({ !$0.isLocked }) else { return }

        let before = runner.store.project
        let end = max(before.contentEnd, 1)
        let a = generator.double(in: 0...end), b = generator.double(in: 0...end)
        let (from, to) = (min(a, b), max(a, b))
        guard to - from > 1e-6 else { return }

        runner.store.extract(range: from...to)
        let after = runner.store.project

        // 範囲より手前はそのまま。
        for t in intervalMidpoints(of: before, within: 0...max(0, from)) {
            #expect(VisibleAtTime(at: t, in: before, includingAlpha: false)
                    == VisibleAtTime(at: t, in: after, includingAlpha: false),
                    "seed \(seed): 範囲の手前 \(String(format: "%.4f", t)) 秒に映るものが変わった")
        }
        // 範囲より後ろは、抜いたぶん前へずれた位置で同じに見える。
        for t in intervalMidpoints(of: before, within: to...max(to, end)) {
            #expect(VisibleAtTime(at: t, in: before, includingAlpha: false)
                    == VisibleAtTime(at: t - (to - from), in: after, includingAlpha: false),
                    "seed \(seed): 範囲の後ろ \(String(format: "%.4f", t)) 秒に映るものが変わった")
        }
    }

    @Test("抜いたあともプロジェクトは壊れていない", arguments: 0..<150)
    func extractKeepsProjectValid(seed: Int) {
        var generator = SeededGenerator(seed: UInt64(seed) &+ 0xEE03)
        let runner = EditRunner()
        for command in EditGen.commands(count: 30, using: &generator) { runner.apply(command) }
        let end = max(runner.store.project.contentEnd, 1)
        let a = generator.double(in: 0...end), b = generator.double(in: 0...end)
        guard max(a, b) - min(a, b) > 1e-6 else { return }

        runner.store.extract(range: min(a, b)...max(a, b))
        let found = ProjectInvariants.violations(in: runner.store.project)
        #expect(found.isEmpty, "seed \(seed): \(found.joined(separator: " / "))")
    }
}

// MARK: - 保存と読み込み

@MainActor
struct ProjectIOPropertyTests {

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nanovid-pbt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("保存して読み戻すと同じプロジェクトになる", arguments: 0..<100)
    func roundTripsThroughDisk(seed: Int) throws {
        let project = RandomProject.make(seed: UInt64(seed))
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("p.nanovid")
        try ProjectIO.save(project, to: file)
        let reloaded = try ProjectIO.load(from: file)

        // 素材のパスは相対化されうるので、そこだけ別に見る。
        #expect(ProjectShape.of(reloaded) == ProjectShape.of(project),
                "seed \(seed): 中身が変わった")
        #expect(reloaded.outputRange == project.outputRange, "seed \(seed): 書き出す範囲が消えた")
        #expect(reloaded.textTemplates == project.textTemplates, "seed \(seed): テンプレートが変わった")
    }

    @Test("相対パスにしても同じファイルを指す", arguments: 0..<60)
    func relativePathsStillPointAtTheSameFile(seed: Int) throws {
        var project = RandomProject.make(seed: UInt64(seed))
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // プロジェクトと同じ階層・下の階層・まったく別の場所、の 3 通りを混ぜる。
        let nested = directory.appendingPathComponent("素材/その 2")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let places = [
            directory.appendingPathComponent("となり.mp4"),
            nested.appendingPathComponent("奥.mov"),
            URL(fileURLWithPath: "/tmp/nanovid-pbt-外.wav"),
        ]
        for (i, asset) in project.assets.enumerated() {
            project.assets[i].path = places[i % places.count].path
        }
        let expected = project.assets.map { $0.url(relativeTo: directory).standardizedFileURL }

        let file = directory.appendingPathComponent("p.nanovid")
        try ProjectIO.save(project, to: file)
        let reloaded = try ProjectIO.load(from: file)

        let actual = reloaded.assets.map { $0.url(relativeTo: directory).standardizedFileURL }
        #expect(actual == expected, """
            seed \(seed): 保存前と違うファイルを指している
            保存前: \(expected.map(\.path))
            読込後: \(actual.map(\.path))（記録は \(reloaded.assets.map(\.path))）
            """)
    }
}
