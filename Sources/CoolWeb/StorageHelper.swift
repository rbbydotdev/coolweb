import Foundation

@_silgen_name("sandbox_init_with_parameters")
private func sandbox_init_with_parameters(_ profile: UnsafePointer<CChar>, _ flags: UInt64,
                                          _ params: UnsafePointer<UnsafePointer<CChar>?>?,
                                          _ err: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32

/// `CoolWeb --storage-helper <root> <origin> <token>`: one site's file server, in its own process.
///
/// The containment is the kernel, not this code. After opening the root and binding a loopback socket, the
/// process sandboxes itself to that one directory. Every file operation is relative to the root, but nothing
/// here checks where a path leads: a VM-made symlink to "/" or a "../" simply cannot be opened, because the
/// process has no right to anything outside the root. It exits when the browser closes its stdin.
///
///   GET    dir/          JSON [{name, kind, size, lastModified}]; entries that cannot be opened are left out
///   GET    file          bytes
///   HEAD   path          X-Kind: file | directory
///   PUT    dir/          create a directory (parent must exist)
///   PUT    file          replace the file with the body, atomically (parent must exist)
///   DELETE path          remove; a non-empty directory needs ?recursive=1
enum StorageHelper {
    static let profile = """
        (version 1)
        (deny default)
        (allow file-read* file-write* (subpath (param "ROOT")))
        (allow network-bind network-inbound (local ip "localhost:*"))
        (allow sysctl-read)
        """

    static func run(root: String, origin: String, token: String) -> Never {
        let rootfd = open(root, O_RDONLY | O_DIRECTORY)
        guard rootfd >= 0 else { die("Storage \(root) cannot open.") }

        let listener = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, len) == 0 && listen(listener, 64) == 0 && getsockname(listener, $0, &len) == 0
            }
        }
        guard bound else { die("Storage server cannot listen.") }
        let port = UInt16(bigEndian: addr.sin_port)

        // vmfs.js is read before the sandbox closes; afterwards only the root is reachable.
        let library = Bundle.module.url(forResource: "web/vmfs", withExtension: "js").flatMap { try? Data(contentsOf: $0) } ?? Data()

        // Canonical root path: the sandbox matches real paths.
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(rootfd, F_GETPATH, &buf) == 0 else { die("Storage root has no path.") }
        let realRoot = String(cString: buf)
        var err: UnsafeMutablePointer<CChar>?
        let params: [UnsafePointer<CChar>?] = [("ROOT" as NSString).utf8String, (realRoot as NSString).utf8String, nil]
        let rc = params.withUnsafeBufferPointer { sandbox_init_with_parameters(profile, 0, $0.baseAddress, &err) }
        guard rc == 0 else { die("Sandbox cannot start: \(err.map { String(cString: $0) } ?? "unknown")") }

        print(port)
        fflush(stdout)

        // The browser holds our stdin; when it goes away, so do we.
        Thread.detachNewThread {
            var byte: UInt8 = 0
            while read(0, &byte, 1) > 0 {}
            exit(0)
        }

        let server = Server(rootfd: rootfd, origin: origin, token: token, library: library)
        while true {
            let conn = accept(listener, nil, nil)
            if conn < 0 { continue }
            Thread.detachNewThread { server.serve(conn) }
        }
    }

    private static func die(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }

    // MARK: HTTP over one connection

    struct Request {
        var method = "", path = "", query = ""
        var headers: [String: String] = [:]
        var body = Data()
    }

    struct Response {
        var status: Int
        var headers: [String: String] = [:]
        var body = Data()

        static func text(_ status: Int, _ message: String) -> Response {
            Response(status: status, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data(message.utf8))
        }
    }

    final class Server {
        let rootfd: Int32, origin: String, token: String, library: Data

        init(rootfd: Int32, origin: String, token: String, library: Data) {
            self.rootfd = rootfd; self.origin = origin; self.token = token; self.library = library
        }

        func serve(_ conn: Int32) {
            defer { close(conn) }
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 1 << 16)
            while true {
                while let (req, rest) = parse(buffer) {
                    buffer = rest
                    var res = handle(req)
                    res.headers["Content-Length"] = "\(res.body.count)"
                    res.headers["Connection"] = "keep-alive"
                    guard sendAll(conn, serialize(res, head: req.method == "HEAD")) else { return }
                }
                let n = recv(conn, &chunk, chunk.count, 0)
                if n <= 0 { return }
                buffer.append(chunk, count: n)
            }
        }

        private func sendAll(_ conn: Int32, _ data: Data) -> Bool {
            data.withUnsafeBytes { raw in
                var off = 0
                while off < raw.count {
                    let n = send(conn, raw.baseAddress! + off, raw.count - off, 0)
                    if n <= 0 { return false }
                    off += n
                }
                return true
            }
        }

        private func parse(_ buf: Data) -> (Request, Data)? {
            guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
            var lines = String(decoding: buf[buf.startIndex..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let first = lines.removeFirst().split(separator: " ")
            guard first.count >= 2 else { return nil }
            var req = Request()
            req.method = String(first[0])
            let target = String(first[1])
            if let q = target.firstIndex(of: "?") {
                req.path = String(target[..<q]); req.query = String(target[target.index(after: q)...])
            } else {
                req.path = target
            }
            for line in lines {
                guard let c = line.firstIndex(of: ":") else { continue }
                req.headers[line[..<c].lowercased()] = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
            }
            let length = Int(req.headers["content-length"] ?? "0") ?? 0
            guard buf.distance(from: end.upperBound, to: buf.endIndex) >= length else { return nil }
            let bodyEnd = buf.index(end.upperBound, offsetBy: length)
            req.body = Data(buf[end.upperBound..<bodyEnd])
            return (req, Data(buf[bodyEnd...]))
        }

        private func serialize(_ res: Response, head: Bool) -> Data {
            let reason = [200: "OK", 201: "Created", 204: "No Content", 403: "Forbidden", 404: "Not Found",
                          405: "Method Not Allowed", 409: "Conflict", 500: "Internal Server Error"]
            var out = "HTTP/1.1 \(res.status) \(reason[res.status] ?? "Status")\r\n"
            for (k, v) in res.headers { out += "\(k): \(v)\r\n" }
            var data = Data((out + "\r\n").utf8)
            if !head { data.append(res.body) }
            return data
        }

        private func handle(_ req: Request) -> Response {
            if req.path == "/vmfs.js" {
                return Response(status: 200, headers: ["Content-Type": "text/javascript; charset=utf-8",
                                                       "Access-Control-Allow-Origin": "*"], body: library)
            }
            let parts = req.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 2, parts[0] == "fs", parts[1] == token else { return .text(404, "Storage not found.") }
            var res = route(req, names: Array(parts.dropFirst(2)))
            // Only the owning origin may read responses or send PUT / DELETE (they need a CORS preflight).
            res.headers["Access-Control-Allow-Origin"] = origin
            res.headers["Access-Control-Allow-Methods"] = "GET, HEAD, PUT, DELETE"
            res.headers["Access-Control-Allow-Headers"] = "Content-Type"
            res.headers["Access-Control-Expose-Headers"] = "X-Kind, X-Last-Modified, Content-Length"
            res.headers["Vary"] = "Origin"
            res.headers["Cache-Control"] = "no-store"
            return res
        }

        // MARK: Files, all relative to rootfd. No containment checks: the sandbox is the boundary.

        /// errno from a denied or failed call, as an HTTP response.
        private func failure(_ e: Int32 = errno) -> Response {
            switch e {
            case EPERM, EACCES: return .text(403, "Path is outside the storage.")
            case ENOENT, ENOTDIR: return .text(404, "Not found.")
            case EEXIST, ENOTEMPTY, EISDIR: return .text(409, String(cString: strerror(e)))
            default: return .text(500, String(cString: strerror(e)))
            }
        }

        private func route(_ req: Request, names raw: [String]) -> Response {
            if req.method == "OPTIONS" { return Response(status: 204) }
            // Web names, not a security check: "." and ".." are not file names in the handle API.
            var names: [String] = []
            for r in raw {
                guard let n = r.removingPercentEncoding, !n.isEmpty, n != ".", n != "..", !n.contains("/") else {
                    return .text(403, "Path is outside the storage.")
                }
                names.append(n)
            }
            let rel = names.isEmpty ? "." : names.joined(separator: "/")
            let parentRel = names.count > 1 ? names.dropLast().joined(separator: "/") : "."

            switch req.method {
            case "GET", "HEAD":
                var st = stat()
                guard fstatat(rootfd, rel, &st, 0) == 0 else { return failure() }
                let modified = "\(Int(st.st_mtimespec.tv_sec) * 1000 + Int(st.st_mtimespec.tv_nsec) / 1_000_000)"
                if (st.st_mode & S_IFMT) == S_IFDIR { return list(rel, modified: modified) }
                if req.method == "HEAD" {
                    return Response(status: 200, headers: ["X-Kind": "file", "X-Last-Modified": modified,
                                                           "X-Size": "\(st.st_size)"])
                }
                let fd = openat(rootfd, rel, O_RDONLY)
                guard fd >= 0 else { return failure() }
                defer { close(fd) }
                var body = Data(count: Int(st.st_size))
                let n = body.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                guard n >= 0 else { return failure() }
                body.count = n
                return Response(status: 200, headers: ["Content-Type": "application/octet-stream", "X-Kind": "file",
                                                       "X-Last-Modified": modified], body: body)

            case "PUT":
                var pst = stat()
                guard fstatat(rootfd, parentRel, &pst, 0) == 0 else {
                    let e = errno
                    return e == ENOENT || e == ENOTDIR ? .text(409, "Parent directory does not exist.") : failure(e)
                }
                guard (pst.st_mode & S_IFMT) == S_IFDIR else { return .text(409, "Parent is not a directory.") }
                if req.path.hasSuffix("/") {
                    if mkdirat(rootfd, rel, 0o755) == 0 { return Response(status: 201) }
                    let e = errno
                    var st = stat()
                    if e == EEXIST, fstatat(rootfd, rel, &st, 0) == 0, (st.st_mode & S_IFMT) == S_IFDIR { return Response(status: 204) }
                    return failure(e)
                }
                var st = stat()
                if fstatat(rootfd, rel, &st, AT_SYMLINK_NOFOLLOW) == 0, (st.st_mode & S_IFMT) == S_IFDIR {
                    return .text(409, "A directory has that name.")
                }
                // Write a temp file beside the target, then rename over it: readers never see half a file.
                // rename replaces a symlink itself rather than writing through it.
                let tmp = (parentRel == "." ? "" : parentRel + "/") + ".coolweb-\(UUID().uuidString)"
                let fd = openat(rootfd, tmp, O_WRONLY | O_CREAT | O_EXCL, 0o644)
                guard fd >= 0 else { return failure() }
                let ok = req.body.withUnsafeBytes { raw -> Bool in
                    var off = 0
                    while off < raw.count {
                        let n = write(fd, raw.baseAddress! + off, raw.count - off)
                        if n <= 0 { return false }
                        off += n
                    }
                    return true
                }
                close(fd)
                guard ok, renameat(rootfd, tmp, rootfd, rel) == 0 else {
                    let e = errno
                    unlinkat(rootfd, tmp, 0)
                    return failure(e)
                }
                return Response(status: 201)

            case "DELETE":
                guard !names.isEmpty else { return .text(403, "The storage root cannot be removed.") }
                var st = stat()
                guard fstatat(rootfd, rel, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return failure() }
                if (st.st_mode & S_IFMT) != S_IFDIR { return unlinkat(rootfd, rel, 0) == 0 ? Response(status: 204) : failure() }
                if unlinkat(rootfd, rel, AT_REMOVEDIR) == 0 { return Response(status: 204) }
                guard errno == ENOTEMPTY, req.query.contains("recursive=1") else { return failure() }
                return removeTree(rel) ? Response(status: 204) : failure()

            default:
                return .text(405, "Method not allowed.")
            }
        }

        /// Entries that cannot be stat'ed (a link out of the root, a dangling link) are left out.
        private func list(_ rel: String, modified: String) -> Response {
            let dfd = openat(rootfd, rel, O_RDONLY | O_DIRECTORY)
            guard dfd >= 0, let dir = fdopendir(dfd) else { return failure() }
            defer { closedir(dir) }
            var entries: [[String: Any]] = []
            while let ent = readdir(dir) {
                let name = withUnsafeBytes(of: ent.pointee.d_name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
                if name == "." || name == ".." || name.hasPrefix(".coolweb-") { continue }
                var st = stat()
                guard fstatat(dirfd(dir), name, &st, 0) == 0 else { continue }
                let isDir = (st.st_mode & S_IFMT) == S_IFDIR
                entries.append(["name": name, "kind": isDir ? "directory" : "file", "size": Int(st.st_size),
                                "lastModified": Int(st.st_mtimespec.tv_sec) * 1000 + Int(st.st_mtimespec.tv_nsec) / 1_000_000])
            }
            entries.sort { ($0["name"] as! String) < ($1["name"] as! String) }
            let body = (try? JSONSerialization.data(withJSONObject: entries)) ?? Data("[]".utf8)
            return Response(status: 200, headers: ["Content-Type": "application/json", "X-Kind": "directory",
                                                   "X-Last-Modified": modified], body: body)
        }

        /// Deletes a tree without following links: a link is removed, never its target.
        private func removeTree(_ rel: String) -> Bool {
            let dfd = openat(rootfd, rel, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard dfd >= 0, let dir = fdopendir(dfd) else { return false }
            var names: [String] = []
            while let ent = readdir(dir) {
                let name = withUnsafeBytes(of: ent.pointee.d_name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
                if name != "." && name != ".." { names.append(name) }
            }
            closedir(dir)
            for name in names {
                let child = rel + "/" + name
                var st = stat()
                guard fstatat(rootfd, child, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return false }
                if (st.st_mode & S_IFMT) == S_IFDIR {
                    guard removeTree(child) else { return false }
                } else if unlinkat(rootfd, child, 0) != 0 {
                    return false
                }
            }
            return unlinkat(rootfd, rel, AT_REMOVEDIR) == 0
        }
    }
}
