import AppKit
import Foundation

/// `Nanovid --render <プロジェクト> [オプション]` で、指定した時刻のコマを PNG に書いて終了する。
///
/// ```sh
/// Nanovid --render movie.nanovid --at 0.5,1.5 --out /tmp/frames --path both
/// ```
///
/// - `--at 秒,秒,…`  描く時刻。省くと、見えるレイヤーの組み合わせが変わる区間ごとに 1 枚。
/// - `--out ディレクトリ`  書き出し先。省くと一時ディレクトリの nanovid-render。
/// - `--path direct|player|both`  描き方（FrameRenderer.Path）。既定は both。
///   both なら 2 つを比べ、差のある画素を赤くした絵（-diff.png）も書く。
/// - `--sources decoded|stub`  direct で使う素材フレーム。既定は decoded。
/// - `--tolerance 割合`  both で「違う」とみなす、差のある画素の割合。既定 0.002（0.2%）。
///
/// 出力先には PNG と report.json（各コマのレイヤー構成・差・描けなかったクリップ）を置く。
/// 終わりちょうどやその先の時刻は、最後のコマとして描く。
/// 終了コード: 0 = 問題なし、1 = 失敗、2 = both で差が許容を超えたコマがある。
enum RenderCommand {

    struct Options {
        var project: URL
        var times: [Double]?
        var out: URL
        var paths: [FrameRenderer.Path] = FrameRenderer.Path.allCases
        var sources: FrameRenderer.Sources = .decoded
        var tolerance: Double = 0.002
    }

