import Foundation
import Virtualization

/// One Linux VM running one worker script. See guest/overlay/init for the port layout.
/// Unbuffered trace line (stdout is block-buffered when redirected, and lost if the process is killed).
func trace(_ line: String) { FileHandle.standardError.write(Data((line + "\n").utf8)) }

final class Box: NSObject, VZVirtualMachineDelegate, VZVirtioSocketListenerDelegate {
    enum Serialization: String {
        /// u32 big-endian length + one CBOR item per message.
        case advanced
        /// One JSON value per line.
        case json
    }

    struct Options {
        var cpus = 2
        var memoryMB: UInt64 = 512
        var network = true
        var serialization = Serialization.advanced
        /// Host directories shared into the guest with virtiofs, mounted before the script starts.
        var mounts: [(guestPath: String, hostDirectory: URL)] = []
    }

    /// Largest message accepted from the guest. A bad length prefix otherwise looks like a huge message.
    static let maxFrame = 256 * 1024 * 1024

    let id: String
    let options: Options
    private(set) var state = "starting"

    /// All callbacks run on the main queue.
    var onMessage: ((Data) -> Void)?
    var onMessageError: ((String) -> Void)?
    var onConsole: ((String) -> Void)?
    var onExit: ((_ code: Int?, _ error: Error?) -> Void)?

    private final class Port {
        let toGuest = Pipe(), fromGuest = Pipe()
        /// Bytes received but not yet a whole line or frame.
        var buffer = Data()

        /// Complete lines; a partial line waits for the next chunk. Strips a trailing CR.
        func lines(_ data: Data) -> [Data] {
            buffer.append(data)
            var out: [Data] = []
            while let nl = buffer.firstIndex(of: 0x0A) {
                var end = nl
                if end > buffer.startIndex, buffer[buffer.index(before: end)] == 0x0D { end = buffer.index(before: end) }
                out.append(Data(buffer[buffer.startIndex..<end]))
                buffer.removeSubrange(buffer.startIndex...nl)
            }
            return out
        }

        /// Complete length-prefixed frames. Throws on a length over the limit.
        func frames(_ data: Data) throws -> [Data] {
            buffer.append(data)
            var out: [Data] = []
            while buffer.count >= 4 {
                let s = buffer.startIndex
                let n = Int(buffer[s]) << 24 | Int(buffer[s + 1]) << 16 | Int(buffer[s + 2]) << 8 | Int(buffer[s + 3])
                guard n <= Box.maxFrame else {
                    buffer.removeAll()
                    throw NSError(domain: "VMWorker", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Message frame of \(n) bytes is over the limit."])
                }
                guard buffer.count >= 4 + n else { break }
                out.append(Data(buffer[(s + 4)..<(s + 4 + n)]))
                buffer.removeSubrange(s..<(s + 4 + n))
            }
            return out
        }
    }

    /// Guest connects here (CID 2 = host) with the worker's stdin/stdout.
    static let messagePort: UInt32 = 1024

    private var vm: VZVirtualMachine!
    private let console = Port(), control = Port(), messages = Port()
    private let listener = VZVirtioSocketListener()
    private var connection: VZVirtioSocketConnection?
    private var messageIn: FileHandle?
    private var messageOut: FileHandle?
    /// Pipe and socket writes can block until the guest reads; keep them off the main thread, in order.
    private let writes = DispatchQueue(label: "coolweb.box.writes")
    private let script: String
    private var outbox: [Data] = []
    /// Guest TCP port -> forwarder, once the guest reported it listening.
    private var forwarders: [Int: PortForwarder] = [:]
    private var serveWaiters: [Int: [(Result<UInt16, Error>) -> Void]] = [:]
    /// Control lines that must follow "run" (the guest reads only mount/run before it). Nil once run was sent.
    private var afterRun: [String]? = []
    private var exitCode: Int?

