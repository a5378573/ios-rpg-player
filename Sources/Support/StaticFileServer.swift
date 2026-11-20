import Foundation
import Network

/// 极简本地静态文件服务器。MV/MZ 通过 XMLHttpRequest 读取 data/*.json，
/// file:// 会被 CORS 拦住，所以用 127.0.0.1 上的 HTTP 服务承载。
final class StaticFileServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.local.rpgplayer.httpserver", qos: .userInitiated)
    private let root: URL
    private(set) var port: UInt16 = 0

    init(root: URL) {
        self.root = root.standardizedFileURL
    }

    func start(timeout: TimeInterval = 5) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.allowLocalEndpointReuse = true

        let listener = try NWListener(using: parameters)
        let semaphore = DispatchSemaphore(value: 0)
        var startError: Error?

        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let raw = listener.port?.rawValue {
                    self?.port = raw
                }
                semaphore.signal()
            case .failed(let error):
                startError = error
                semaphore.signal()
            case .cancelled:
                semaphore.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
        self.listener = listener

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            listener.cancel()
            throw NSError(domain: "StaticFileServer", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "本地服务启动超时"])
        }
        if let error = startError {
            listener.cancel()
            throw error
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = 0
    }

    var baseURL: URL? {
        guard port != 0 else { return nil }
        return URL(string: "http://127.0.0.1:\(port)/")
    }

    // MARK: - 连接处理

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var accumulated = buffer
            if let data { accumulated.append(data) }

            if let headerRange = accumulated.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = accumulated.subdata(in: 0..<headerRange.lowerBound)
                self.respond(on: connection, headerData: headerData)
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(connection, buffer: accumulated)
        }
    }

    private func respond(on connection: NWConnection, headerData: Data) {
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            send(connection, status: "400 Bad Request", contentType: "text/plain", body: Data())
            return
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            send(connection, status: "400 Bad Request", contentType: "text/plain", body: Data())
            return
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            send(connection, status: "400 Bad Request", contentType: "text/plain", body: Data())
            return
        }
        let rawPath = String(parts[1])
        let path = rawPath.split(separator: "?").first.map(String.init) ?? rawPath

        let rangeHeader = lines.first { $0.lowercased().hasPrefix("range:") }
            .map { $0.dropFirst("range:".count).trimmingCharacters(in: .whitespaces) }

        let target = resolve(path: path)
        guard let fileURL = target,
              FileManager.default.fileExists(atPath: fileURL.path),
              !isDirectory(fileURL) else {
            send(connection, status: "404 Not Found", contentType: "text/plain", body: Data("Not Found".utf8))
            return
        }

        guard let data = try? Data(contentsOf: fileURL) else {
            send(connection, status: "500 Internal Server Error", contentType: "text/plain", body: Data())
            return
        }

        let mime = Self.mimeType(for: fileURL.pathExtension)
        if let rangeHeader, let range = Self.parseRange(rangeHeader, total: data.count) {
            let chunk = data.subdata(in: range)
            let head = """
            HTTP/1.1 206 Partial Content\r
            Content-Type: \(mime)\r
            Content-Length: \(chunk.count)\r
            Content-Range: bytes \(range.lowerBound)-\(range.upperBound - 1)/\(data.count)\r
            Accept-Ranges: bytes\r
            Access-Control-Allow-Origin: *\r
            Cache-Control: no-cache\r
            Connection: close\r
            \r\n
            """
            send(connection, raw: Data(head.utf8) + chunk)
        } else {
            let head = """
            HTTP/1.1 200 OK\r
            Content-Type: \(mime)\r
            Content-Length: \(data.count)\r
            Accept-Ranges: bytes\r
            Access-Control-Allow-Origin: *\r
            Cache-Control: no-cache\r
            Connection: close\r
            \r\n
            """
            send(connection, raw: Data(head.utf8) + data)
        }
    }

    private func resolve(path: String) -> URL? {
        var cleaned = path
        if cleaned.hasPrefix("/") { cleaned.removeFirst() }
        cleaned = cleaned.removingPercentEncoding ?? cleaned
        if cleaned.isEmpty { cleaned = "index.html" }

        let candidate = root.appendingPathComponent(cleaned).standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(rootPath) else { return nil }
        return candidate
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return isDir.boolValue
    }

    private func send(_ connection: NWConnection, status: String, contentType: String, body: Data) {
        let head = """
        HTTP/1.1 \(status)\r
        Content-Type: \(contentType)\r
        Content-Length: \(body.count)\r
        Access-Control-Allow-Origin: *\r
        Connection: close\r
        \r\n
        """
        send(connection, raw: Data(head.utf8) + body)
    }

    private func send(_ connection: NWConnection, raw: Data) {
        connection.send(content: raw, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - 工具

    private static func parseRange(_ header: String, total: Int) -> Range<Int>? {
        guard header.lowercased().hasPrefix("bytes=") else { return nil }
        let spec = header.dropFirst("bytes=".count)
        let pieces = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count == 2 else { return nil }
        let startText = pieces[0].trimmingCharacters(in: .whitespaces)
        let endText = pieces[1].trimmingCharacters(in: .whitespaces)
        if startText.isEmpty, let suffix = Int(endText) {
            let lower = max(0, total - suffix)
            return lower..<total
        }
        guard let start = Int(startText) else { return nil }
        let end = Int(endText) ?? (total - 1)
        guard start <= end, start < total else { return nil }
        return start..<min(end + 1, total)
    }

    static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs": return "application/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "ogg", "oga": return "audio/ogg"
        case "m4a": return "audio/mp4"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "mp4", "m4v": return "video/mp4"
        case "webm": return "video/webm"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "wasm": return "application/wasm"
        default: return "application/octet-stream"
        }
    }
}
