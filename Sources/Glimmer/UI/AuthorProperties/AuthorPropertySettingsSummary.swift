import Foundation

@MainActor
struct AuthorPropertySettingsSummary {
    enum Activity: Equatable { case idle, applying, retryRequired }
    let editableCount: Int
    let modifiedCount: Int
    let activity: Activity

    /// A transient host loading state must not replace the transaction that is
    /// still waiting for its actual ACK. Source/item matching belongs to the view.
    static func effectiveCapabilities(_ current: AuthorPropertyEditingCapabilities,
                                      session: AuthorPropertySettingsSession?) -> AuthorPropertyEditingCapabilities {
        if let session, session.isSaving { return session.capabilities }
        return current
    }

    init(session: AuthorPropertySettingsSession) {
        editableCount = session.project.properties.filter { session.canEdit($0) }.count
        modifiedCount = session.editableModifiedKeys.count
        if session.isSaving { activity = .applying }
        else if session.savedButNotApplied || session.errorText != nil { activity = .retryRequired }
        else { activity = .idle }
    }
}
