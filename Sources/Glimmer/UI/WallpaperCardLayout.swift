import SwiftUI

/// One cover-card geometry across the library, recent items, discovery and downloads.
/// Status and diagnostics belong inside this fixed cover rather than growing its height.
enum WallpaperCardLayout {
    static let aspectRatio: CGFloat = 3.0 / 2.0
    static let minimumWidth: CGFloat = 280
    static let maximumWidth: CGFloat = 460
    static let spacing: CGFloat = 20
    static let horizontalPadding: CGFloat = 24
    static let topPadding: CGFloat = 18
    static let bottomPadding: CGFloat = 28
    static let cornerRadius: CGFloat = 22

    static var columns: [GridItem] {
        [GridItem(.adaptive(minimum: minimumWidth, maximum: maximumWidth), spacing: spacing, alignment: .top)]
    }
}
