import Testing
import Foundation
@testable import Nanovid

// MARK: - 生成

/// ランダムな編集操作。EditorStore を通すので、UI から起きうることだけを並べる。
enum EditCommand {
    case addMedia(assetIndex: Int, trackIndex: Int, at: Double)
    case addText(templateIndex: Int, trackIndex: Int, at: Double)
    case select(indices: [Int])
    case selectInTrack(trackIndex: Int, count: Int)
    case selectAll
    case delete
    case duplicate
    case rippleDelete
    case pack
    case copy
    case cut
    case paste(at: Double)
    case split(at: Double)
    case move(clipIndex: Int, trackIndex: Int, start: Double)
    case moveSelection(delta: Double, laneDelta: Int)
    case trimLeft(clipIndex: Int, to: Double)
    case trimRight(clipIndex: Int, to: Double)
    case extractRange(from: Double, to: Double)
    case setOutputStart(Double)
    case setOutputEnd(Double)
    case resetOutputRange
    case addTrack(audio: Bool)
    case undo
    case redo
}

enum EditGen {

    /// 映像・音声・画像の素材と、テキストテンプレートを持つ土台。
    /// クリップは置かずに始めて、操作列で組み上げさせる。
    static func makeStore() -> EditorStore {
        var project = Project.starter()
        project.assets = [
            MediaAsset(path: "/tmp/a.mp4", displayName: "映像A", kind: .video, duration: 12,
                       naturalSize: CGSize(width: 1920, height: 1080), hasAudio: true, hasVideo: true),
            MediaAsset(path: "/tmp/b.mov", displayName: "映像B", kind: .video, duration: 5,
                       naturalSize: CGSize(width: 1280, height: 720), hasAudio: false, hasVideo: true),
            MediaAsset(path: "/tmp/c.wav", displayName: "音声C", kind: .audio, duration: 9,
                       naturalSize: nil, hasAudio: true, hasVideo: false),
            MediaAsset(path: "/tmp/d.png", displayName: "画像D", kind: .image, duration: 5,
                       naturalSize: CGSize(width: 800, height: 600), hasAudio: false, hasVideo: false),
        ]
        return EditorStore(project: project)
    }

    /// 生成しうる操作の名前。どれも一度は効いていることを確かめるために使う。
    static let allCommandNames = [
        "addMedia", "addText", "select", "selectInTrack", "selectAll", "delete", "duplicate",
        "rippleDelete", "pack", "copy", "cut", "paste", "split", "move",
        "moveSelection", "trimLeft", "trimRight", "extractRange",
        "setOutputStart", "setOutputEnd", "resetOutputRange", "addTrack", "undo", "redo",
    ]

    static func commands(count: Int, using g: inout SeededGenerator) -> [EditCommand] {
        (0..<count).map { _ in command(using: &g) }
    }

    /// 重みつきで 1 つ選ぶ。重みは「その操作が実際に効く頻度」を見て決める。
    /// pack のように前提（同じトラックで複数選択）が要るものは厚めにしないと、
    /// 引かれても素通りして一度も試されない。
    private static let weights: [(weight: Int, make: (inout SeededGenerator) -> EditCommand)] = [
        (3, { .addMedia(assetIndex: $0.int(in: 0...3), trackIndex: $0.int(in: 0...3),
                        at: $0.time(upTo: span, grid: grid)) }),
        (3, { .addText(templateIndex: $0.int(in: 0...3), trackIndex: $0.int(in: 0...3),
                       at: $0.time(upTo: span, grid: grid)) }),
        (2, { g in .select(indices: (0..<g.int(in: 1...3)).map { _ in g.int(in: 0...7) }) }),
        (4, { .selectInTrack(trackIndex: $0.int(in: 0...3), count: $0.int(in: 2...4)) }),
        (1, { _ in .selectAll }),
        (1, { _ in .delete }),
        (1, { _ in .duplicate }),
        (1, { _ in .rippleDelete }),
        (5, { _ in .pack }),
        (1, { _ in .copy }),
        (1, { _ in .cut }),
        (2, { .paste(at: $0.time(upTo: span, grid: grid)) }),
        (2, { .split(at: $0.time(upTo: span, grid: grid)) }),
        (2, { .move(clipIndex: $0.int(in: 0...7), trackIndex: $0.int(in: 0...3),
                    start: $0.time(upTo: span, grid: grid)) }),
        (1, { .moveSelection(delta: $0.double(in: -span...span), laneDelta: $0.int(in: -2...2)) }),
        (2, { .trimLeft(clipIndex: $0.int(in: 0...7), to: $0.time(upTo: span, grid: grid)) }),
        (2, { .trimRight(clipIndex: $0.int(in: 0...7), to: $0.time(upTo: span, grid: grid)) }),
        (1, { g in
            let a = g.time(upTo: span, grid: grid), b = g.time(upTo: span, grid: grid)
            return .extractRange(from: min(a, b), to: max(a, b))
        }),
        (1, { .setOutputStart($0.time(upTo: span, grid: grid)) }),
        (1, { .setOutputEnd($0.time(upTo: span, grid: grid)) }),
        (1, { _ in .resetOutputRange }),
        (1, { .addTrack(audio: $0.chance(0.4)) }),
        (2, { _ in .undo }),
        (2, { _ in .redo }),
    ]

