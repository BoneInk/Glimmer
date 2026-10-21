// Prints the Sparkle EdDSA public key of the private key read from standard input, in the
// base64 form SUPublicEDKey uses. The release workflow compares it with SPARKLE_PUBLIC_ED_KEY,
// so a build never ships a public key that can't verify its own updates.
//
//   printf '%s' "$SPARKLE_PRIVATE_KEY" | xcrun swift Scripts/release/sparkle-public-key.swift
//
// The private key is `generate_keys -x` output: base64 of the 32-byte seed (older exports: the
// 64-byte seed + public key). It is never printed.
import CryptoKit
import Foundation

let input: String = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    .trimmingCharacters(in: .whitespacesAndNewlines)
guard let raw: Data = Data(base64Encoded: input), raw.count == 32 || raw.count == 64 else {
    FileHandle.standardError.write(Data("error: the private key is not base64 of 32 or 64 bytes\n".utf8))
    exit(1)
}
do {
    let key: Curve25519.Signing.PrivateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: raw.prefix(32))
    print(key.publicKey.rawRepresentation.base64EncodedString())
} catch {
    FileHandle.standardError.write(Data("error: not an Ed25519 private key\n".utf8))
    exit(1)
}
