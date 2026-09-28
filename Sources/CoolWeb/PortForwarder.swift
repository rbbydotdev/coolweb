import Foundation
import Virtualization

/// Serves one guest TCP port on 127.0.0.1:<hostPort>. Each accepted connection gets its own vsock connection
/// into the guest, where socat bridges it to the server. Bytes are copied both ways untouched, so HTTP,
/// keep-alive, WebSockets and HMR all work.
final class PortForwarder {
    let hostPort: UInt16
    private let listener: Int32
    private let vsockPort: UInt32
    private weak var device: VZVirtioSocketDevice?
    private var closed = false

    init(device: VZVirtioSocketDevice, vsockPort: UInt32) throws {
        self.device = device
        self.vsockPort = vsockPort
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, len) == 0 && listen(fd, 128) == 0 && getsockname(fd, $0, &len) == 0
            }
        }
        guard ok else {
            close(fd)
            throw NSError(domain: "VMWorker", code: 2, userInfo: [NSLocalizedDescriptionKey: "Port cannot open on the host."])
        }
        listener = fd
        hostPort = UInt16(bigEndian: addr.sin_port)
        Thread.detachNewThread { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { return }  // listener closed
                self?.bridge(client) ?? { close(client) }()
            }
        }
    }

    func stop() {
        guard !closed else { return }
        closed = true
        shutdown(listener, SHUT_RDWR)
        close(listener)
    }

    /// The guest listener may lag the "listening" report by a moment; retry the vsock connect briefly.
    private func bridge(_ client: Int32, attempt: Int = 0) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.closed, let device = self.device else { close(client); return }
            device.connect(toPort: self.vsockPort) { result in
                switch result {
                case .success(let conn):
                    Self.splice(client, conn)
                case .failure:
                    if attempt < 20 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.bridge(client, attempt: attempt + 1) }
                    } else {
                        close(client)
                    }
                }
            }
        }
    }

    /// Copies both directions on two threads. EOF on one side half-closes the other, so request/response
    /// protocols finish cleanly; both ends close when both directions are done.
    private static func splice(_ client: Int32, _ conn: VZVirtioSocketConnection) {
        let guest = conn.fileDescriptor
        let group = DispatchGroup()
        for (label, from, to) in [("client->guest", client, guest), ("guest->client", guest, client)] {
            group.enter()
            Thread.detachNewThread {
                var buf = [UInt8](repeating: 0, count: 1 << 16)
                var total = 0
                defer {
                    if ProcessInfo.processInfo.environment["COOLWEB_TRACE_PORTS"] != nil {
                        trace("[splice] \(label) \(total) bytes, stopped errno=\(errno)")
                    }
                }
                copy: while true {
                    let n = read(from, &buf, buf.count)
                    if n <= 0 { break }
                    total += n
                    // Write through a pointer into the buffer. (&buf[off] would pass a one-byte temporary.)
                    let ok = buf.withUnsafeBytes { raw -> Bool in
                        var off = 0
                        while off < n {
                            let w = write(to, raw.baseAddress! + off, n - off)
                            if w <= 0 { return false }
                            off += w
                        }
                        return true
                    }
                    if !ok { break copy }
                }
                shutdown(to, SHUT_WR)
                group.leave()
            }
        }
        group.notify(queue: .global()) {
            close(client)
            conn.close()
        }
    }
}
