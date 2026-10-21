import Foundation

/// Text from one string catalog of a module (`<table>.xcstrings` in `bundle`; nil is
/// `Localizable`), in every language the app ships. Each catalog has one, named like a function,
/// such as the timeline's `T("Cut Keyframes")`.
public struct EditorText {
    public let table: String?
    public let bundle: Bundle

    public init(table: String?, bundle: Bundle) {
        self.table = table
        self.bundle = bundle
    }

    public func callAsFunction(_ key: String.LocalizationValue) -> String {
        String(localized: key, table: table, bundle: bundle)
    }
}
