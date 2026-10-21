import AppKit

/// The Wallpaper Editor's questions about a draft (`WallpaperEditorDraft`), worded and ordered as
/// a document app's: unsaved changes when a window closes or the editor quits, and a draft left
/// from an earlier session when a wallpaper opens.
@MainActor
enum WallpaperEditorDraftAlerts {
    /// Save (first button), Cancel (second), Don't Save (third), as AppKit's documents ask.
    static func unsavedChanges(title: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = String(localized: "Do you want to save the changes you made to “\(title)”?",
                                   comment: "Wallpaper Editor: asked when a window with unsaved changes closes or the editor quits; the wallpaper's title")
        alert.informativeText = String(localized: "Your changes will be lost if you don’t save them.",
                                       comment: "Wallpaper Editor: under the question whether to save a window's changes")
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let dontSave = alert.addButton(withTitle: String(localized: "Don’t Save",
                                                         comment: "Wallpaper Editor: drops a window's unsaved changes as it closes"))
        dontSave.hasDestructiveAction = true
        // ⌘D, as AppKit's Don't Save.
        dontSave.keyEquivalent = "d"
        dontSave.keyEquivalentModifierMask = .command
        return alert
    }

    /// Resume (first button) or Discard (second).
    static func leftoverDraft(title: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = String(localized: "“\(title)” has unsaved changes.",
                                   comment: "Wallpaper Editor: a wallpaper opens with a draft left from an earlier session (the editor quit or crashed before it was saved); the wallpaper's title")
        alert.informativeText = String(localized: "They were kept from an earlier editing session. Resume editing them, or discard them and edit the wallpaper as it was last saved.",
                                       comment: "Wallpaper Editor: under the question about a draft left from an earlier session")
        alert.addButton(withTitle: String(localized: "Resume"))
        let discard = alert.addButton(withTitle: String(localized: "Discard",
                                                        comment: "Wallpaper Editor: drops a draft left from an earlier session"))
        discard.hasDestructiveAction = true
        return alert
    }

    static func saveFailed(_ error: Error) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = String(localized: "The changes couldn’t be saved.",
                                   comment: "Wallpaper Editor: saving a window's changes failed")
        alert.informativeText = error.localizedDescription
        return alert
    }
}
