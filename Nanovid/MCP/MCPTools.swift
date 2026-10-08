import AppKit
import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// MCP から呼べる道具。どれも起動中の EditorStore を通して編集するので、
/// 画面にそのまま映り、⌘Z で取り消せる。
///
/// 説明文とエラーは AI が読むものなので英語で書き、訳さない。
@MainActor
enum MCPTools {

    struct Failure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// tools/call の結果の content。
    enum Content {
        case text(String)
        case json(Any)
        case image(Data, mimeType: String)

        var payload: [String: Any] {
            switch self {
            case .text(let s):
                return ["type": "text", "text": s]
            case .json(let value):
                return ["type": "text", "text": MCPJSON.string(value, pretty: true)]
            case .image(let data, let mime):
                return ["type": "image", "data": data.base64EncodedString(), "mimeType": mime]
            }
        }
    }

    // MARK: - 一覧

    static var definitions: [[String: Any]] {
        [
            tool("get_project",
                 "Read the project open in Nanovid: canvas, output range, tracks and their clips, "
                 + "imported media assets, and text templates (with their editable props). "
                 + "Tracks are listed back to front: later video tracks draw on top of earlier ones. "
                 + "All times are in seconds. Call this first to learn the IDs other tools take.",
                 [:]),
            tool("import_media",
                 "Import video, audio or image files into the project's media library. "
                 + "With append_to_timeline, also place each one at the end of a matching track. "
                 + "The sandboxed App Store build can only read files the user has opened or chosen in Nanovid "
                 + "(for example by dragging them into the window); ask the user to import other files from the app.",
                 ["paths": array(of: ["type": "string"], "Absolute file paths."),
                  "append_to_timeline": boolean("Place the imported media at the end of the timeline. Default false.")],
                 required: ["paths"]),
            tool("add_media_clip",
                 "Place an imported asset on the timeline. Returns the new clip's ID.",
                 ["asset_id": string("Asset ID from get_project."),
                  "start": number("Timeline position in seconds."),
                  "track_id": string("Target track. Defaults to the backmost track of the matching kind "
                                     + "(video or audio) that is free over the clip's time span.")],
                 required: ["asset_id", "start"]),
            tool("add_text_clip",
                 "Place a text (caption / title) clip that renders through a text template. Returns the new clip's ID.",
                 ["start": number("Timeline position in seconds."),
                  "duration": number("Length in seconds. Default 3."),
                  "template_id": string("Text template ID from get_project. Defaults to the first template."),
                  "track_id": string("Target video track. Defaults to the frontmost video track that is "
                                     + "free over the clip's time span."),
                  "props": propsSchema],
                 required: ["start"]),
            tool("add_track",
                 "Add an empty track. A new video track draws in front of the existing ones. Returns its ID.",
                 ["kind": ["type": "string", "enum": ["video", "audio"]]],
                 required: ["kind"]),
            tool("move_clip",
                 "Move a clip to a new start time, optionally onto another track of the same kind.",
                 ["clip_id": string("Clip ID."),
                  "start": number("New timeline position in seconds."),
                  "track_id": string("Destination track. Defaults to the clip's current track.")],
                 required: ["clip_id", "start"]),
            tool("trim_clip",
                 "Trim a clip by moving its start and/or end edge on the timeline. Moving the start "
                 + "edge also shifts where the media starts playing. Media clips cannot extend past their source.",
                 ["clip_id": string("Clip ID."),
                  "start": number("New start edge in seconds."),
                  "end": number("New end edge in seconds.")],
                 required: ["clip_id"]),
            tool("split_clips",
                 "Cut clips at a time. Without clip_ids, cuts every clip under that time on unlocked tracks. "
                 + "Returns the IDs of the new right-hand pieces.",
                 ["time": number("Where to cut, in seconds."),
                  "clip_ids": array(of: ["type": "string"], "Only cut these clips.")],
                 required: ["time"]),
            tool("delete_clips",
                 "Delete clips. With ripple, later clips on every track move left to close the gap.",
                 ["clip_ids": array(of: ["type": "string"], "Clip IDs."),
                  "ripple": boolean("Close the gap left behind. Default false.")],
                 required: ["clip_ids"]),
            tool("set_clip_properties",
                 "Change appearance and sound of clips. Only the given fields change.",
                 ["clip_ids": array(of: ["type": "string"], "Clip IDs."),
                  "name": string("Clip name."),
                  "opacity": number("0 to 1."),
                  "volume": number("0 to 1 (can exceed 1 to boost)."),
                  "fade_in": number("Fade-in length in seconds."),
                  "fade_out": number("Fade-out length in seconds."),
                  "position": ["type": "object",
                               "description": "Offset from the canvas center as a fraction of canvas width (x) and height (y).",
                               "properties": ["x": ["type": "number"], "y": ["type": "number"]]],
                  "scale": number("1 is the fitted size."),
                  "rotation": number("Degrees.")],
                 required: ["clip_ids"]),
            tool("set_text_props",
                 "Override template props (text, colors…) on text clips. Pass null for a key to "
                 + "reset it to the template default.",
                 ["clip_ids": array(of: ["type": "string"], "Text clip IDs."),
                  "props": propsSchema],
                 required: ["clip_ids", "props"]),
            tool("set_output_range",
                 "Set which part of the timeline gets exported. With auto, follow the end of the last clip again.",
                 ["start": number("Seconds."),
                  "end": number("Seconds."),
                  "auto": boolean("Reset to following the clips.")]),
            tool("set_canvas",
                 "Change output resolution and/or frame rate.",
                 ["width": integer("Pixels."), "height": integer("Pixels."), "fps": integer("Frames per second.")]),
            tool("seek",
                 "Move the playhead so the user sees that moment in the preview.",
                 ["time": number("Seconds.")],
                 required: ["time"]),
            tool("render_frame",
                 "Render one frame of the composition as a JPEG, exactly as it will be exported. "
                 + "Use it to check layout and captions.",
                 ["time": number("Seconds. Defaults to the playhead."),
                  "max_width": integer("Longest edge of the image in pixels. Default 960.")]),
            tool("undo", "Undo the last edit (the same as ⌘Z in the app).", [:]),
            tool("redo", "Redo the last undone edit.", [:]),
            tool("save_project",
                 "Save the project to its file. A project that was never saved has to be saved from the app first.",
                 [:]),
            tool("export_video",
                 "Export the output range to an MP4 file and wait until it is done.",
                 ["path": string("Destination .mp4 path. If omitted, Nanovid shows a standard save dialog "
                                 + "and the user chooses where to save. The sandboxed App Store build can only "
                                 + "write to locations the user has chosen, so prefer omitting it."),
                  "codec": ["type": "string", "enum": ["h264", "hevc"], "description": "Default h264."],
                  "quality": ["type": "string", "enum": ["standard", "high", "max"], "description": "Default high."]]),
        ]
    }