    private static let grid = 1.0 / 30
    private static let span = 20.0

    private static func command(using g: inout SeededGenerator) -> EditCommand {
        let total = weights.reduce(0) { $0 + $1.weight }
        var ticket = g.int(in: 0...(total - 1))
        for entry in weights {
            ticket -= entry.weight
            if ticket < 0 { return entry.make(&g) }
        }
        return .selectAll
    }
}

// MARK: - 実行

/// 操作列を流す入れ物。
///
/// クリップボードは自前で持つ。ClipboardIO はプロセス共通のペーストボードを
/// 触るので、並列に走るテスト同士で混ざって再現しなくなる。
@MainActor
final class EditRunner {
    let store = EditGen.makeStore()
    private var clipboard: ClipboardPayload?

    /// 全トラックのクリップを表示順に並べたもの。添字で指すために使う。
    private var flatClips: [Clip] {
        store.project.tracks.flatMap(\.clips)
    }

    var shape: [String] { ProjectShape.of(store.project) }

    /// 「効いたか」を測るための、いまの状態のひとまとめ。
    /// クリップボードまで含めないと、コピーが何もしていないように見える。
    var fingerprint: [String] {
        shape + ["selection \(store.selectedClipIDs.count)"]
             + ["clipboard \(clipboard?.entries.count ?? -1)"]
    }

    /// 生成した操作を 1 つ流す。指した添字が無いときは何もしない（UI でも起きない操作）。
    func apply(_ command: EditCommand) {
        let clips = flatClips
        let tracks = store.project.tracks

        func track(_ index: Int) -> Track? {
            tracks.indices.contains(index) ? tracks[index] : nil
        }
        func clipID(_ index: Int) -> UUID? {
            clips.indices.contains(index) ? clips[index].id : nil
        }

        switch command {
        case .addMedia(let ai, let ti, let at):
            guard let track = track(ti), store.project.assets.indices.contains(ai) else { return }
            let asset = store.project.assets[ai]
            // UI と同じく、音声トラックには音声だけを落とす。
            guard (track.kind == .audio) == (asset.kind == .audio) else { return }
            store.addMediaClip(assetID: asset.id, trackID: track.id, at: at)

        case .addText(let index, let ti, let at):
            guard let track = track(ti), track.kind == .video,
                  store.project.textTemplates.indices.contains(index) else { return }
            store.addTextClip(templateID: store.project.textTemplates[index].id,
                              trackID: track.id, at: at)

        case .select(let indices):
            store.selectedClipIDs = Set(indices.compactMap(clipID))
        case .selectInTrack(let ti, let count):
            guard let track = track(ti) else { return }
            store.selectedClipIDs = Set(track.clips.prefix(count).map(\.id))
            store.selectedTrackID = track.id
        case .selectAll:
            store.selectAll()
        case .delete:
            store.deleteSelection()
        case .duplicate:
            store.duplicateSelection()
        case .rippleDelete:
            store.rippleDeleteSelection()
        case .pack:
            store.packSelection()

        // copySelection / cutSelection と同じ組み立てを、ペーストボードを介さずに使う。
        case .copy:
            clipboard = store.makePayload(of: store.selectedClipIDs) ?? clipboard
        case .cut:
            guard let payload = store.makePayload(of: store.selectedClipIDs) else { return }
            clipboard = payload
            store.deleteSelection()
        case .paste(let at):
            guard let payload = clipboard else { return }
            store.currentTime = at
            store.paste(payload)

        case .split(let at):
            store.currentTime = at
            store.splitAtPlayhead()
        case .move(let ci, let ti, let start):
            guard let id = clipID(ci), let track = track(ti) else { return }
            store.move(clipID: id, toTrack: track.id, start: start)
        case .moveSelection(let delta, let laneDelta):
            store.moveClips(store.selectedClipIDs, deltaSeconds: delta, laneDelta: laneDelta,
                            laneOrder: store.project.tracks.map(\.id))
        case .trimLeft(let ci, let to):
            guard let id = clipID(ci) else { return }
            store.trimLeft(clipID: id, to: to)
        case .trimRight(let ci, let to):
            guard let id = clipID(ci) else { return }
            store.trimRight(clipID: id, to: to)
        case .extractRange(let from, let to):
            guard to - from > 1e-6 else { return }
            store.extract(range: from...to)
        case .setOutputStart(let t):
            store.setOutputStart(t)
        case .setOutputEnd(let t):
            store.setOutputEnd(t)
        case .resetOutputRange:
            store.resetOutputRange()
        case .addTrack(let audio):
            store.addTrack(kind: audio ? .audio : .video)
        case .undo:
            store.undo()
        case .redo:
            store.redo()
        }
    }
}

