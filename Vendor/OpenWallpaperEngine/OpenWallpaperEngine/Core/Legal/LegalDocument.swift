import Foundation

/// The Terms of Use and the Privacy Policy. The app bundles both (`Resources/Legal`, in the
/// framework; copies of `docs/legal`) so they can be read offline; the website has them too.
enum LegalDocument: String, CaseIterable, Identifiable {
    case termsOfUse = "terms-of-use"
    case privacyPolicy = "privacy-policy"

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .termsOfUse: return "Terms of Use"
        case .privacyPolicy: return "Privacy Policy"
        }
    }

    /// The document on the project's website.
    var onlineURL: URL {
        switch self {
        case .termsOfUse: return URL(string: "https://openwallpaperengine.app/terms.html")!
        case .privacyPolicy: return URL(string: "https://openwallpaperengine.app/privacy.html")!
        }
    }

    /// The bundled Markdown text; nil if the bundle lacks it.
    func text(in bundle: Bundle = AppBundleLayout.framework) -> String? {
        guard let url = bundle.url(forResource: rawValue, withExtension: "md", subdirectory: "Legal")
                ?? bundle.url(forResource: rawValue, withExtension: "md") else { return nil }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            OWELog.error(.app, "The bundled \(rawValue).md can't be read: \(error)")
            return nil
        }
    }

    /// The version and effective date a document states in its "**Version 1.0 · Effective date:
    /// 2026-09-28**" line.
    struct Edition: Equatable {
        let version: String
        let effectiveDate: String
    }

    static func edition(of text: String) -> Edition? {
        let pattern = #"Version\s+([0-9A-Za-z.\-]+)\s*·\s*Effective date:\s*([0-9]{4}-[0-9]{2}-[0-9]{2})"#
        guard let regex = try? NSRegularExpression(pattern: pattern), // A constant pattern: it compiles.
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let version = Range(match.range(at: 1), in: text),
              let date = Range(match.range(at: 2), in: text) else { return nil }
        return Edition(version: String(text[version]), effectiveDate: String(text[date]))
    }

    func edition(in bundle: Bundle = AppBundleLayout.framework) -> Edition? {
        text(in: bundle).flatMap(Self.edition(of:))
    }
}
