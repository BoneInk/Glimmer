import Foundation

/// The notice the setup assistant starts with: the Terms of Use and the Privacy Policy, and a
/// checkbox that the user has read them. It's a notice, not a gate: nothing else in the app
/// depends on it.
///
/// The version shown and the date it was confirmed are kept in the app's defaults. When either
/// document's version changes, the notice shows once more; users who finished setup before the
/// notice existed see it once too.
struct LegalNotice {
    static let versionKey = "LegalNoticeVersion"
    static let dateKey = "LegalNoticeDate"

    /// The documents' combined version, e.g. "terms-of-use 1.0, privacy-policy 1.0".
    static func version(of editions: [LegalDocument: LegalDocument.Edition]) -> String {
        LegalDocument.allCases
            .map { "\($0.rawValue) \(editions[$0]?.version ?? "?")" }
            .joined(separator: ", ")
    }

    /// The version of the documents in the app.
    static var currentVersion: String {
        var editions: [LegalDocument: LegalDocument.Edition] = [:]
        for document in LegalDocument.allCases { editions[document] = document.edition() }
        return version(of: editions)
    }

    struct Acknowledgement: Equatable {
        let version: String
        let date: Date
    }

    static func acknowledgement(in defaults: UserDefaults) -> Acknowledgement? {
        guard let version = defaults.string(forKey: versionKey),
              let date = defaults.object(forKey: dateKey) as? Date else { return nil }
        return Acknowledgement(version: version, date: date)
    }

    /// Whether the notice is due: never confirmed, or confirmed for other versions.
    static func isDue(in defaults: UserDefaults, currentVersion: String = LegalNotice.currentVersion) -> Bool {
        acknowledgement(in: defaults)?.version != currentVersion
    }

    /// Records that the user read the documents of `version`, on `date`.
    static func acknowledge(in defaults: UserDefaults, version: String = LegalNotice.currentVersion, date: Date = Date()) {
        defaults.set(version, forKey: versionKey)
        defaults.set(date, forKey: dateKey)
        OWELog.info(.app, "Legal notice read: \(version)")
    }
}
