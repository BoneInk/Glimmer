import Foundation
import Security

/// Checks that a bundle is signed by the same developer as the running app before the app runs
/// it: its signature must be valid and satisfy the running app's designated requirement.
enum UpdateBundleVerifier {
    enum Failure: Error, CustomStringConvertible {
        /// The running build has no stable identity (ad hoc or unsigned, as in a local Debug build).
        case noStableRequirement(String)
        case invalid(OSStatus)

        var description: String {
            switch self {
            case .noStableRequirement(let reason): return "the running build has no stable signing requirement (\(reason))"
            case .invalid(let status): return "the signature doesn't satisfy this app's requirement (\(status))"
            }
        }
    }

    /// The running app's designated requirement; fails for an ad hoc or unsigned build.
    static func runningAppRequirement() throws -> SecRequirement {
        var code: SecCode?
        var status: OSStatus = SecCodeCopySelf([], &code)
        guard status == errSecSuccess, let code else { throw Failure.noStableRequirement("SecCodeCopySelf \(status)") }
        var staticCode: SecStaticCode?
        status = SecCodeCopyStaticCode(code, [], &staticCode)
        guard status == errSecSuccess, let staticCode else { throw Failure.noStableRequirement("SecCodeCopyStaticCode \(status)") }
        var info: CFDictionary?
        status = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        let signing = info as? [String: Any]
        // An ad hoc signature's designated requirement is its cdhash, which no other build has.
        let flags: UInt32 = (signing?[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        guard status == errSecSuccess, signing?[kSecCodeInfoTeamIdentifier as String] != nil,
              flags & SecCodeSignatureFlags.adhoc.rawValue == 0 else {
            throw Failure.noStableRequirement("ad hoc or no team")
        }
        var requirement: SecRequirement?
        status = SecCodeCopyDesignatedRequirement(staticCode, [], &requirement)
        guard status == errSecSuccess, let requirement else {
            throw Failure.noStableRequirement("SecCodeCopyDesignatedRequirement \(status)")
        }
        return requirement
    }

    /// Throws unless `bundle` is validly signed and satisfies `requirement`.
    static func verify(_ bundle: URL, requirement: SecRequirement) throws {
        var staticCode: SecStaticCode?
        var status: OSStatus = SecStaticCodeCreateWithPath(bundle as CFURL, [], &staticCode)
        guard status == errSecSuccess, let staticCode else { throw Failure.invalid(status) }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        status = SecStaticCodeCheckValidity(staticCode, flags, requirement)
        guard status == errSecSuccess else { throw Failure.invalid(status) }
    }
}
