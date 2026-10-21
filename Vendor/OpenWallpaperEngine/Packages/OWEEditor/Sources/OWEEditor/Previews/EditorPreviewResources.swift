import Foundation

/// The editor's own pictures for previews, which the app's renderer reads.
public enum EditorPreviewResources {
    /// The test card effects are shown on (`Scripts/make-editor-test-card.py` draws it): a hue
    /// sweep, colour bars, a checker strip and shapes, so colour, blur, distortion and motion show.
    public static var testCard: URL? {
        Bundle.module.url(forResource: "EditorPreviewTestCard", withExtension: "png")
    }
}