    /// 引数を読む。`--render` が無ければ nil。
    static func parse(_ args: [String]) throws -> Options? {
        guard let idx = args.firstIndex(of: "--render") else { return nil }
        guard args.count > idx + 1, !args[idx + 1].hasPrefix("--") else {
            throw UsageError("--render の後ろにプロジェクトのパスが要ります。")
        }
        var options = Options(
            project: URL(fileURLWithPath: args[idx + 1]),
            out: FileManager.default.temporaryDirectory.appendingPathComponent("nanovid-render"))

        var i = idx + 2
        func value(_ name: String) throws -> String {
            guard i + 1 < args.count else { throw UsageError("\(name) の値がありません。") }
            i += 1
            return args[i]
        }
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--at":
                let raw = try value(arg)
                let times = raw.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
                guard !times.isEmpty, times.allSatisfy({ $0?.isFinite == true }) else {
                    throw UsageError("--at は「0.5,1.5」のように秒をカンマで並べます: \(raw)")
                }
                options.times = times.compactMap { $0 }
            case "--out":
                options.out = URL(fileURLWithPath: try value(arg))
            case "--path":
                let raw = try value(arg)
                if raw == "both" {
                    options.paths = FrameRenderer.Path.allCases
                } else if let path = FrameRenderer.Path(rawValue: raw) {
                    options.paths = [path]
                } else {
                    throw UsageError("--path は direct / player / both のどれかです: \(raw)")
                }
            case "--sources":
                let raw = try value(arg)
                guard let sources = FrameRenderer.Sources(rawValue: raw) else {
                    throw UsageError("--sources は decoded / stub のどちらかです: \(raw)")
                }
                options.sources = sources
            case "--tolerance":
                let raw = try value(arg)
                guard let t = Double(raw), t.isFinite, t >= 0 else {
                    throw UsageError("--tolerance は 0 以上の数です: \(raw)")
                }
                options.tolerance = t
            default:
                // ほかの起動オプション（-NS… など）は読み飛ばす。
                break
            }
            i += 1
        }
        return options
    }

    struct UsageError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    // MARK: - レポート

    struct Report: Codable {
        struct Canvas: Codable {
            var width: Int
            var height: Int
            var fps: Int
        }
        struct Comparison: Codable {
            /// 全画素の成分ごとの差の平均（0…255）。
            var meanDifference: Double
            /// はっきり違う画素の割合（0…1）。
            var changedFraction: Double
            var withinTolerance: Bool
        }
        struct FrameEntry: Codable {
            var time: Double
            var files: [String: String]
            var description: FrameRenderer.Description?
            var comparison: Comparison?
            var errors: [String: String]?
        }
        var project: String
        var canvas: Canvas
        var duration: Double
        var sources: String
        var tolerance: Double
        var frames: [FrameEntry]
        /// 置いてあるのに描けなかったクリップ。
        var skipped: [SkippedClip]
        var ok: Bool
    }

    // MARK: - 実行

    static func runIfRequested() -> Bool {
        let options: Options
        do {
            guard let parsed = try parse(CommandLine.arguments) else { return false }
            options = parsed
        } catch {
            FileHandle.standardError.write("FAIL: \(error.localizedDescription)\n".data(using: .utf8)!)
            exit(1)
        }

        let sem = DispatchSemaphore(value: 0)
        var result: Result<Report, Error> = .failure(CocoaError(.featureUnsupported))
        Task.detached {
            do { result = .success(try await run(options)) } catch { result = .failure(error) }
            sem.signal()
        }
        sem.wait()

        switch result {
        case .success(let report):
            exit(report.ok ? 0 : 2)
        case .failure(let error):
            FileHandle.standardError.write("FAIL: \(error.localizedDescription)\n".data(using: .utf8)!)
            exit(1)
        }
    }

    static func run(_ options: Options) async throws -> Report {
        let project = try ProjectIO.load(from: options.project)
        let base = options.project.deletingLastPathComponent()
        let renderer = try await FrameRenderer.make(project: project, baseURL: base)
        try FileManager.default.createDirectory(at: options.out, withIntermediateDirectories: true)

        let times = options.times ?? renderer.segmentMidpoints()
        print("プロジェクト: \(project.name)  \(project.canvas.width)x\(project.canvas.height)"
              + String(format: " / 尺 %.2f 秒 / %d コマ", project.duration, times.count))
        for clip in renderer.built.skipped {
            print("  描かないクリップ: \(clip.name)（\(clip.reason)）")
        }

        var entries: [Report.FrameEntry] = []
        var allOK = true
        var usedStems: [String: Int] = [:]
        for time in times {
            let baseStem = String(format: "t%08.3f", time)
            let occurrence = (usedStems[baseStem] ?? 0) + 1
            usedStems[baseStem] = occurrence
            let stem = occurrence == 1 ? baseStem : "\(baseStem)-\(occurrence)"

            var entry = Report.FrameEntry(time: time, files: [:],
                                          description: renderer.describe(at: time))
            var frames: [FrameRenderer.Path: RGBAFrame] = [:]
            var errors: [String: String] = [:]
            var images: [FrameRenderer.Path: CGImage] = [:]
            for path in options.paths {
                do {
                    let image = try await renderer.render(at: time, path: path, sources: options.sources)
                    let file = "\(stem)-\(path.rawValue).png"
                    try image.writePNG(to: options.out.appendingPathComponent(file))
                    entry.files[path.rawValue] = file
                    images[path] = image
                    frames[path] = RGBAFrame(image)
                } catch {
                    errors[path.rawValue] = error.localizedDescription
                }
            }

            var line = String(format: "  %8.3f 秒  レイヤー %d", time, entry.description?.layers.count ?? 0)
            if let direct = frames[.direct], let player = frames[.player] {
                let changed = direct.changedFraction(from: player)
                let comparison = Report.Comparison(
                    meanDifference: direct.difference(from: player),
                    changedFraction: changed,
                    withinTolerance: changed <= options.tolerance)
                entry.comparison = comparison
                line += String(format: "  差 %.2f%%（平均 %.2f）", changed * 100, comparison.meanDifference)
                if !comparison.withinTolerance {
                    allOK = false
                    line += "  ← 違う"
                    if let diff = direct.differenceImage(from: player) {
                        let file = "\(stem)-diff.png"
                        try diff.writePNG(to: options.out.appendingPathComponent(file))
                        entry.files["diff"] = file
                    }
                }
            }
            if !errors.isEmpty {
                allOK = false
                entry.errors = errors
                line += "  失敗: " + errors.map { "\($0.key) \($0.value)" }.sorted().joined(separator: " / ")
            }
            print(line)
            entries.append(entry)
        }

        let report = Report(
            project: options.project.path,
            canvas: .init(width: project.canvas.width, height: project.canvas.height, fps: project.canvas.fps),
            duration: project.duration,
            sources: options.sources.rawValue,
            tolerance: options.tolerance,
            frames: entries,
            skipped: renderer.built.skipped,
            ok: allOK)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: options.out.appendingPathComponent("report.json"))
        print(allOK ? "OK" : "差または失敗あり", options.out.path)
        return report
    }
}
