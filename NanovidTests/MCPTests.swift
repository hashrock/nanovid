// App Store 用ビルドには入れない（README「App Store 用ビルドと MCP」）。
#if !APPSTORE
import Testing
import Foundation
@testable import Nanovid

/// MCP の受け答えと道具。HTTP は通さず、本文を直に渡して確かめる。
@MainActor
struct MCPTests {

    private func send(_ message: [String: Any], store: EditorStore?) async -> MCPProtocol.Reply {
        await MCPProtocol.handle(MCPJSON.data(message), store: store)
    }

    private func result(_ reply: MCPProtocol.Reply) throws -> [String: Any] {
        let body = try #require(reply.body)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        return try #require(object["result"] as? [String: Any])
    }

    /// tools/call を呼んで、結果の最初の文字列と isError を返す。
    private func call(_ name: String, _ args: [String: Any] = [:],
                      store: EditorStore) async throws -> (text: String, isError: Bool) {
        let reply = await send(["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                "params": ["name": name, "arguments": args]], store: store)
        let r = try result(reply)
        let content = try #require(r["content"] as? [[String: Any]])
        let text = content.compactMap { $0["text"] as? String }.first ?? ""
        return (text, r["isError"] as? Bool ?? false)
    }

    private func json(_ text: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    // MARK: - 受け答え

    @Test("initialize は相手の版で答え、知らない版には最新で答える")
    func initializeNegotiatesVersion() async throws {
        let known = try result(await send(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                           "params": ["protocolVersion": "2025-03-26"]], store: nil))
        #expect(known["protocolVersion"] as? String == "2025-03-26")
        #expect((known["capabilities"] as? [String: Any])?["tools"] != nil)

        let unknown = try result(await send(["jsonrpc": "2.0", "id": 2, "method": "initialize",
                                             "params": ["protocolVersion": "1999-01-01"]], store: nil))
        #expect(unknown["protocolVersion"] as? String == MCPProtocol.supportedVersions[0])
    }

    @Test("通知には本文なしの 202、壊れた本文には 400")
    func notificationsAndParseErrors() async {
        let note = await send(["jsonrpc": "2.0", "method": "notifications/initialized"], store: nil)
        #expect(note.status == 202)
        #expect(note.body == nil)

        let broken = await MCPProtocol.handle(Data("{".utf8), store: nil)
        #expect(broken.status == 400)
    }

    @Test("知らないメソッドは -32601")
    func unknownMethod() async throws {
        let reply = await send(["jsonrpc": "2.0", "id": 7, "method": "resources/list"], store: nil)
        let body = try #require(reply.body)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect((object["error"] as? [String: Any])?["code"] as? Int == -32601)
        #expect(object["id"] as? Int == 7)
    }

    @Test("tools/list の道具はどれも名前と入力の型を持ち、名前が重ならない")
    func toolDefinitionsAreWellFormed() async throws {
        let r = try result(await send(["jsonrpc": "2.0", "id": 1, "method": "tools/list"], store: nil))
        let tools = try #require(r["tools"] as? [[String: Any]])
        let names = tools.compactMap { $0["name"] as? String }
        #expect(names.count == tools.count)
        #expect(Set(names).count == names.count)
        for tool in tools {
            #expect((tool["inputSchema"] as? [String: Any])?["type"] as? String == "object")
        }
    }

    // MARK: - 道具

    @Test("テキストを置くと props が入り、1 回の undo で消える")
    func addTextClipWithProps() async throws {
        let store = EditorStore()
        let title = try #require(store.project.textTemplates.first { $0.props.contains { $0.key == "title" } })
        let added = try await call("add_text_clip", ["start": 1, "duration": 2,
                                                     "template_id": title.id.uuidString,
                                                     "props": ["title": "見出し", "titleColor": "#FFCC00"]],
                                   store: store)
        #expect(!added.isError)
        let id = try #require(UUID(uuidString: try json(added.text)["clip_id"] as? String ?? ""))
        let inst = try #require(store.project.clip(id)?.content.textInstance)
        #expect(inst.props["title"] == .string("見出し"))
        #expect(inst.props["titleColor"] == .color(RGBAColor(hex: "#FFCC00")!))

        store.undo()
        #expect(store.project.clip(id) == nil)
    }

    @Test("置き先を言わなければ、その時間に空いているトラックへ置く")
    func defaultsToAFreeTrack() async throws {
        let store = EditorStore()
        let first = try await call("add_text_clip", ["start": 0, "duration": 3], store: store)
        let second = try await call("add_text_clip", ["start": 1, "duration": 3], store: store)
        let a = try #require(UUID(uuidString: try json(first.text)["clip_id"] as? String ?? ""))
        let b = try #require(UUID(uuidString: try json(second.text)["clip_id"] as? String ?? ""))
        #expect(store.project.track(containing: a)?.id != store.project.track(containing: b)?.id,
                "重なる時間のクリップを同じトラックに積んではいけない")
    }

    @Test("テンプレートに無い props や型の違う値は弾き、何も変えない")
    func rejectsBadProps() async throws {
        let store = EditorStore()
        let added = try await call("add_text_clip", ["start": 0], store: store)
        let id = try json(added.text)["clip_id"] as? String ?? ""
        let before = store.project

        let unknownKey = try await call("set_text_props", ["clip_ids": [id], "props": ["nope": "x"]], store: store)
        #expect(unknownKey.isError)
        let wrongType = try await call("set_text_props", ["clip_ids": [id], "props": ["textColor": 3]], store: store)
        #expect(wrongType.isError)
        #expect(store.project == before)
    }

    @Test("時刻を指定して切ると、右側の新しいクリップが返る")
    func splitAtTime() async throws {
        let store = EditorStore()
        let added = try await call("add_text_clip", ["start": 0, "duration": 4], store: store)
        let id = try json(added.text)["clip_id"] as? String ?? ""
        let split = try await call("split_clips", ["time": 1.5, "clip_ids": [id]], store: store)
        #expect(!split.isError)
        let right = try #require((try json(split.text)["new_clip_ids"] as? [String])?.first)
        #expect(store.project.clip(UUID(uuidString: right)!)?.start == 1.5)
        #expect(store.project.clip(UUID(uuidString: id)!)?.duration == 1.5)

        let nothing = try await call("split_clips", ["time": 30], store: store)
        #expect(nothing.isError, "何も切れなかったら知らせる")
    }

    @Test("知らない道具や足りない引数はエラーとして返す（例外にしない）")
    func toolErrorsAreResults() async throws {
        let store = EditorStore()
        #expect(try await call("nope", store: store).isError)
        #expect(try await call("move_clip", ["start": 1], store: store).isError)
        #expect(try await call("undo", store: store).isError, "取り消すものが無い")
    }

    @Test("真偽値を数として読まない")
    func booleansAreNotNumbers() async throws {
        let store = EditorStore()
        #expect(try await call("seek", ["time": true], store: store).isError)
    }

    // MARK: - HTTP

    @Test("HTTP の要求は本文が揃うまで待つ")
    func httpParsingWaitsForBody() throws {
        let head = "POST /mcp?x=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 4\r\nOrigin: http://localhost\r\n\r\n"
        guard case .incomplete = HTTPRequest.parse(Data((head + "ab").utf8), limit: 1024) else {
            Issue.record("本文が足りないのに読み終えた"); return
        }
        guard case .complete(let request) = HTTPRequest.parse(Data((head + "abcd").utf8), limit: 1024) else {
            Issue.record("揃っているのに読めなかった"); return
        }
        #expect(request.method == "POST")
        #expect(request.path == "/mcp")
        #expect(request.headers["origin"] == "http://localhost")
        #expect(request.body == Data("abcd".utf8))

        guard case .tooLarge = HTTPRequest.parse(Data(head.utf8), limit: 2) else {
            Issue.record("上限を超えたのに通した"); return
        }
    }

    @Test("手元以外の Origin は通さない")
    func originCheck() {
        #expect(MCPServer.isLocalOrigin("http://localhost:3000"))
        #expect(MCPServer.isLocalOrigin("http://127.0.0.1"))
        #expect(MCPServer.isLocalOrigin("http://[::1]:8080"))
        #expect(!MCPServer.isLocalOrigin("https://example.com"))
        #expect(!MCPServer.isLocalOrigin("http://localhost.example.com"))
        #expect(!MCPServer.isLocalOrigin("null"))
    }
}

/// MCP から録音を書き出す。
@MainActor
struct MCPRecordingExportTests {

