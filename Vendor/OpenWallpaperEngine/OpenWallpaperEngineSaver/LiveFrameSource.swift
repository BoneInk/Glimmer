import Foundation

/// A saver process's way to the app's live frames: the `.saver`'s global surfaces and Darwin
/// notifications (`GlobalSurfaceFrameSource`) or the extension's XPC connection. One per process,
/// shared by its views (`LiveSaverPresenter`). Main thread.
protocol LiveFrameSource: AnyObject {
    var store: LiveFrameStore { get }
    /// A view started showing (not a preview: previews never make the app draw).
    func attach(viewID: String, display: String?, isPreview: Bool)
    /// The view still shows; called about once a second.
    func ping(viewID: String)
    func detach(viewID: String)
    /// Brings `store` up to date before a view reads it (the `.saver` reads the notifications'
    /// states here; the extension's XPC fills it as messages come).
    func refresh()
}
