import Foundation
import CryptoKit
import Darwin

@main enum LiveWallpaperBundleTests {
    static func main() throws {
        umask(0o077)
        let fm = FileManager.default
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), bundle = root.appendingPathComponent("bundle")
        try fm.createDirectory(at: source.appendingPathComponent("project"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let project = source.appendingPathComponent("project/project.json"), html = source.appendingPathComponent("project/index.html")
        let data = Data("{\"type\":\"web\",\"file\":\"index.html\"}".utf8)
        try data.write(to: project); try Data("hello".utf8).write(to: html)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: html.path)
        let files = try LiveWallpaperBundle.inspect(source, copyTo: bundle)
        var recipe = LiveWallpaperRecipe(assetID: UUID(), kind: .web, width: 640, height: 400, fps: 30,
            entryFile: "index.html", propertiesJSON: Data("{}".utf8), sceneProperties: [:],
            projectDigest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            assetsManifestDigest: String(repeating: "0", count: 64), allowHTTPS: false, files: files)
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: message, code: 1) }; print("PASS \(message)")
        }
        func rejects(_ operation: () throws -> Void, _ message: String) throws {
            var rejected = false
            do { try operation() } catch { rejected = true }
            try check(rejected, message)
        }
        try LiveWallpaperBundle.writeRecipe(recipe, root: bundle)
        try check(try LiveWallpaperBundle.load(bundle) == recipe, "a staged bundle preserves the exact recipe and bytes")
        let stagedHTML = bundle.appendingPathComponent("project/index.html")
        let mode = try fm.attributesOfItem(atPath: stagedHTML.path)[.posixPermissions] as? NSNumber
        try check(mode?.intValue == 0o600, "copied resources are private even when original files are public")
        try Data("jello".utf8).write(to: stagedHTML)
        try rejects({ _ = try LiveWallpaperBundle.load(bundle) }, "same-size tampering fails content verification")
        try Data("hello".utf8).write(to: stagedHTML)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: stagedHTML.path)
        try rejects({ _ = try LiveWallpaperBundle.load(bundle) }, "public staged files are rejected")
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stagedHTML.path)
        let extra = bundle.appendingPathComponent("extra.js")
        try Data("unexpected".utf8).write(to: extra)
        try rejects({ _ = try LiveWallpaperBundle.load(bundle) }, "unlisted runtime resources are rejected")
        try fm.removeItem(at: extra)
        try fm.removeItem(at: stagedHTML)
        try fm.createSymbolicLink(at: stagedHTML, withDestinationURL: html)
        try rejects({ _ = try LiveWallpaperBundle.load(bundle) }, "symlinked resources never grant outside access")
        try fm.removeItem(at: stagedHTML)
        try fm.linkItem(at: html, to: stagedHTML)
        try rejects({ _ = try LiveWallpaperBundle.load(bundle) }, "hardlinked resources are rejected")
        try fm.removeItem(at: stagedHTML)
        try Data("hello".utf8).write(to: stagedHTML)
        let recipeFile = bundle.appendingPathComponent("recipe.json")
        try fm.removeItem(at: recipeFile)
        try fm.createSymbolicLink(at: recipeFile, withDestinationURL: project)
        try rejects({ _ = try LiveWallpaperBundle.load(bundle) }, "a symlink cannot replace the recipe")
        try fm.removeItem(at: recipeFile)
        try LiveWallpaperBundle.writeRecipe(recipe, root: bundle)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundle.path)
        try rejects({ _ = try LiveWallpaperBundle.load(bundle) }, "shared bundles must have a private root")
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bundle.path)
        let linkedRoot = root.appendingPathComponent("linked")
        try fm.createSymbolicLink(at: linkedRoot, withDestinationURL: bundle)
        try rejects({ _ = try LiveWallpaperBundle.load(linkedRoot) }, "a symlinked root is rejected")
        recipe.files.append(recipe.files[0])
        try rejects({ try recipe.validate() }, "duplicate manifest entries are rejected")
        try check(!LiveWallpaperRecipe.relative("../secret") && !LiveWallpaperRecipe.relative("/etc/passwd")
            && !LiveWallpaperRecipe.relative("project//index.html"), "absolute and traversing paths are rejected")
    }
}
