import XCTest
@testable import OpenWallpaperEngine

/// Items that ship only as a `.pkg`: `…/workshop/<id>/…` paths resolve inside the package.
final class WorkshopPackageAssetTests: XCTestCase {
    /// A PKGV archive holding `files`, in WE's layout.
    static func package(_ files: [(String, Data)]) -> Data {
        func u32(_ value: Int) -> Data { withUnsafeBytes(of: UInt32(value).littleEndian) { Data($0) } }
        func string(_ value: String) -> Data { u32(value.utf8.count) + Data(value.utf8) }
        var table = string("PKGV0019") + u32(files.count)
        var body = Data()
        for (path, data) in files {
            table += string(path) + u32(body.count) + u32(data.count)
            body += data
        }
        return table + body
    }

    func testEffectsShadersAndTexturesResolveInsideTheItemsPackage() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "owe-pkg-\(UUID().uuidString)")
        let item = root.appending(path: "3333333333")
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.package([("effects/glow/effect.json", Data("{}".utf8)),
                          ("shaders/glow.frag", Data("frag".utf8)),
                          ("materials/tex.tex", Data("tex".utf8))])
            .write(to: item.appending(path: "scene.pkg"))
        let resolver = WorkshopAssetResolver(roots: [root])
        XCTAssertEqual(resolver.data(for: "effects/workshop/3333333333/glow/effect.json"), Data("{}".utf8))
        XCTAssertEqual(resolver.data(for: "shaders/workshop/3333333333/glow.frag"), Data("frag".utf8))
        XCTAssertEqual(resolver.data(for: "materials/workshop/3333333333/tex.tex"), Data("tex".utf8))
        XCTAssertNil(resolver.data(for: "shaders/workshop/3333333333/missing.frag"))
        XCTAssertNil(resolver.data(for: "shaders/glow.frag"))
    }
}
