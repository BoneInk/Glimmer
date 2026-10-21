import Foundation

/// State of the Steam Web API key controls: whether a key is stored (shown masked), and entering,
/// validating, replacing or removing one. The key itself stays in the keychain.
@MainActor
final class SteamWebAPIKeyViewModel: ObservableObject {
    @Published private(set) var maskedKey: String?
    @Published var draft = ""
    @Published var isEditing = false
    @Published private(set) var isValidating = false
    @Published private(set) var errorMessage: String?

    private let store: KeychainSecret
    private let validator: (String) async throws -> Void

    init(store: KeychainSecret = SteamCredentials.webAPIKey(),
         validator: ((String) async throws -> Void)? = nil) {
        self.store = store
        self.validator = validator ?? { try await WorkshopAPIService(apiKey: store).validate(apiKey: $0) }
        reload()
    }

    var isKeySet: Bool { maskedKey != nil }

    var canSubmit: Bool { !trimmedDraft.isEmpty && !isValidating }

    func reload() {
        maskedKey = store.load().map(Self.mask)
        isEditing = maskedKey == nil
    }

    func beginReplacing() {
        draft = ""
        errorMessage = nil
        isEditing = true
    }

    func cancelReplacing() {
        draft = ""
        errorMessage = nil
        isEditing = maskedKey == nil
    }

    /// Validates the entered key with one cheap Steam call and stores it if Steam accepts it.
    /// Returns whether a key was saved.
    @discardableResult
    func submit() async -> Bool {
        let key = trimmedDraft
        guard !key.isEmpty else { return false }
        isValidating = true
        errorMessage = nil
        defer { isValidating = false }
        do {
            try await validator(key)
            try store.save(key)
        } catch {
            errorMessage = SteamSecretRedactor.redact(error.localizedDescription, secrets: [key])
            return false
        }
        draft = ""
        reload()
        return true
    }

    func remove() {
        do {
            try store.remove()
            errorMessage = nil
        } catch {
            errorMessage = String(localized: "Couldn't remove the key: \(error.localizedDescription)", comment: "%@ is the system's reason")
        }
        reload()
    }

    /// The last four characters, the rest as dots: enough to tell keys apart, useless on its own.
    static func mask(_ key: String) -> String {
        let visible = key.count > 8 ? String(key.suffix(4)) : ""
        return String(repeating: "•", count: 12) + visible
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
