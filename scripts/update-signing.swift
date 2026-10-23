// A file-based Ed25519 key, compatible with Sparkle's --ed-key-file format.
// Prints only the public key. Does not access the login Keychain.
import CryptoKit
import Darwin
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 2, ["create", "public"].contains(args[0]) else {
    fail("Usage: swift update-signing.swift create|public <private-key-file>")
}
let url = URL(fileURLWithPath: args[1])
do {
    let key: Curve25519.Signing.PrivateKey
    if args[0] == "create" {
        key = Curve25519.Signing.PrivateKey()
        // withoutOverwriting also rejects an existing symlink. Restrict access
        // from the moment the new file is created, rather than chmod afterward.
        umask(0o077)
        try Data((key.rawRepresentation.base64EncodedString() + "\n").utf8)
            .write(to: url, options: .withoutOverwriting)
    } else {
        let encoded = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw = Data(base64Encoded: encoded), raw.count == 32 || raw.count == 64 else {
            fail("The private key must contain a base64-encoded 32-byte seed (or legacy 64-byte export).")
        }
        key = try Curve25519.Signing.PrivateKey(rawRepresentation: raw.prefix(32))
    }
    print(key.publicKey.rawRepresentation.base64EncodedString())
} catch {
    // Do not include file contents in diagnostics.
    fail("Could not \(args[0] == "create" ? "create" : "read") the update signing key: \(error.localizedDescription)")
}
