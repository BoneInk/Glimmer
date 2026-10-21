import Foundation

/// One of OWE's own caches, as `CacheSweeper` and Settings › Performance › Caches see it. Every
/// entry can be made again from the wallpapers and WE's assets; deleting one only costs the time to
/// make it again. The desktop pictures (`DesktopSnapshotCache`, which macOS shows), the Depth Map
/// Generation plugin's model and the exports are not caches and are not listed.
struct CacheFolder: Equatable, Sendable {
    enum ID: String, CaseIterable, Sendable {
        case textures, loadingSnapshots, editorPreviews, videoTextures, legacyVideoTextures, repairedVideos
        case displayPictures, shaderVariants, pipelineArchives

        /// The id `caches_get` reports (MCP).
        var mcpName: String {
            switch self {
            case .textures: return "textures"
            case .loadingSnapshots: return "loading_snapshots"
            case .editorPreviews: return "editor_previews"
            case .videoTextures: return "video_textures"
            case .legacyVideoTextures: return "legacy_video_textures"
            case .repairedVideos: return "repaired_videos"
            case .displayPictures: return "display_pictures"
            case .shaderVariants: return "shader_variants"
            case .pipelineArchives: return "pipeline_archives"
            }
        }
    }

    let id: ID
    let root: URL
    /// Entries unused for `CacheSweeper.unusedLifetime` are deleted (`CacheSweeper.expire`);
    /// the others only go with Clear Caches.
    let expires: Bool

    /// Whether a file named `name` in this cache is an entry the sweeper may delete. The legacy
    /// video texture folder sits directly in the user's Caches folder, so only OWE's own names
    /// (a SHA-256 and `.mp4`) count there.
    func isEntry(named name: String) -> Bool {
        guard id == .legacyVideoTextures else { return true }
        let parts = name.split(separator: ".")
        return parts.count == 2 && parts[1] == "mp4" && parts[0].count == 64 && parts[0].allSatisfy(\.isHexDigit)
    }
}