    // MARK: - 呼び出し

    static func call(_ name: String, _ args: [String: Any], store: EditorStore) async throws -> [Content] {
        switch name {
        case "get_project": return [.json(projectSummary(store))]
        case "import_media": return try await importMedia(args, store)
        case "add_media_clip": return try addMediaClip(args, store)
        case "add_text_clip": return try addTextClip(args, store)
        case "add_track": return try addTrack(args, store)
        case "move_clip": return try moveClip(args, store)
        case "trim_clip": return try trimClip(args, store)
        case "split_clips": return try splitClips(args, store)
        case "delete_clips": return try deleteClips(args, store)
        case "set_clip_properties": return try setClipProperties(args, store)
        case "set_text_props": return try setTextProps(args, store)
        case "set_output_range": return try setOutputRange(args, store)
        case "set_canvas": return try setCanvas(args, store)
        case "seek":
            store.pause()
            store.seek(to: try number(args, "time"))
            return [.text("Playhead at \(seconds(store.currentTime)).")]
        case "render_frame": return try await renderFrame(args, store)
        case "undo":
            guard store.canUndo else { throw Failure("Nothing to undo.") }
            store.undo()
            return [.text("Undone.")]
        case "redo":
            guard store.canRedo else { throw Failure("Nothing to redo.") }
            store.redo()
            return [.text("Redone.")]
        case "save_project": return try saveProject(store)
        case "export_video": return try await exportVideo(args, store)
        default: throw Failure("Unknown tool: \(name)")
        }
    }

