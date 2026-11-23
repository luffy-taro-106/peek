import Foundation
import Network

/// A parsed HTTP/1.1 request (only what the hook script sends).
struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]   // lower-cased names
    let body: Data
}

/// Holds one open connection so a reply can be sent later (permission gates
/// stay open until the user decides in the notch).
final class HTTPResponder: @unchecked Sendable {
    private let connection: NWConnection
    private let lock = NSLock()
    private var finished = false
    /// Called once if the client goes away before we answered
    /// (Claude cancelled the call, or the user answered in Claude itself).
    var onDisconnect: (() -> Void)?

    init(connection: NWConnection) { self.connection = connection }

    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }

    func send(json: Data, status: Int = 200) {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        lock.unlock()
        let reason = status == 200 ? "OK" : (status == 404 ? "Not Found" : "Error")
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(json.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(json)
        connection.send(content: out, completion: .contentProcessed { [connection] _ in
            connection.cancel()
        })
    }

    func send(object: Any, status: Int = 200) {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        send(json: data, status: status)
    }

    fileprivate func peerClosed() {
        lock.lock()
        let wasFinished = finished
        finished = true
        lock.unlock()
        if !wasFinished { onDisconnect?() }
        connection.cancel()
    }
}

/// Loopback-only HTTP server. Claude Code hooks POST to /hook/<Event>.
final class HookServer: @unchecked Sendable {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "peek.hook-server")
    private(set) var port: UInt16 = 0
    /// Loopback only (Claude hooks). The iPhone link sets this to false.
    var localOnly = true
    /// Where the chosen port is recorded for the hook script (nil = don't record).
    var recordPortTo: URL? = HookServer.portFile
    var onRequest: ((HTTPRequest, HTTPResponder) -> Void)?
    var onStateChange: ((String) -> Void)?

    static let portFile: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/peek", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("port")
    }()

    /// Tries 8799…8809 so a busy port never stops the app.
    func start(preferred: UInt16 = 8799, tries: UInt16 = 10) {
        for candidate in preferred...(preferred + tries) {
            if tryStart(port: candidate) { return }
        }
        onStateChange?("Could not open a port (\(preferred)–\(preferred + tries) busy)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = 0
    }

    private func tryStart(port candidate: UInt16) -> Bool {
        let params = NWParameters.tcp
        params.acceptLocalOnly = localOnly
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: candidate),
              let l = try? NWListener(using: params, on: nwPort) else { return false }

        let sem = DispatchSemaphore(value: 0)
        var ok = false
        l.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                ok = true; sem.signal()
                self?.onStateChange?("Listening on 127.0.0.1:\(candidate)")
            case .failed(let err):
                sem.signal()
                self?.onStateChange?("Server failed: \(err.localizedDescription)")
            case .cancelled:
                sem.signal()
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        l.start(queue: queue)
        _ = sem.wait(timeout: .now() + 2)
        if ok {
            listener = l
            port = candidate
            if let file = recordPortTo {
                try? "http://127.0.0.1:\(candidate)\n".write(to: file, atomically: true, encoding: .utf8)
            }
            return true
        }
        l.cancel()
        return false
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let req = Self.parse(buf) {
                let responder = HTTPResponder(connection: conn)
                self.watchForClose(conn, responder: responder)
                self.onRequest?(req, responder)
                return
            }
            if isComplete || error != nil || buf.count > 8 << 20 {
                conn.cancel()
                return
            }
            self.receive(conn, buffer: buf)
        }
    }

    /// Keeps a read pending so we notice when curl is killed (Claude moved on).
    private func watchForClose(_ conn: NWConnection, responder: HTTPResponder) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            if isComplete || error != nil {
                responder.peerClosed()
            } else if !responder.isFinished {
                _ = data
                self?.watchForClose(conn, responder: responder)
            }
        }
    }

    private static func parse(_ buf: Data) -> HTTPRequest? {
        let sep = Data("\r\n\r\n".utf8)
        guard let range = buf.range(of: sep) else { return nil }
        guard let head = String(data: buf[buf.startIndex..<range.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let idx = line.firstIndex(of: ":") else { continue }
            let name = line[..<idx].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = range.upperBound
        guard buf.count - bodyStart >= length else { return nil }
        let body = buf[bodyStart..<(bodyStart + length)]
        return HTTPRequest(method: String(first[0]), path: String(first[1]), headers: headers, body: Data(body))
    }
}
