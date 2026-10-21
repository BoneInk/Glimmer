//
//  SceneContentLoader+ParticleDocuments.swift
//  Open Wallpaper Engine
//
//  The Wallpaper Editor's particle documents, and the systems that read them.
//

import SwiftUI
import CoreText
import CryptoKit
import OWESceneEditing

extension SceneContentLoader {
    // MARK: - The Wallpaper Editor's particle documents

    /// Replaces the editor's documents the build reads (`SceneParticleOverlay.assets`); the
    /// systems that read a changed one are then built again (`particleObjectIDsAsync`).
    func setEditorAssets(_ assets: [String: Data]) {
        editorAssetsLock.withLock { editorAssets = assets }
    }

    /// The particle objects whose system, child systems or their materials read one of `paths`,
    /// found on the content queue and delivered on the main queue.
    func particleObjectIDsAsync(using paths: Set<String>, completion: @escaping (Set<Int>) -> Void) {
        contentQueue.async { [weak self] in
            let ids = self?.particleObjectIDs(using: paths) ?? []
            DispatchQueue.main.async { completion(ids) }
        }
    }

    /// The particle objects (by the ids the build gives them) that read one of `paths`. Takes the
    /// scene lock.
    func particleObjectIDs(using paths: Set<String>) -> Set<Int> {
        sceneLock.lock()
        defer { sceneLock.unlock() }
        guard !paths.isEmpty, let authoredScene = loadedScene, let wallpaperDir = loadedWallpaperDirectory else { return [] }
        var ids = Set<Int>()
        for object in SceneObjectIdentity.assigningFallbackIDs(resolvedScene(authoredScene).objects) {
            guard let id = object.id, let path = object.particle else { continue }
            var visited = Set<String>()
            if particleDefinition(path, reads: paths, wallpaperDir: wallpaperDir, visited: &visited) { ids.insert(id) }
        }
        return ids
    }

    /// Whether the definition at `path` is, or reads (its material, its children's), one of `paths`.
    private func particleDefinition(_ path: String, reads paths: Set<String>, wallpaperDir: URL,
                                    visited: inout Set<String>) -> Bool {
        if paths.contains(path) { return true }
        // A definition that doesn't decode builds nothing, which its build logs; it reads nothing here.
        guard visited.insert(path).inserted, let data = rawAssetData(named: path, wallpaperDir: wallpaperDir),
              let system = try? JSONDecoder().decode(WEParticleSystem.self, from: data) else { return false }
        if let material = system.material, paths.contains(material) { return true }
        for child in system.children ?? [] {
            if let name = child.name, particleDefinition(name, reads: paths, wallpaperDir: wallpaperDir, visited: &visited) {
                return true
            }
        }
        return false
    }
}