    // MARK: - 読む

    static func projectSummary(_ store: EditorStore) -> [String: Any] {
        let p = store.project
        var out: [String: Any] = [
            "name": p.name,
            "file": store.documentURL?.path ?? NSNull(),
            "has_unsaved_changes": store.hasUnsavedChanges,
            "canvas": ["width": p.canvas.width, "height": p.canvas.height, "fps": p.canvas.fps,
                       "background": p.canvas.backgroundColor.hexString],
            "output_range": ["start": p.outputStart, "end": p.outputEnd, "duration": p.duration,
                             "auto": !p.hasExplicitOutputRange],
            "playhead": store.currentTime,
            "selected_clip_ids": store.selectedClipIDs.map(\.uuidString).sorted(),
        ]
        out["assets"] = p.assets.map { a -> [String: Any] in
            ["id": a.id.uuidString, "name": a.displayName, "kind": a.kind.rawValue,
             "duration": a.duration, "path": a.url(relativeTo: store.baseURL).path]
        }
        out["text_templates"] = p.textTemplates.map { t -> [String: Any] in
            ["id": t.id.uuidString, "name": LName(t.name),
             "props": t.props.map { d -> [String: Any] in
                 ["key": d.key, "label": LName(d.label), "type": d.type.rawValue,
                  "default": jsonValue(d.defaultValue)]
             }]
        }
        // 先頭が最背面。並びはそのまま返し、説明の側でそう伝える。
        out["tracks"] = p.tracks.map { track -> [String: Any] in
            ["id": track.id.uuidString, "name": track.name, "kind": track.kind.rawValue,
             "muted": track.isMuted, "hidden": track.isHidden, "locked": track.isLocked,
             "clips": track.clips.map { clipSummary($0, in: p) }]
        }
        return out
    }

    private static func clipSummary(_ clip: Clip, in p: Project) -> [String: Any] {
        var out: [String: Any] = [
            "id": clip.id.uuidString, "name": clip.name,
            "start": clip.start, "duration": clip.duration, "end": clip.end,
        ]
        switch clip.content {
        case .media(let assetID, let sourceStart):
            out["type"] = "media"
            out["asset_id"] = assetID.uuidString
            out["source_start"] = sourceStart
        case .text(let inst):
            out["type"] = "text"
            out["template_id"] = inst.templateID.uuidString
            if let template = p.template(inst.templateID) {
                out["props"] = inst.resolvedProps(in: template).mapValues(jsonValue)
            }
        }
        if clip.opacity != 1 { out["opacity"] = clip.opacity }
        if clip.volume != 1 { out["volume"] = clip.volume }
        if clip.fade.inDuration > 0 { out["fade_in"] = clip.fade.inDuration }
        if clip.fade.outDuration > 0 { out["fade_out"] = clip.fade.outDuration }
        if clip.transform != .identity {
            out["position"] = ["x": clip.transform.position.x, "y": clip.transform.position.y]
            out["scale"] = clip.transform.scale
            out["rotation"] = clip.transform.rotation
        }
        return out
    }

    // MARK: - 素材とクリップ