    init(id: String, options: Options, script: String, kernel: URL, initrd: URL) throws {
        self.id = id
        self.options = options
        self.script = script
        super.init()

        let boot = VZLinuxBootLoader(kernelURL: kernel)
        boot.initialRamdiskURL = initrd
        boot.commandLine = ProcessInfo.processInfo.environment["COOLWEB_CMDLINE"] ?? "console=hvc0 quiet loglevel=3 rdinit=/init"

        let config = VZVirtualMachineConfiguration()
        config.bootLoader = boot
        config.cpuCount = max(VZVirtualMachineConfiguration.minimumAllowedCPUCount,
                              min(options.cpus, VZVirtualMachineConfiguration.maximumAllowedCPUCount))
        config.memorySize = max(VZVirtualMachineConfiguration.minimumAllowedMemorySize,
                                min(options.memoryMB * 1024 * 1024, VZVirtualMachineConfiguration.maximumAllowedMemorySize))
        config.serialPorts = [console, control].map(Box.serial)
        config.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        config.directorySharingDevices = options.mounts.enumerated().map { i, m in
            let fs = VZVirtioFileSystemDeviceConfiguration(tag: "m\(i)")
            fs.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: m.hostDirectory, readOnly: false))
            return fs
        }
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        if options.network {
            let net = VZVirtioNetworkDeviceConfiguration()
            net.attachment = VZNATNetworkDeviceAttachment()
            config.networkDevices = [net]
        }
        try config.validate()

        vm = VZVirtualMachine(configuration: config, queue: .main)
        vm.delegate = self


