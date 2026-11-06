import Foundation

/// Unix-socket IPC, i3-msg style. Request: "<type>\n<payload>"; response: JSON.
public enum IPC {
    public static var socketPath: String { "/tmp/panespace-\(getuid()).sock" }

    private static func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            let bytes = Array(path.utf8.prefix(buf.count - 1))
            buf.copyBytes(from: bytes)
            buf[bytes.count] = 0
        }
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    private static func readAll(_ fd: Int32) -> Data {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        return data
    }

    private static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { return }
                off += n
            }
        }
    }

    /// Returns nil when no daemon is listening.
    public static func send(type: String, payload: String) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard withAddress(socketPath, { connect(fd, $0, $1) }) == 0 else { return nil }
        writeAll(fd, Data("\(type)\n\(payload)".utf8))
        shutdown(fd, SHUT_WR)
        return String(decoding: readAll(fd), as: UTF8.self)
    }

    /// Accepts connections on a background thread; `handler` runs on the main thread.
    /// `offMain` answers first, on the IPC thread, for requests that would block the main thread (nil = not
    /// mine); everything else goes to `handler` on the main thread.
    public static func serve(_ handler: @escaping (_ type: String, _ payload: String) -> String,
                             offMain: ((_ type: String, _ payload: String) -> String?)? = nil) -> Bool {
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, withAddress(socketPath, { bind(fd, $0, $1) }) == 0, listen(fd, 16) == 0 else { return false }
        chmod(socketPath, 0o600)
        let thread = Thread {
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { continue }
                let req = String(decoding: readAll(client), as: UTF8.self)
                let (type, payload) = req.firstIndex(of: "\n").map {
                    (String(req[..<$0]), String(req[req.index(after: $0)...]))
                } ?? (req, "")
                let resp = offMain?(type, payload) ?? DispatchQueue.main.sync { handler(type, payload) }
                writeAll(client, Data(resp.utf8))
                close(client)
            }
        }
        thread.name = "panespace.ipc"
        thread.start()
        return true
    }

    public static func json(_ v: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .sortedKeys]) else { return "null" }
        return String(decoding: d, as: UTF8.self)
    }
}