    private static func importMedia(_ args: [String: Any], _ store: EditorStore) async throws -> [Content] {
        let paths = try strings(args, "paths")
        guard !paths.isEmpty else { throw Failure("paths is empty.") }
        let urls = paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        for url in urls where !FileManager.default.isReadableFile(atPath: url.path) {
            throw Failure(FileManager.default.fileExists(atPath: url.path)
                ? "Cannot read \(url.path). The sandboxed App Store build can only read files the user has "
                    + "opened or chosen in Nanovid. Ask the user to import it from the app."
                : "No such file: \(url.path)")
        }
        store.buildError = nil
        let assets = await store.importAssets(urls: urls)
        var out: [String: Any] = [
            "assets": assets.map { ["id": $0.id.uuidString, "name": $0.displayName,
                                    "kind": $0.kind.rawValue, "duration": $0.duration] },
        ]
        if let problem = store.buildError { out["problem"] = problem }
        if assets.isEmpty { throw Failure(store.buildError ?? "Nothing could be imported.") }
        if bool(args, "append_to_timeline") ?? false {
            out["clip_ids"] = store.appendAtEnd(assets).map(\.uuidString)
        }
        return [.json(out)]
    }

    private static func addMediaClip(_ args: [String: Any], _ store: EditorStore) throws -> [Content] {
        let assetID = try uuid(args, "asset_id")
        guard let asset = store.project.asset(assetID) else { throw Failure("No asset \(assetID.uuidString).") }
        let kind: TrackKind = asset.kind == .audio ? .audio : .video
        let start = try number(args, "start")
        let span = start..<(start + (asset.kind == .image ? 5 : asset.duration))
        let track = try track(args, store, default: freeTrack(kind, over: span, in: store.project.tracks))
        guard track.kind == kind else { throw Failure("A \(asset.kind.rawValue) asset cannot go on a \(track.kind.rawValue) track.") }
        try requireUnlocked(track)
        guard let id = store.addMediaClip(assetID: assetID, trackID: track.id, at: start) else {
            throw Failure("Could not place the clip.")
        }
        return [.json(["clip_id": id.uuidString])]
    }

    private static func addTextClip(_ args: [String: Any], _ store: EditorStore) throws -> [Content] {
        let p = store.project
        let template: TextTemplate
        if args["template_id"] != nil {
            let id = try uuid(args, "template_id")
            guard let t = p.template(id) else { throw Failure("No text template \(id.uuidString).") }
            template = t
        } else {
            guard let t = p.textTemplates.first else { throw Failure("The project has no text templates.") }
            template = t
        }
        let start = try number(args, "start")
        let duration = number(args, "duration", default: 3)
        guard duration > 0 else { throw Failure("duration must be positive.") }
        let track = try track(args, store, default: freeTrack(.video, over: start..<(start + duration),
                                                              in: p.tracks.reversed()))
        guard track.kind == .video else { throw Failure("Text clips go on video tracks.") }
        try requireUnlocked(track)

        var inst = TextInstance(templateID: template.id)
        if let props = args["props"] as? [String: Any] {
            for (key, raw) in props where !(raw is NSNull) {
                inst.props[key] = try propValue(raw, key: key, in: template)
            }
        }
        let clip = Clip(name: template.name,
                        start: p.canvas.snap(max(0, start)),
                        duration: max(p.canvas.frameDuration, p.canvas.snap(duration)),
                        content: .text(inst))
        store.edit { project in
            guard let ti = project.tracks.firstIndex(where: { $0.id == track.id }) else { return }
            project.tracks[ti].clips.append(clip)
            project.tracks[ti].sortClips()
        }
        return [.json(["clip_id": clip.id.uuidString])]
    }

    private static func addTrack(_ args: [String: Any], _ store: EditorStore) throws -> [Content] {
        guard let raw = args["kind"] as? String, let kind = TrackKind(rawValue: raw) else {
            throw Failure("kind must be video or audio.")
        }
        let before = Set(store.project.tracks.map(\.id))
        store.addTrack(kind: kind)
        guard let track = store.project.tracks.first(where: { !before.contains($0.id) }) else {
            throw Failure("Could not add a track.")
        }
        return [.json(["track_id": track.id.uuidString, "name": track.name])]
    }

