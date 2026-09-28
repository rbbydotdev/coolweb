import Foundation

/// Per-origin VM storage. Each origin gets a directory under Application Support and its own file server
/// process (StorageHelper) that the kernel sandbox confines to that directory. Pages reach it at a capability
/// URL, http://127.0.0.1:<port>/fs/<token>/, like a blob: URL. The browser process never serves files itself.
final class StorageServer {
    static let shared = StorageServer()

    private struct Space {
        let origin: String
        let root: URL
        let token: String
        let port: UInt16
        let process: Process
        let stdin: Pipe
    }

    private var spaces: [String: Space] = [:]   // origin -> space
    private let lock = NSLock()

    let storageRoot: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("CoolWeb/VMStorage", isDirectory: true)
    }()

    /// The storage root URL for an origin such as "http://localhost:8123". Starts its server on first use.
    func rootURL(for origin: String) throws -> String {
        let space = try self.space(for: origin)
        return "http://127.0.0.1:\(space.port)/fs/\(space.token)/"
    }

    /// Host directory behind a handle URL, for a VM mount. Only for the caller's own origin. The path is
    /// opened with O_NOFOLLOW_ANY, so the kernel refuses any symlink in it: a VM cannot redirect a mount.
    func directory(forHandleURL url: String, origin: String) -> URL? {
        lock.lock(); let space = spaces[origin]; lock.unlock()
        guard let space, let u = URL(string: url), u.host == "127.0.0.1", u.port == Int(space.port) else { return nil }
        let parts = u.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2, parts[0] == "fs", parts[1] == space.token else { return nil }
        var path = space.root.path
        for raw in parts.dropFirst(2) {
            guard let name = raw.removingPercentEncoding, !name.isEmpty, name != ".", name != "..",
                  !name.contains("/") else { return nil }
            path += "/" + name
        }
        let fd = open(path, O_RDONLY | O_DIRECTORY | Self.noFollowAny)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buf) == 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buf), isDirectory: true)
    }

    func stopAll() {
        lock.lock(); defer { lock.unlock() }
        for s in spaces.values { s.process.terminate() }
        spaces.removeAll()
    }

    /// O_NOFOLLOW_ANY (macOS 11+): fail if any path component is a symlink.
    private static let noFollowAny: Int32 = 0x2000_0000

    private func space(for origin: String) throws -> Space {
        lock.lock(); defer { lock.unlock() }
        if let s = spaces[origin], s.process.isRunning { return s }

        let dir = storageRoot.appendingPathComponent(Self.directoryName(for: origin), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let token = Self.randomToken()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        process.arguments = ["--storage-helper", dir.path, origin, token]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()

        // The helper prints its port once it is listening and sandboxed.
        let line = String(decoding: stdout.fileHandleForReading.availableData, as: UTF8.self)
        guard let port = UInt16(line.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            process.terminate()
            throw NSError(domain: "VMStorage", code: 1, userInfo: [NSLocalizedDescriptionKey: "Storage server did not start."])
        }
        let space = Space(origin: origin, root: dir, token: token, port: port, process: process, stdin: stdin)
        spaces[origin] = space
        return space
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 18)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// "http://localhost:8123" -> "http_localhost_8123"
    private static func directoryName(for origin: String) -> String {
        String(origin.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" })
            .replacingOccurrences(of: "___", with: "_")
    }
}
