import Combine
import Foundation

/// The window's document: whether it has changes File › Save hasn't saved (its draft), and the
/// app's saving and reverting of them. The editor's window edits a draft of the wallpaper, which
/// nothing else runs until it is saved.
@MainActor
public final class WallpaperEditorDocument: ObservableObject {
    /// The draft differs from the wallpaper as last saved.
    @Published public var isEdited = false
    /// File › Save: the draft becomes the wallpaper's edits, which every running copy of it takes.
    public var save: () throws -> Void
    /// File › Revert to Saved: the draft goes back to the last save (one undo step).
    public var revertToSaved: () -> Void

    public init(save: @escaping () throws -> Void = {}, revertToSaved: @escaping () -> Void = {}) {
        self.save = save
        self.revertToSaved = revertToSaved
    }
}