    private static func moveClip(_ args: [String: Any], _ store: EditorStore) throws -> [Content] {
        let id = try uuid(args, "clip_id")
        guard let from = store.project.track(containing: id) else { throw Failure("No clip \(id.uuidString).") }
        let to = try track(args, store, default: from)
        try requireUnlocked(from)
        try requireUnlocked(to)
        guard let clip = store.project.clip(id), store.accepts(clip: clip, track: to) else {
            throw Failure("That clip cannot go on a \(to.kind.rawValue) track.")
        }
        store.move(clipID: id, toTrack: to.id, start: try number(args, "start"))
        return [.json(clipSummary(store.project.clip(id)!, in: store.project))]
    }

    private static func trimClip(_ args: [String: Any], _ store: EditorStore) throws -> [Content] {
        let id = try uuid(args, "clip_id")
        guard let track = store.project.track(containing: id) else { throw Failure("No clip \(id.uuidString).") }
        try requireUnlocked(track)
        let start = args["start"].flatMap(asDouble)
        let end = args["end"].flatMap(asDouble)
        guard start != nil || end != nil else { throw Failure("Give start, end, or both.") }
        if let start { store.trimLeft(clipID: id, to: start) }
        if let end { store.trimRight(clipID: id, to: end) }
        return [.json(clipSummary(store.project.clip(id)!, in: store.project))]
    }

    private static func splitClips(_ args: [String: Any], _ store: EditorStore) throws -> [Content] {
        let time = try number(args, "time")
        let ids = Set(try optionalUUIDs(args, "clip_ids") ?? [])
        for id in ids where store.project.clip(id) == nil { throw Failure("No clip \(id.uuidString).") }
        let before = Set(store.project.tracks.flatMap(\.clips).map(\.id))
        store.pause()
        store.seek(to: time)
        store.selectedClipIDs = ids
        store.splitAtPlayhead()
        let made = store.project.tracks.flatMap(\.clips).map(\.id).filter { !before.contains($0) }
        guard !made.isEmpty else { throw Failure("No clip spans \(seconds(time)), so nothing was cut.") }
        return [.json(["new_clip_ids": made.map(\.uuidString)])]
    }

    private static func deleteClips(_ args: [String: Any], _ store: EditorStore) throws -> [Content] {
        let ids = Set(try uuids(args, "clip_ids"))
        for id in ids {
            guard let track = store.project.track(containing: id) else { throw Failure("No clip \(id.uuidString).") }
            try requireUnlocked(track)
        }
        store.selectedClipIDs = ids
        if bool(args, "ripple") ?? false { store.rippleDeleteSelection() } else { store.deleteSelection() }
        return [.text("Deleted \(ids.count) clip(s).")]
    }

    private static func setClipProperties(_ args: [String: Any], _ store: EditorStore) throws -> [Content] {
        let ids = Set(try uuids(args, "clip_ids"))
        for id in ids where store.project.clip(id) == nil { throw Failure("No clip \(id.uuidString).") }
        let name = args["name"] as? String
        let opacity = args["opacity"].flatMap(asDouble)
        let volume = args["volume"].flatMap(asDouble)
        let fadeIn = args["fade_in"].flatMap(asDouble)
        let fadeOut = args["fade_out"].flatMap(asDouble)
        let position = (args["position"] as? [String: Any]).map {
            CGPoint(x: $0["x"].flatMap(asDouble) ?? 0, y: $0["y"].flatMap(asDouble) ?? 0)
        }
        let scale = args["scale"].flatMap(asDouble)
        let rotation = args["rotation"].flatMap(asDouble)
        store.edit { p in
            for ti in p.tracks.indices {
                for ci in p.tracks[ti].clips.indices where ids.contains(p.tracks[ti].clips[ci].id) {
                    var c = p.tracks[ti].clips[ci]
                    if let name { c.name = name }
                    if let opacity { c.opacity = max(0, min(1, opacity)) }
                    if let volume { c.volume = max(0, volume) }
                    if let fadeIn { c.fade.inDuration = max(0, min(c.duration, fadeIn)) }
                    if let fadeOut { c.fade.outDuration = max(0, min(c.duration, fadeOut)) }
                    if let position { c.transform.position = position }
                    if let scale { c.transform.scale = max(0.01, scale) }
                    if let rotation { c.transform.rotation = rotation }
                    p.tracks[ti].clips[ci] = c
                }
            }
        }
        return [.json(ids.compactMap { store.project.clip($0) }.map { clipSummary($0, in: store.project) })]
    }

