import Foundation

/// MCP の JSON-RPC を受け答えする部分。HTTP からは切り離してあり、
/// 1 通の本文を受けて、返す本文（と HTTP の状態）を作るだけ。
///
/// 返事は SSE ではなく application/json 1 通で返す（Streamable HTTP で許されている
/// 形）。サーバから先に話しかけることは無いので、セッションも持たない。
@MainActor
enum MCPProtocol {

    struct Reply {
        var status: Int
        /// nil なら本文なし（通知を受けたときの 202）。
        var body: Data?
    }

    /// 対応している版。相手の言う版がこの中にあればそれで、無ければ先頭で答える。
    static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    static func handle(_ body: Data, store: EditorStore?) async -> Reply {
        guard let message = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return Reply(status: 400, body: error(id: NSNull(), code: -32700, "Parse error"))
        }
        // 通知と、こちらが出していない要求への返事。受け取るだけ。
        guard let method = message["method"] as? String, let id = message["id"] else {
            return Reply(status: 202, body: nil)
        }
        let params = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String
            let version = asked.flatMap { supportedVersions.contains($0) ? $0 : nil } ?? supportedVersions[0]
            return ok(id: id, [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "nanovid", "title": "Nanovid", "version": appVersion],
                "instructions": instructions,
            ])
        case "ping":
            return ok(id: id, [:])
        case "tools/list":
            return ok(id: id, ["tools": MCPTools.definitions])
        case "tools/call":
            guard let name = params["name"] as? String else {
                return Reply(status: 200, body: error(id: id, code: -32602, "Missing tool name"))
            }
            guard let store else {
                return ok(id: id, toolError("No project window is open in Nanovid."))
            }
            let args = params["arguments"] as? [String: Any] ?? [:]
            do {
                let content = try await MCPTools.call(name, args, store: store)
                return ok(id: id, ["content": content.map(\.payload), "isError": false])
            } catch let failure as MCPTools.Failure {
                return ok(id: id, toolError(failure.message))
            } catch {
                return ok(id: id, toolError(error.localizedDescription))
            }
        default:
            return Reply(status: 200, body: Self.error(id: id, code: -32601, "Method not found: \(method)"))
        }
    }

    private static let instructions = """
        Nanovid is a Mac video editor. These tools edit the project that is open in the app \
        right now; every change shows up on screen immediately and the user can undo it with ⌘Z. \
        Start with get_project to learn the track, clip, asset and template IDs. Times are in seconds \
        and snap to frame boundaries. Use render_frame to look at the result.
        """

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private static func toolError(_ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "isError": true]
    }

    private static func ok(id: Any, _ result: [String: Any]) -> Reply {
        Reply(status: 200, body: MCPJSON.data(["jsonrpc": "2.0", "id": id, "result": result]))
    }

    private static func error(id: Any, code: Int, _ message: String) -> Data {
        MCPJSON.data(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }
}

enum MCPJSON {
    static func data(_ value: Any, pretty: Bool = false) -> Data {
        var options: JSONSerialization.WritingOptions = [.withoutEscapingSlashes, .sortedKeys]
        if pretty { options.insert(.prettyPrinted) }
        return (try? JSONSerialization.data(withJSONObject: value, options: options)) ?? Data("null".utf8)
    }

    static func string(_ value: Any, pretty: Bool = false) -> String {
        String(decoding: data(value, pretty: pretty), as: UTF8.self)
    }
}
