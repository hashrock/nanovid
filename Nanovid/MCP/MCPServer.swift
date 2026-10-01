import Foundation
import Network

/// AI から起動中の nanovid を操作するための MCP サーバ（Streamable HTTP）。
///
/// 127.0.0.1 だけで待ち受け、外の機械からは届かない。既定では止めてあり、
/// アプリのメニューから入れる。受け答えの中身は MCPProtocol、道具は MCPTools。
///
/// HTTP は MCP に要るぶんだけを自前で読む。1 回の接続で 1 往復して閉じる。
final class MCPServer {

    static let shared = MCPServer()

    /// メニューの入切を覚えておく先（UserDefaults）。
    static let enabledKey = "mcpServerEnabled"
    static let port: UInt16 = 47_231
    static var endpoint: String { "http://127.0.0.1:\(port)/mcp" }

    /// 窓が出たときに渡される。道具はこの store を編集する。
    @MainActor weak var store: EditorStore?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "nanovid.mcp")
    /// 本文の上限。素材のパスやテキストを送るだけなので、これで十分。
    private let maxRequestSize = 4 << 20

    var isRunning: Bool { listener != nil }

    /// 待ち受けを始める。ポートが塞がっているなどで失敗したら onFailure（main で呼ぶ）。
    @MainActor
    func start(onFailure: @escaping (String) -> Void) {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback),
                                                     port: NWEndpoint.Port(rawValue: Self.port)!)
        do {
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { [weak self] state in
                guard case .failed(let error) = state else { return }
                DispatchQueue.main.async {
                    self?.stop()
                    onFailure(error.localizedDescription)
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            onFailure(error.localizedDescription)
        }
    }

    @MainActor
    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - 接続

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { [weak self] data, _, done, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPRequest.parse(buffer, limit: self.maxRequestSize) {
            case .complete(let request):
                self.respond(to: request, on: connection)
            case .tooLarge:
                self.send(HTTPResponse(status: 413), on: connection)
            case .malformed:
                self.send(HTTPResponse(status: 400), on: connection)
            case .incomplete:
                if done || error != nil { return connection.cancel() }
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func respond(to request: HTTPRequest, on connection: NWConnection) {
        guard request.path == "/mcp" || request.path == "/" else {
            return send(HTTPResponse(status: 404), on: connection)
        }
        // ブラウザのページから 127.0.0.1 を突かれる（DNS rebinding など）のを防ぐ。
        // Origin を付けてくるのはブラウザだけなので、付いていたら手元のものしか通さない。
        if let origin = request.headers["origin"], !Self.isLocalOrigin(origin) {
            return send(HTTPResponse(status: 403), on: connection)
        }
        guard request.method == "POST" else {
            // サーバから話しかける SSE の口は持たない。
            return send(HTTPResponse(status: 405, headers: ["Allow": "POST"]), on: connection)
        }
        let body = request.body
        Task { @MainActor in
            let reply = await MCPProtocol.handle(body, store: self.store)
            var response = HTTPResponse(status: reply.status)
            if let data = reply.body {
                response.headers["Content-Type"] = "application/json"
                response.body = data
            }
            self.send(response, on: connection)
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialized, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    static func isLocalOrigin(_ origin: String) -> Bool {
        guard let host = URL(string: origin)?.host?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    }
}

// MARK: - HTTP

struct HTTPRequest {
    var method: String
    var path: String
    /// 名前は小文字にそろえる。
    var headers: [String: String]
    var body: Data

    enum Parse {
        case complete(HTTPRequest)
        case incomplete
        case tooLarge
        case malformed
    }

    static func parse(_ data: Data, limit: Int) -> Parse {
        let separator = Data("\r\n\r\n".utf8)
        guard let end = data.range(of: separator) else {
            return data.count > 64 << 10 ? .tooLarge : .incomplete
        }
        guard let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else {
            return .malformed
        }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count >= 2 else { return .malformed }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { return .malformed }
        guard length <= limit else { return .tooLarge }
        let bodyStart = end.upperBound
        guard data.count - (bodyStart - data.startIndex) >= length else { return .incomplete }

        let target = String(requestLine[1])
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
        return .complete(HTTPRequest(method: String(requestLine[0]).uppercased(), path: path,
                                     headers: headers,
                                     body: data.subdata(in: bodyStart..<(bodyStart + length))))
    }
}

struct HTTPResponse {
    var status: Int
    var headers: [String: String] = [:]
    var body = Data()

    var serialized: Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        var all = headers
        all["Content-Length"] = String(body.count)
        all["Connection"] = "close"
        for (name, value) in all.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + body
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        default: return "Status"
        }
    }
}