    private static func setTextProps(_ args: [String: Any], _ store: EditorStore) throws -> [Content] {
        let ids = Set(try uuids(args, "clip_ids"))
        guard let raw = args["props"] as? [String: Any], !raw.isEmpty else { throw Failure("props is empty.") }
        // 先に全部確かめてから、1 回の編集（1 つの undo）で書き換える。
        var changes: [UUID: [String: PropValue?]] = [:]
        for id in ids {
            guard let clip = store.project.clip(id) else { throw Failure("No clip \(id.uuidString).") }
            guard let inst = clip.content.textInstance,
                  let template = store.project.template(inst.templateID) else {
                throw Failure("Clip \(id.uuidString) is not a text clip.")
            }
            var change: [String: PropValue?] = [:]
            for (key, value) in raw {
                change[key] = value is NSNull ? .some(nil) : try propValue(value, key: key, in: template)
            }
            changes[id] = change
        }
        store.edit { p in
            for ti in p.tracks.indices {
                for ci in p.tracks[ti].clips.indices {
                    guard let change = changes[p.tracks[ti].clips[ci].id],
                          var inst = p.tracks[ti].clips[ci].content.textInstance else { continue }
                    for (key, value) in change { inst.props[key] = value }
                    p.tracks[ti].clips[ci].content = .text(inst)
                }
            }
        }
        return [.json(ids.compactMap { store.project.clip($0) }.map { clipSummary($0, in: store.project) })]
    }

    // MARK: - プロジェクト

    private static func setOutputRange(_ args: [String: Any], _ store: EditorStore) throws -> [Content] {
        if bool(args, "auto") ?? false {
            store.resetOutputRange()
        } else {
            let start = args["start"].flatMap(asDouble)
            let end = args["end"].flatMap(asDouble)
            guard start != nil || end != nil else { throw Failure("Give start, end, or auto.") }
            if let start { store.setOutputStart(start) }
            if let end { store.setOutputEnd(end) }
        }
        let p = store.project
        return [.json(["start": p.outputStart, "end": p.outputEnd, "duration": p.duration,
                       "auto": !p.hasExplicitOutputRange])]
    }

    private static func setCanvas(_ args: [String: Any], _ store: EditorStore) throws -> [Content] {
        let c = store.project.canvas
        let width = args["width"].flatMap(asDouble).map(Int.init) ?? c.width
        let height = args["height"].flatMap(asDouble).map(Int.init) ?? c.height
        let fps = args["fps"].flatMap(asDouble).map(Int.init) ?? c.fps
        guard (16...8192).contains(width), (16...8192).contains(height) else {
            throw Failure("width and height must be between 16 and 8192.")
        }
        guard (1...240).contains(fps) else { throw Failure("fps must be between 1 and 240.") }
        store.setCanvas(width: width, height: height, fps: fps)
        return [.json(["width": width, "height": height, "fps": fps])]
    }

    private static func saveProject(_ store: EditorStore) throws -> [Content] {
        guard let url = store.documentURL else {
            throw Failure("This project has never been saved. Ask the user to save it from the app (⌘S) first.")
        }
        guard store.save() else { throw Failure("Saving failed.") }
        return [.text("Saved to \(url.path).")]
    }

    // MARK: - 描画と書き出し