// MARK: - 性質

/// ランダムな操作列を流しても、プロジェクトが壊れないこと。
@MainActor
struct EditingPropertyTests {

    /// 種から操作列を作って流し、破れた不変条件を返す。
    private func run(seed: UInt64, steps: Int = 40) -> (commands: [EditCommand], violations: [String]) {
        var generator = SeededGenerator(seed: seed)
        let commands = EditGen.commands(count: steps, using: &generator)
        return (commands, violations(of: commands))
    }

    private func violations(of commands: [EditCommand]) -> [String] {
        let runner = EditRunner()
        for command in commands {
            runner.apply(command)
            let found = ProjectInvariants.violations(in: runner.store.project)
            if !found.isEmpty { return found }
        }
        return []
    }

    @Test("どんな操作列のあともプロジェクトは壊れない", arguments: 0..<300)
    func editingKeepsProjectValid(seed: Int) {
        let (commands, found) = run(seed: UInt64(seed))
        guard !found.isEmpty else { return }
        // 落ちたら、まだ落ちる最小の列まで縮めてから報告する。
        let minimal = Shrink.minimalFailing(commands) { !violations(of: $0).isEmpty }
        Issue.record("""
            seed \(seed) で不変条件が破れました。
            破れた内容: \(violations(of: minimal).joined(separator: " / "))
            最小の手順 (\(minimal.count) 手):
            \(minimal.map { "  \($0)" }.joined(separator: "\n"))
            """)
    }

    @Test("編集したぶんだけ取り消せば元に戻る", arguments: 0..<200)
    func undoingEveryEditRestoresTheStart(seed: Int) {
        var generator = SeededGenerator(seed: UInt64(seed) &+ 0xBEEF)
        // undo/redo 自体は混ぜない。積んだ数と戻す数を一致させて見る。
        let commands = EditGen.commands(count: 30, using: &generator).filter {
            if case .undo = $0 { return false }
            if case .redo = $0 { return false }
            return true
        }

        let runner = EditRunner()
        let store = runner.store
        let original = store.project
        for command in commands { runner.apply(command) }

        // 積まれた回数がわからないので、戻せなくなるまで戻す。
        var guardCount = 0
        while store.canUndo && guardCount < 500 {
            store.undo()
            guardCount += 1
        }
        #expect(store.project == original,
                "seed \(seed): \(guardCount) 回戻しても元に戻らない")
    }

    /// EditorStore.checkpoint() のコメント「1 操作 = 1 スナップショット」をそのまま性質にする。
    ///
    /// 「最後まで戻すと最初に戻る」だけでは、checkpoint を積み忘れた操作を見逃す。
    /// 積み忘れた変更は次の操作のスナップショットに巻き込まれるので、
    /// 全部戻せばやはり最初に着いてしまうため。
    @Test("プロジェクトを変える操作は、取り消し 1 回ぶんだけ戻る", arguments: 0..<200)
    func eachEditIsExactlyOneUndoStep(seed: Int) {
        var generator = SeededGenerator(seed: UInt64(seed) &+ 0xF00D)
        let commands = EditGen.commands(count: 30, using: &generator).filter {
            // 取り消し自体は数えられないので外す。
            if case .undo = $0 { return false }
            if case .redo = $0 { return false }
            return true
        }

        let runner = EditRunner()
        for command in commands {
            let before = runner.shape
            runner.apply(command)
            let after = runner.shape
            guard after != before else { continue }   // 何も変えていない操作は対象外

            runner.store.undo()
            #expect(runner.shape == before,
                    "seed \(seed): \(command) が取り消し 1 回で戻らない")
            runner.store.redo()
            #expect(runner.shape == after,
                    "seed \(seed): \(command) をやり直せない")
        }
    }

    @Test("取り消してやり直すと同じ状態に戻る", arguments: 0..<200)
    func redoUndoesTheUndo(seed: Int) {
        var generator = SeededGenerator(seed: UInt64(seed) &+ 0xCAFE)
        let commands = EditGen.commands(count: 25, using: &generator).filter {
            if case .undo = $0 { return false }
            if case .redo = $0 { return false }
            return true
        }

        let runner = EditRunner()
        let store = runner.store
        for command in commands { runner.apply(command) }
        let after = store.project

        guard store.canUndo else { return }
        store.undo()
        store.redo()
        #expect(store.project == after, "seed \(seed): undo → redo で戻らない")
    }
}

