import Foundation

/// `CoolWeb --selftest [script]`: boots one VMWorker without UI, posts two messages, prints every event, exits.
/// Exit status 0 only when the worker replied to both messages and exited with code 0.
enum SelfTest {
    /// `CoolWeb --bench`: echo VM (advanced framing), 8 MB frames through the serial port and back, no browser.
    static func bench() -> Never {
        let box = try! Box(id: "bench", options: .init(cpus: 2, memoryMB: 512, network: false, serialization: .advanced),
                           script: "#!/bin/sh\nexec cat\n",
                           kernel: guestDirectory.appendingPathComponent("Image"),
                           initrd: guestDirectory.appendingPathComponent("initramfs.gz"))
        let payload = Data((0..<(8 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 2654435761 >> 13) })
        var round = 0, t = Date()
        box.onMessage = { back in
            let ms = Date().timeIntervalSince(t) * 1000
            precondition(back == payload, "echo differs")
            print(String(format: "round %d: 8 MB out and back in %.0f ms (%.0f MB/s each way)", round, ms, 8 / (ms / 1000)))
            round += 1
            if round == 4 { exit(0) }
            t = Date()
            box.postMessage(payload)
        }
        box.onExit = { _, e in print("exited early: \(String(describing: e))"); exit(1) }
        box.start { _ in t = Date(); box.postMessage(payload) }
        dispatchMain()
    }

    static func run(scriptPath: String?) -> Never {
        let script = scriptPath.flatMap { try? String(contentsOfFile: $0) } ?? """
            #!/bin/sh
            echo "stderr works" >&2
            echo '{"type":"ready","kernel":"'"$(uname -r)"'","cpus":'"$(nproc)"'}'
            n=0
            while IFS= read -r msg; do
              n=$((n + 1))
              echo "{\\"echo\\":$msg,\\"n\\":$n}"
              [ $n -ge 2 ] && exit 0
            done
            """
        let t0 = Date()
        let ms = { String(format: "%6.0f ms [%.3f]", Date().timeIntervalSince(t0) * 1000, Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 100)) }
        var replies = 0

        let box: Box
        do {
            box = try Box(id: "selftest", options: .init(cpus: 2, memoryMB: 512, network: true, serialization: .json), script: script,
                          kernel: guestDirectory.appendingPathComponent("Image"),
                          initrd: guestDirectory.appendingPathComponent("initramfs.gz"))
        } catch {
            print("FAIL create: \(error)")
            exit(1)
        }
        box.onConsole = { print("\(ms()) console: \($0)") }
        box.onMessage = { payload in
            let line = String(decoding: payload, as: UTF8.self)
            print("\(ms()) message: \(line)")
            if line.contains("\"echo\"") { replies += 1 }
        }
        box.onExit = { code, error in
            print("\(ms()) exit code=\(code.map(String.init) ?? "nil") error=\(error.map { "\($0)" } ?? "nil")")
            let ok = replies == 2 && code == 0
            print(ok ? "PASS" : "FAIL replies=\(replies)")
            exit(ok ? 0 : 1)
        }
        // Posted before boot finishes: exercises the queue-until-ready path.
        box.postMessage(Data(#"{"hello":"first"}"#.utf8))
        box.postMessage(Data(#"{"hello":"second"}"#.utf8))
        box.start { error in
            if let error { print("FAIL start: \(error)"); exit(1) }
            print("\(ms()) started")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            print("FAIL timeout replies=\(replies)")
            exit(1)
        }
        dispatchMain()
    }
}