    private static func renderFrame(_ args: [String: Any], _ store: EditorStore) async throws -> [Content] {
        let time = args["time"].flatMap(asDouble) ?? store.currentTime
        let maxWidth = args["max_width"].flatMap(asDouble) ?? 960
        let project = store.project
        let built = try await CompositionBuilder.build(project: project, baseURL: store.baseURL)
        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = built.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.appliesPreferredTrackTransform = false
        let edge = max(64, min(4096, maxWidth))
        generator.maximumSize = CGSize(width: edge, height: edge)
        let (image, _) = try await generator.image(at: max(0, time).cmTime)
        guard let jpeg = NSBitmapImageRep(cgImage: image)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            throw Failure("Could not encode the frame.")
        }
        return [.image(jpeg, mimeType: "image/jpeg"),
                .text("Frame at \(seconds(time)), \(image.width)×\(image.height).")]
    }

    private static func exportVideo(_ args: [String: Any], _ store: EditorStore) async throws -> [Content] {
        guard store.duration > 0 else { throw Failure("The output range is empty.") }
        let url: URL
        if let path = args["path"] as? String {
            url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        } else {
            // 決め打ちの場所（~/Movies など）には書かない（App Review 2.4.5(i)）。
            // 標準の保存パネルで、置き場所をユーザーに選んでもらう。
            guard let chosen = chooseExportDestination(store) else {
                throw Failure("The user cancelled the save dialog. Nothing was exported.")
            }
            url = chosen
        }
        var settings = ExportSettings()
        if let codec = args["codec"] as? String {
            guard let value = ExportSettings.Codec(rawValue: codec) else { throw Failure("Unknown codec \(codec).") }
            settings.codec = value
        }
        if let quality = args["quality"] as? String {
            guard let value = ExportSettings.Quality(rawValue: quality) else { throw Failure("Unknown quality \(quality).") }
            settings.quality = value
        }
        store.pause()
        do {
            try await Exporter().export(project: store.project, baseURL: store.baseURL, to: url,
                                        settings: settings) { _ in }
        } catch {
            throw Failure("\(error.localizedDescription) (\(url.path)). "
                          + "The sandboxed App Store build can only write to locations the user has chosen. "
                          + "Call export_video without path to let the user pick one.")
        }
        return [.text("Exported \(seconds(store.duration)) to \(url.path).")]
    }

    /// 書き出し先を標準の保存パネルで選んでもらう。キャンセルなら nil。
    private static func chooseExportDestination(_ store: EditorStore) -> URL? {
        NSApp.activate()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        let name = store.project.name.isEmpty ? "movie" : store.project.name
        panel.nameFieldStringValue = "\(name).mp4"
        // 開いたときの場所の提案だけ。どこに置くかはユーザーが決める。
        if let dir = store.baseURL { panel.directoryURL = dir }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    // MARK: - 引数

    private static func string(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }
    private static func number(_ description: String) -> [String: Any] {
        ["type": "number", "description": description]
    }
    private static func integer(_ description: String) -> [String: Any] {
        ["type": "integer", "description": description]
    }
    private static func boolean(_ description: String) -> [String: Any] {
        ["type": "boolean", "description": description]
    }
    private static func array(of items: [String: Any], _ description: String) -> [String: Any] {
        ["type": "array", "items": items, "description": description]
    }

    private static var propsSchema: [String: Any] {
        ["type": "object",
         "description": "Template props by key (see text_templates in get_project). "
             + "Strings for text, \"#RRGGBB\" or \"#RRGGBBAA\" for colors, numbers, booleans, {x, y} for points.",
         "additionalProperties": true]
    }

    private static func tool(_ name: String, _ description: String,
                             _ properties: [String: Any], required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { schema["required"] = required }
        return ["name": name, "description": description, "inputSchema": schema]
    }

    private static func asDouble(_ value: Any) -> Double? {
        // JSONSerialization は true / false も NSNumber で返す。数として読まない。
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }

    private static func number(_ args: [String: Any], _ key: String) throws -> Double {
        guard let v = args[key].flatMap(asDouble), v.isFinite else { throw Failure("\(key) must be a number.") }
        return v
    }

    private static func number(_ args: [String: Any], _ key: String, default value: Double) -> Double {
        args[key].flatMap(asDouble) ?? value
    }

    private static func bool(_ args: [String: Any], _ key: String) -> Bool? {
        guard let n = args[key] as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }

    private static func strings(_ args: [String: Any], _ key: String) throws -> [String] {
        guard let list = args[key] as? [String] else { throw Failure("\(key) must be an array of strings.") }
        return list
    }

    private static func uuid(_ args: [String: Any], _ key: String) throws -> UUID {
        guard let s = args[key] as? String, let id = UUID(uuidString: s) else {
            throw Failure("\(key) must be an ID from get_project.")
        }
        return id
    }

    private static func uuids(_ args: [String: Any], _ key: String) throws -> [UUID] {
        guard let list = try optionalUUIDs(args, key), !list.isEmpty else {
            throw Failure("\(key) must be a non-empty array of IDs.")
        }
        return list
    }

    private static func optionalUUIDs(_ args: [String: Any], _ key: String) throws -> [UUID]? {
        guard let raw = args[key] else { return nil }
        guard let list = raw as? [String] else { throw Failure("\(key) must be an array of IDs.") }
        return try list.map { s in
            guard let id = UUID(uuidString: s) else { throw Failure("\(s) is not an ID.") }
            return id
        }
    }

    private static func track(_ args: [String: Any], _ store: EditorStore, default fallback: Track?) throws -> Track {
        if args["track_id"] != nil {
            let id = try uuid(args, "track_id")
            guard let t = store.project.tracks.first(where: { $0.id == id }) else { throw Failure("No track \(id.uuidString).") }
            return t
        }
        guard let fallback else {
            throw Failure("No unlocked track of that kind is free at that time. Pass track_id, or add one with add_track.")
        }
        return fallback
    }

    /// 指定の区間に何も置かれていない、ロックしていないトラック。並びの先頭から探す。
    private static func freeTrack<S: Sequence>(_ kind: TrackKind, over span: Range<Double>,
                                               in tracks: S) -> Track? where S.Element == Track {
        tracks.first { $0.kind == kind && !$0.isLocked && $0.clips(overlapping: span).isEmpty }
    }

    private static func requireUnlocked(_ track: Track) throws {
        if track.isLocked { throw Failure("Track \"\(track.name)\" is locked.") }
    }

    /// テンプレートの宣言した型に合わせて JSON の値を読む。
    static func propValue(_ raw: Any, key: String, in template: TextTemplate) throws -> PropValue {
        guard let def = template.propDef(for: key) else {
            let keys = template.props.map(\.key).joined(separator: ", ")
            throw Failure("Template \"\(LName(template.name))\" has no prop \"\(key)\". Props: \(keys).")
        }
        switch def.type {
        case .string:
            guard let s = raw as? String else { break }
            return .string(s)
        case .number:
            guard let v = asDouble(raw) else { break }
            return .number(v)
        case .color:
            guard let s = raw as? String, let c = RGBAColor(hex: s) else { break }
            return .color(c)
        case .bool:
            guard let n = raw as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { break }
            return .bool(n.boolValue)
        case .point:
            if let o = raw as? [String: Any], let x = o["x"].flatMap(asDouble), let y = o["y"].flatMap(asDouble) {
                return .point(CGPoint(x: x, y: y))
            }
        }
        throw Failure("Prop \"\(key)\" takes a \(def.type.rawValue).")
    }

    static func jsonValue(_ v: PropValue) -> Any {
        switch v {
        case .string(let s): return s
        case .number(let n): return n
        case .color(let c): return c.hexString
        case .point(let p): return ["x": p.x, "y": p.y]
        case .bool(let b): return b
        }
    }

    private static func seconds(_ t: Double) -> String { String(format: "%.3fs", t) }
}
