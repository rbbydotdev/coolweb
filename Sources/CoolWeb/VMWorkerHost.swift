import Foundation
import WebKit

/// Native side of VMWorker for one tab. VMs belong to the tab's current document, like Web Workers.
final class VMWorkerHost: NSObject, WKScriptMessageHandlerWithReply {
    static let handlerName = "vmworker"

    weak var webView: WKWebView?
    /// Called when the set of running VMs changes.
    var onChange: (() -> Void)?
    private var boxes: [String: Box] = [:] { didSet { onChange?() } }
    private static var nextId = 1

    private let kernel: URL
    private let initrd: URL

    init(guestDir: URL) {
        kernel = guestDir.appendingPathComponent("Image")
        initrd = guestDir.appendingPathComponent("initramfs.gz")
    }

    var runningCount: Int { boxes.count }

    func terminateAll() { boxes.values.forEach { $0.terminate() } }

    // MARK: Control plane

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let msg = message.body as? [String: Any], let op = msg["op"] as? String else {
            return replyHandler(nil, "Invalid VMWorker message.")
        }
        let box = (msg["id"] as? String).flatMap { boxes[$0] }

        let origin = Self.origin(of: message.frameInfo.securityOrigin)
        switch op {
        case "storageRoot":
            do { replyHandler(try StorageServer.shared.rootURL(for: origin), nil) }
            catch { replyHandler(nil, "VM storage cannot open: \(error.localizedDescription)") }
        case "create":
            create(msg, origin: origin, reply: replyHandler)
        case "post":
            if let b64 = msg["bytes"] as? String {
                guard let bytes = Data(base64Encoded: b64) else { return replyHandler(nil, "Message bytes are not base64.") }
                box?.postMessage(bytes)
            } else {
                box?.postMessage(Data((msg["data"] as? String ?? "null").utf8))
            }
            replyHandler(nil, nil)
        case "serve":
            guard let box, let port = msg["port"] as? Int, (1...65535).contains(port) else {
                return replyHandler(nil, "serve needs a running VM and a port from 1 to 65535.")
            }
            box.serve(port: port) { result in
                switch result {
                case .success(let hostPort): replyHandler("http://127.0.0.1:\(hostPort)/", nil)
                case .failure(let e): replyHandler(nil, "Port \(port) cannot be served: \(e.localizedDescription)")
                }
            }
        case "terminate":
            box?.terminate()
            replyHandler(nil, nil)
        default:
            replyHandler(nil, "Unknown VMWorker operation: \(op).")
        }
    }

    /// Matches the page's location.origin, e.g. "http://localhost:8123".
    static func origin(of o: WKSecurityOrigin) -> String {
        o.port == 0 ? "\(o.protocol)://\(o.host)" : "\(o.protocol)://\(o.host):\(o.port)"
    }

    private func create(_ msg: [String: Any], origin: String, reply: @escaping (Any?, String?) -> Void) {
        var opts = Box.Options()
        if let cpus = msg["cpus"] as? Int { opts.cpus = cpus }
        if let mem = msg["memory"], let mb = Self.parseMB(mem) { opts.memoryMB = mb }
        if let net = msg["network"] as? Bool { opts.network = net }
        if let s = msg["serialization"] as? String {
            guard let mode = Box.Serialization(rawValue: s) else { return reply(nil, "Unknown serialization: \(s).") }
            opts.serialization = mode
        }

        for m in msg["mounts"] as? [[String: Any]] ?? [] {
            guard let path = m["path"] as? String, let url = m["url"] as? String,
                  let dir = StorageServer.shared.directory(forHandleURL: url, origin: origin) else {
                return reply(nil, "Mount \(m["path"] ?? "?") is not a directory of this site's VM storage.")
            }
            opts.mounts.append((guestPath: path, hostDirectory: dir))
        }

        let id = "vm\(Self.nextId)"
        Self.nextId += 1
        let box: Box
        do {
            box = try Box(id: id, options: opts, script: msg["script"] as? String ?? "", kernel: kernel, initrd: initrd)
        } catch {
            return reply(nil, "VMWorker cannot start: \(error.localizedDescription)")
        }
        boxes[id] = box

        box.onMessage = { [weak self] payload in
            switch opts.serialization {
            case .json: self?.event(["type": "message", "id": id, "data": String(decoding: payload, as: UTF8.self)])
            case .advanced: self?.event(["type": "message", "id": id, "bytes": payload.base64EncodedString()])
            }
        }
        box.onMessageError = { [weak self] why in self?.event(["type": "console", "id": id, "text": why]) }
        box.onConsole = { [weak self] line in self?.event(["type": "console", "id": id, "text": line]) }
        box.onExit = { [weak self] code, error in
            self?.boxes.removeValue(forKey: id)
            self?.event(["type": "exit", "id": id, "code": code ?? NSNull(),
                         "error": error?.localizedDescription ?? NSNull()])
        }
        box.start { [weak self] error in
            if let error {
                self?.boxes.removeValue(forKey: id)
                return reply(nil, "VMWorker cannot start: \(error.localizedDescription)")
            }
            reply(["id": id, "cpus": opts.cpus, "memoryMB": opts.memoryMB, "network": opts.network], nil)
        }
    }

    private func event(_ payload: [String: Any]) {
        webView?.callAsyncJavaScript("globalThis.__vmworkerEvent?.(e)", arguments: ["e": payload],
                                     in: nil, in: .page, completionHandler: nil)
    }

    /// Accepts 512 (MB), "512MB", "2GB".
    static func parseMB(_ v: Any) -> UInt64? {
        if let n = v as? Int { return UInt64(n) }
        guard let s = (v as? String)?.uppercased().trimmingCharacters(in: .whitespaces) else { return nil }
        if s.hasSuffix("GB"), let n = Double(s.dropLast(2)) { return UInt64(n * 1024) }
        if s.hasSuffix("MB"), let n = Double(s.dropLast(2)) { return UInt64(n) }
        return UInt64(s)
    }
}
