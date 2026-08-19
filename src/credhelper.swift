import Foundation
import Security
import Darwin

// NotchUsage credential helper.
//
// Reads exactly one Claude Code keychain record and writes it to stdout.
// It exists as a separate binary so the keychain "Always Allow" approval is
// granted to THIS file, which is built once and cached — updates of the main
// app never touch it, so macOS never re-prompts after updates.

// Cheap guard: only serve processes launched from a NotchUsage binary.
// (Not a security boundary — local malware has better options anyway — but
// it keeps random processes from using the helper as a token oracle.)
func parentIsNotchUsage() -> Bool {
    var buf = [CChar](repeating: 0, count: 4 * 1024)
    let n = proc_pidpath(getppid(), &buf, UInt32(buf.count))
    guard n > 0 else { return false }
    let path = String(cString: buf)
    return (path as NSString).lastPathComponent.hasPrefix("NotchUsage")
}

let args = CommandLine.arguments
guard args.count == 2, args[1].hasPrefix("Claude Code-credentials") else {
    FileHandle.standardError.write(Data("usage: <service name with the Claude Code prefix>\n".utf8))
    exit(2)
}
guard parentIsNotchUsage() else {
    FileHandle.standardError.write(Data("refusing: caller is not NotchUsage\n".utf8))
    exit(3)
}

let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: args[1],
    kSecMatchLimit as String: kSecMatchLimitOne,
    kSecReturnData as String: true,
]
var result: CFTypeRef?
let status = SecItemCopyMatching(query as CFDictionary, &result)
guard status == errSecSuccess, let data = result as? Data else {
    if status == errSecUserCanceled { exit(44) }
    if status == errSecItemNotFound { exit(45) }
    exit(46)
}
FileHandle.standardOutput.write(data)
exit(0)
