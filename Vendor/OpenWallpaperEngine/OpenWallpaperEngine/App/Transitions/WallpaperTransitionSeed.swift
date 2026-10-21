import Foundation

/// Per-transition random values (WE's g_Hash, g_Hash2, g_Random), each in [0, 1). WE draws them
/// once when a transition starts; the effects place their noise, centres and directions by them.
struct WallpaperTransitionSeed: Equatable, Sendable {
    var hash: Float
    var hash2: Float
    var random: Float

    static func random() -> WallpaperTransitionSeed {
        WallpaperTransitionSeed(hash: Float.random(in: 0..<1), hash2: Float.random(in: 0..<1),
                                random: Float.random(in: 0..<1))
    }
}
