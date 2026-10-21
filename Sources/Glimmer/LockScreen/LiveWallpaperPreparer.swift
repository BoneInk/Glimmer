import Foundation
import CryptoKit
import Darwin
import CoreGraphics
import ImageIO

@MainActor
enum LiveWallpaperPreparer {
    static func prepare(item: WallpaperItem, storage: AppStorage, root: URL,
                        specification: LockScreenExportSpecification, allowHTTPS: Bool) async throws -> ExperimentalLockScreenAsset {
        let project = try AuthorPropertyProject.load(projectURL: item.fileURL, allowedRoot: item.fileURL.deletingLastPathComponent())
        let kind: LiveWallpaperRecipe.Kind = item.isSceneWallpaper ? .scene : .web
        var entry: String?, sceneValues = [String: String](), assets: URL?
        var expectedAssets = [String: String]()
        var assetManifest = String(repeating: "0", count: 64)
        let payload: Data
        if kind == .scene {
            #if GW_UNIVERSAL_SCENE_BACKEND
            payload = try await AuthorPropertyServices.payload(item: item, storage: storage)
            sceneValues = try SceneBackendPropertyValues.normalize(payload, project: project).values
            guard let bundle = try await Task.detached(priority: .userInitiated, operation: {
                try SceneRuntimeAssetRegistry.production.loadRegisteredBundle()
            }).value else { throw LiveWallpaperFailure(message: "请先准备 Scene 引擎资源。") }
            assets = bundle.assetsRootURL; assetManifest = bundle.manifestFingerprint
            expectedAssets = bundle.verifiedFiles
            #else
            throw LiveWallpaperFailure(message: "当前构建不包含实时 Scene 锁屏引擎。")
            #endif
        } else {
            let descriptor = try WebWallpaperProjectDescriptor(projectURL: item.fileURL)
            entry = String(descriptor.entryURL.path.dropFirst(descriptor.root.path.count + 1))
            payload = try await WebWallpaperLockScreenConfiguration.payload(item: item, storage: storage)
        }
        let recipe = LiveWallpaperRecipe(assetID: UUID(), kind: kind, width: specification.width,
            height: specification.height, fps: specification.renderedFramesPerSecond,
            entryFile: entry, propertiesJSON: payload, sceneProperties: sceneValues,
            projectDigest: SHA256.hash(data: project.sourceData).map { String(format: "%02x", $0) }.joined(),
            assetsManifestDigest: assetManifest, allowHTTPS: kind == .web && allowHTTPS)
        return try await LiveWallpaperPackaging.shared.prepare(itemID: item.id, title: item.displayTitle,
            project: project.projectURL.deletingLastPathComponent(), assets: assets, expectedAssets: expectedAssets, root: root, recipe: recipe)
    }
}

actor LiveWallpaperPackaging {
    static let shared = LiveWallpaperPackaging()

    func prepare(itemID: UUID, title: String, project: URL, assets: URL?, expectedAssets: [String: String], root: URL,
                 recipe initial: LiveWallpaperRecipe) throws -> ExperimentalLockScreenAsset {
        let staging = root.appendingPathComponent(".preparing-live-" + initial.assetID.uuidString)
        let destination = root.appendingPathComponent(itemID.uuidString)
        try LockScreenOwnedFiles.makePrivateDirectory(staging)
        defer { try? FileManager.default.removeItem(at: staging) }
        _ = try LiveWallpaperBundle.inspect(project, copyTo: staging.appendingPathComponent("project"))
        if let assets {
            let copied = try LiveWallpaperBundle.inspect(assets, copyTo: staging.appendingPathComponent("assets"))
            guard Dictionary(uniqueKeysWithValues: copied.map { ($0.path, $0.sha256) }) == expectedAssets else {
                throw LiveWallpaperFailure(message: "Scene 引擎资源在准备期间已改变。")
            }
        }
        // A system snapshot comes from the real renderer. This local placeholder
        // only preserves the prepared-asset file contract before it is acquired.
        let poster = staging.appendingPathComponent("poster.jpg")
        guard let bitmap = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let image = bitmap.makeImage(), let target = CGImageDestinationCreateWithURL(poster as CFURL, "public.jpeg" as CFString, 1, nil)
        else { throw LiveWallpaperFailure(message: "无法准备实时锁屏预览。") }
        CGImageDestinationAddImage(target, image, nil)
        guard CGImageDestinationFinalize(target) else { throw LiveWallpaperFailure(message: "无法写入实时锁屏预览。") }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: poster.path)
        var recipe = initial
        recipe.files = try LiveWallpaperBundle.inspect(staging)
        try LiveWallpaperBundle.writeRecipe(recipe, root: staging)
        _ = try LiveWallpaperBundle.load(staging)
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destination.path) {
            try LockScreenOwnedFiles.makePrivateDirectory(destination)
            guard renameatx_np(AT_FDCWD, staging.path, AT_FDCWD, destination.path, UInt32(RENAME_SWAP)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } else { try FileManager.default.moveItem(at: staging, to: destination) }
        return .init(id: recipe.assetID, itemID: itemID, title: title,
            videoURL: destination.appendingPathComponent("project/project.json"), posterURL: destination.appendingPathComponent("poster.jpg"),
            durationSeconds: 0, codec: "live-" + recipe.kind.rawValue, liveRecipe: recipe)
    }

    func stage(_ asset: ExperimentalLockScreenAsset, directory: URL) throws -> String {
        guard let expected = asset.liveRecipe else { throw LiveWallpaperFailure(message: "缺少实时锁屏项目。") }
        let root = asset.videoURL.deletingLastPathComponent().deletingLastPathComponent()
        let recipe = try LiveWallpaperBundle.load(root)
        guard recipe == expected else { throw LiveWallpaperFailure(message: "实时锁屏项目已改变，请重新准备。") }
        let name = "live-" + recipe.assetID.uuidString
        if recipe.kind == .scene {
            for slot in 0..<8 {
                try LockScreenOwnedFiles.makePrivateDirectory(directory.appendingPathComponent("SceneCaches/" + recipe.assetID.uuidString + "/slot\(slot)"))
            }
        }
        let destination = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: destination.path) {
            guard try LiveWallpaperBundle.load(destination) == recipe else { throw LiveWallpaperFailure(message: "共享项目标识不匹配。") }
            return name
        }
        let staging = directory.appendingPathComponent(".staging-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        _ = try LiveWallpaperBundle.inspect(root, copyTo: staging)
        try LiveWallpaperBundle.writeRecipe(recipe, root: staging)
        _ = try LiveWallpaperBundle.load(staging)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: staging, to: destination)
        return name
    }
}