    private func call(_ name: String, _ args: [String: Any] = [:],
                      store: EditorStore) async throws -> (text: String, isError: Bool) {
        let message: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                      "params": ["name": name, "arguments": args]]
        let reply = await MCPProtocol.handle(MCPJSON.data(message), store: store)
        let body = try #require(reply.body)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let r = try #require(object["result"] as? [String: Any])
        let content = try #require(r["content"] as? [[String: Any]])
        return (content.compactMap { $0["text"] as? String }.first ?? "", r["isError"] as? Bool ?? false)
    }

    private func json(_ text: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    @Test("get_project は録音に印を付け、export_recordings はフォルダへ写す")
    func exportsRecordings() async throws {
        let dir = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("nanovid-mcp-rec-\(UUID().uuidString)")
        let out = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let package = dir.appendingPathComponent("movie.nanovid")
        try ProjectIO.save(Project.starter(), to: package)
        let recording = ProjectIO.recordingsDirectory(in: package).appendingPathComponent("rec-20261110-100000.wav")
        try FileManager.default.createDirectory(at: recording.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("録音".utf8).write(to: recording)
        let bgm = dir.appendingPathComponent("bgm.mp3")
        try Data("BGM".utf8).write(to: bgm)
        var project = Project.starter()
        project.assets = [recording, bgm].map {
            MediaAsset(path: $0.path, displayName: $0.lastPathComponent, kind: .audio,
                       duration: 1, naturalSize: nil, hasAudio: true, hasVideo: false)
        }
        try ProjectIO.save(project, to: package, previous: package)
        let store = EditorStore()
        store.open(url: package)

        let summary = try json(try await call("get_project", store: store).text)
        let assets = try #require(summary["assets"] as? [[String: Any]])
        #expect(assets.map { $0["recording"] as? Bool } == [true, false])

        let done = try await call("export_recordings", ["folder": out.path], store: store)
        #expect(!done.isError)
        let exported = try #require(try json(done.text)["exported"] as? [String])
        #expect(exported == [out.appendingPathComponent("rec-20261110-100000.wav").path])
        #expect(try String(contentsOfFile: exported[0], encoding: .utf8) == "録音")

        // 録音でない素材は断る。
        let wrong = try await call("export_recordings",
                                   ["asset_ids": [project.assets[1].id.uuidString], "folder": out.path],
                                   store: store)
        #expect(wrong.isError)
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).count == 1)
    }

    @Test("録音が無いプロジェクトでは、パネルを出さずに断る")
    func refusesWhenThereAreNoRecordings() async throws {
        let store = EditorStore()
        let result = try await call("export_recordings", store: store)
        #expect(result.isError)
        #expect(result.text.contains("no recordings"))
    }
}
#endif