/// 生成器そのものの健全性。操作列が実際にプロジェクトを動かしているかを見る。
/// これが無いと、全部空振りしていても性質テストは緑になる。
@MainActor
struct EditingGeneratorTests {

    /// 操作の種類ごとに「実際にプロジェクトが変わった回数」。
    /// 0 の操作があると、その経路は一度も試されていない。
    static func effectCounts(seeds: Range<Int>, steps: Int) -> [String: Int] {
        var counts: [String: Int] = [:]
        for seed in seeds {
            var generator = SeededGenerator(seed: UInt64(seed))
            let commands = EditGen.commands(count: steps, using: &generator)
            let runner = EditRunner()
            let store = runner.store
            for command in commands {
                // 選択やクリップボードを変えるだけの操作もあるので、そこまで含めて見る。
                let before = runner.fingerprint
                runner.apply(command)
                let after = runner.fingerprint
                let name = String(describing: command).prefix(while: { $0 != "(" })
                counts[String(name), default: 0] += (after == before) ? 0 : 1
            }
        }
        return counts
    }

    @Test("どの操作も一度は実際に効いている")
    func everyCommandHasAnEffect() {
        let counts = Self.effectCounts(seeds: 0..<120, steps: 40)
        let breakdown = counts.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        // 10 回は効いてほしい。1〜2 回だと、その経路のバグを見逃す。
        // 実際 pack は 3 回しか効いておらず、checkpoint を外す変異を捕まえられなかった。
        let thin = EditGen.allCommandNames.filter { (counts[$0] ?? 0) < 10 }
        #expect(thin.isEmpty, """
            試行が薄い操作があります: \(thin.joined(separator: ", "))
            内訳: \(breakdown)
            """)
    }

    @Test("操作列はプロジェクトを実際に動かしている")
    func sequencesActuallyEdit() {
        var totalClips = 0
        var withClips = 0
        var seedsThatEdited = 0
        let seeds = 0..<60

        for seed in seeds {
            var generator = SeededGenerator(seed: UInt64(seed))
            let commands = EditGen.commands(count: 40, using: &generator)
            let runner = EditRunner()
            let store = runner.store
            for command in commands { runner.apply(command) }

            let count = store.project.tracks.reduce(0) { $0 + $1.clips.count }
            totalClips += count
            if count > 0 { withClips += 1 }
            if store.project != Project.starter() { seedsThatEdited += 1 }
        }

        #expect(seedsThatEdited == seeds.count, "どの種でも何かしら編集されるはず")
        #expect(withClips >= seeds.count / 2,
                "半分以上の種でクリップが残ってほしい（実測 \(withClips)/\(seeds.count)）")
        #expect(totalClips >= seeds.count,
                "1 種あたり平均 1 本以上は置かれてほしい（実測 \(totalClips) 本）")
    }
}

/// 操作列の再現性。同じ種から同じ結果になること。
///
/// 再現しない列があると、縮小しても原因にたどり着けないし、
/// たまに赤くなるテストになってしまう。
@MainActor
struct EditingDeterminismTests {

    @Test("同じ操作列は何度流しても同じプロジェクトになる", arguments: 0..<40)
    func sequencesAreReproducible(seed: Int) {
        var generator = SeededGenerator(seed: UInt64(seed))
        let commands = EditGen.commands(count: 40, using: &generator)

        // ID は毎回新しく振られるので、位置と中身だけを見る。
        func run() -> [String] {
            let runner = EditRunner()
            for command in commands { runner.apply(command) }
            return runner.shape
        }
        #expect(run() == run(), "seed \(seed) で結果が揺れる")
    }
}