        read(console) { [weak self] data in
            guard let self else { return }
            for line in self.console.lines(data) {
                let text = String(decoding: line, as: UTF8.self)
                if tracing { trace("[console] \(text)") }
                self.onConsole?(text)
            }
        }
        read(control) { [weak self] data in
            guard let self else { return }
            for line in self.control.lines(data) {
                let text = String(decoding: line, as: UTF8.self)
                if tracing { trace(String(format: "[control %.3f] ", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 100)) + text) }
                self.handleControl(text)
            }
        }
        listener.delegate = self
    }

    private let tracing = ProcessInfo.processInfo.environment["COOLWEB_TRACE_PORTS"] != nil

    private func receive(_ data: Data) {
        if tracing { trace("[vsock in] \(data.count) bytes") }
        switch options.serialization {
        case .json:
            messages.lines(data).forEach { onMessage?($0) }
        case .advanced:
            do { try messages.frames(data).forEach { onMessage?($0) } }
            catch { onMessageError?(error.localizedDescription) }
        }
    }

    // MARK: VZVirtioSocketListenerDelegate

    func listener(_ listener: VZVirtioSocketListener, shouldAcceptNewConnection connection: VZVirtioSocketConnection,
                  from socketDevice: VZVirtioSocketDevice) -> Bool {
        guard self.connection == nil else { return false }
        self.connection = connection
        let fd = connection.fileDescriptor
        messageIn = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        messageOut = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        messageIn?.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.receive(data) }
        }
        // The VM queue is main, so this runs before any later postMessage: queued messages keep their order.
        outbox.forEach(send)
        outbox.removeAll()
        return true
    }

    private static func serial(_ port: Port) -> VZVirtioConsoleDeviceSerialPortConfiguration {
        let config = VZVirtioConsoleDeviceSerialPortConfiguration()
        config.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: port.toGuest.fileHandleForReading,
            fileHandleForWriting: port.fromGuest.fileHandleForWriting)
        return config
    }

    /// Guest output, delivered on the main queue in arrival order.
    private func read(_ port: Port, _ handle: @escaping (Data) -> Void) {
        port.fromGuest.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { handle(data) }
        }
    }

    private func handleControl(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        switch parts.first {
        case "ready":
            state = "running"
            for (i, m) in options.mounts.enumerated() { write(control, Data("mount m\(i) \(m.guestPath)\n".utf8)) }
            let run = "run \(options.serialization.rawValue) \(Data(script.utf8).base64EncodedString())\n"
            write(control, Data(run.utf8))
            afterRun?.forEach { write(control, Data($0.utf8)) }
            afterRun = nil
        case "listening":
            guard parts.count > 1, let port = Int(parts[1]) else { return }
            let waiters = serveWaiters.removeValue(forKey: port) ?? []
            do {
                guard let device = vm.socketDevices.first as? VZVirtioSocketDevice else { throw CocoaError(.featureUnsupported) }
                let fwd = try forwarders[port] ?? PortForwarder(device: device, vsockPort: Self.vsockPort(for: port))
                forwarders[port] = fwd
                waiters.forEach { $0(.success(fwd.hostPort)) }
            } catch {
                waiters.forEach { $0(.failure(error)) }
            }
        case "exit":
            exitCode = parts.count > 1 ? Int(parts[1]) : nil
        default:
            break
        }
    }

    private func write(_ port: Port, _ data: Data) {
        let handle = port.toGuest.fileHandleForWriting
        writes.async { try? handle.write(contentsOf: data) }
    }

    private func send(_ framed: Data) {
        if tracing { trace("[vsock out] \(framed.count) bytes, connected=\(messageOut != nil)") }
        guard let out = messageOut else { return }
        writes.async { try? out.write(contentsOf: framed) }
    }

    func start(_ done: @escaping (Error?) -> Void) {
        vm.start { [weak self] result in
            if case .failure(let e) = result { return done(e) }
            if let self, let socket = self.vm.socketDevices.first as? VZVirtioSocketDevice {
                socket.setSocketListener(self.listener, forPort: Box.messagePort)
            }
            done(nil)
        }
    }

    /// One serialized message: a JSON text (json) or CBOR bytes (advanced). Queued until the guest connects.
    func postMessage(_ payload: Data) {
        var framed = Data()
        switch options.serialization {
        case .json:
            framed = payload
            framed.append(0x0A)
        case .advanced:
            withUnsafeBytes(of: UInt32(payload.count).bigEndian) { framed.append(contentsOf: $0) }
            framed.append(payload)
        }
        if tracing { trace("[post] \(framed.count) bytes, queued=\(messageOut == nil)") }
        if messageOut != nil { send(framed) } else { outbox.append(framed) }
    }

    /// vsock ports for forwards sit above the 16-bit range, clear of the message port.
    private static func vsockPort(for tcpPort: Int) -> UInt32 { 0x10000 + UInt32(tcpPort) }

    /// Serves a guest TCP port on 127.0.0.1. Calls back once something in the guest listens on it.
    func serve(port: Int, _ done: @escaping (Result<UInt16, Error>) -> Void) {
        if let fwd = forwarders[port] { return done(.success(fwd.hostPort)) }
        let first = serveWaiters[port] == nil
        serveWaiters[port, default: []].append(done)
        if tracing { trace("[serve] \(port) first=\(first)") }
        guard first else { return }
        let line = "forward \(Self.vsockPort(for: port)) \(port)\n"
        if afterRun != nil { afterRun?.append(line) } else { write(control, Data(line.utf8)) }
    }

    func terminate() {
        guard state != "stopped" else { return }
        if vm.canStop {
            vm.stop { [weak self] error in self?.finish(error) }
        } else {
            finish(nil)
        }
    }

    private func finish(_ error: Error?) {
        guard state != "stopped" else { return }
        state = "stopped"
        for port in [console, control] {
            port.fromGuest.fileHandleForReading.readabilityHandler = nil
        }
        forwarders.values.forEach { $0.stop() }
        forwarders.removeAll()
        let stopped = NSError(domain: "VMWorker", code: 3, userInfo: [NSLocalizedDescriptionKey: "VM stopped."])
        serveWaiters.values.flatMap { $0 }.forEach { $0(.failure(stopped)) }
        serveWaiters.removeAll()
        messageIn?.readabilityHandler = nil
        connection?.close()
        connection = nil
        messageIn = nil
        messageOut = nil
        onExit?(exitCode, error)
    }

    // MARK: VZVirtualMachineDelegate

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        if ProcessInfo.processInfo.environment["COOLWEB_TRACE_PORTS"] != nil {
            trace(String(format: "[stopped %.3f]", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 100)))
        }
        finish(nil)
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) { finish(error) }
}
