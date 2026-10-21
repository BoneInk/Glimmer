import Foundation

/// What `applyGeneralSettings(changed)` receives (lib.sceneScript.d.ts `IComponent`; the docs' event
/// page): WE's app settings a script may follow. Today that is only `language`, WE's UI language as
/// one of its own codes (the docs list them), so a script can show its text in the user's language.
/// Here that is the app's language: `Locale.preferredLanguages`, which is the language chosen in
/// Settings (`GSLocalization` writes it to the app's `AppleLanguages`) or else the system's order.
/// The first of them WE has a code for wins, else WE's default, English.
enum SceneScriptGeneralSettings {
    /// The language codes the docs list for `applyGeneralSettings`.
    static let languages: Set<String> = [
        "ar-sa", "be-by", "bg-bg", "cs-cz", "da-dk", "de-de", "el-gr", "en-us", "es-es", "eu-es", "fa-ir", "fi-fi",
        "fr-fr", "he-il", "hu-hu", "id-id", "it-it", "ja-jp", "ko-kr", "lt-lt", "nb-no", "nl-nl", "pl-pl", "pt-br",
        "pt-pt", "ro-ro", "ru-ru", "sk-sk", "sl-si", "sv-se", "th-th", "tr-tr", "uk-ua", "vi-vn", "zh-chs", "zh-cht",
    ]

    static let defaultLanguage = "en-us"

    /// The settings for the user's current preferred languages.
    static func current() -> [String: Any] {
        ["language": language(for: Locale.preferredLanguages)]
    }

    /// The WE code of the first of `identifiers` (BCP 47, as `Locale.preferredLanguages` lists
    /// them) that WE has a language for; `defaultLanguage` when none.
    static func language(for identifiers: [String]) -> String {
        for identifier in identifiers {
            if let code = code(for: identifier) { return code }
        }
        return defaultLanguage
    }

    private static func code(for identifier: String) -> String? {
        let parts = identifier.lowercased().replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
        guard let language = parts.first else { return nil }
        let rest = parts.dropFirst()
        switch language {
        case "zh":
            // Traditional script, or a region that writes it, is zh-cht; everything else zh-chs.
            let traditional = rest.contains("hant") || rest.contains("tw") || rest.contains("hk") || rest.contains("mo")
            return traditional ? "zh-cht" : "zh-chs"
        case "pt":
            return rest.contains("pt") ? "pt-pt" : "pt-br"
        case "nb", "no", "nn":
            return "nb-no"
        default:
            // WE has one code per language; its region is fixed (en-us for any English).
            return languages.first { $0.hasPrefix(language + "-") }
        }
    }
}
