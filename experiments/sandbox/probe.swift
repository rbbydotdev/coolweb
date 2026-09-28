// Can a process lock itself to one directory with a kernel sandbox, so following a symlink out is denied?
import Foundation

@_silgen_name("sandbox_init_with_parameters")
func sandbox_init_with_parameters(_ profile: UnsafePointer<CChar>, _ flags: UInt64,
                                  _ params: UnsafePointer<UnsafePointer<CChar>?>?, _ err: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32

let root = CommandLine.arguments[1]
let rootfd = open(root, O_RDONLY | O_DIRECTORY)
let profile = """
(version 1)
(deny default)
(allow file-read* file-write* (subpath (param "ROOT")))
"""
var err: UnsafeMutablePointer<CChar>?
let params: [UnsafePointer<CChar>?] = [("ROOT" as NSString).utf8String, (root as NSString).utf8String, nil]
let rc = params.withUnsafeBufferPointer { sandbox_init_with_parameters(profile, 0, $0.baseAddress, &err) }
print("sandbox_init:", rc, err.map { String(cString: $0) } ?? "")

func tryRead(_ rel: String) {
    let fd = openat(rootfd, rel, O_RDONLY)
    if fd < 0 { print("\(rel): denied (\(String(cString: strerror(errno))))"); return }
    var buf = [UInt8](repeating: 0, count: 64); let n = read(fd, &buf, 64); close(fd)
    print("\(rel): READ \(n) bytes")
}
tryRead("ok.txt")
tryRead("escape/etc/hosts")
tryRead("../../../../../../etc/hosts")
print("absolute /etc/hosts:", open("/etc/hosts", O_RDONLY) < 0 ? "denied" : "READ")
