import Foundation
import Darwin

@main @MainActor struct SceneScriptModuleSnapshotTests {
    static let fm = FileManager.default
    static var checks = 0
    static func check(_ value: Bool, _ label: String) throws {
        guard value else { throw SceneWallpaperFailure(message: label) }
        checks += 1; print("PASS \(label)")
    }
    static func rejects(_ label: String, _ operation: () throws -> Void) throws {
        do { try operation() } catch { try check(true, label); return }
        throw SceneWallpaperFailure(message: "Unexpected success: \(label)")
    }
    static func write(_ root: URL, _ path: String, _ data: Data) throws {
        let file = root.appendingPathComponent(path)
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
    }
    static func u32(_ n: UInt32) -> Data { var n = n.littleEndian; return withUnsafeBytes(of: &n) { Data($0) } }
    static func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
    static func sourceBytes(_ root: URL) throws -> [String:Data] {
        guard let files = fm.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey]) else { throw SceneWallpaperFailure(message:"Cannot snapshot fixture") }
        var result: [String:Data] = [:]
        for case let file as URL in files where try file.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile == true {
            result[String(file.path.dropFirst(root.path.count+1))] = try Data(contentsOf:file)
        }
        return result
    }
    static func package(_ entries: [(String, Data)], at url: URL) throws {
        let magic = Data("PKGV0005".utf8)
        var header = u32(UInt32(magic.count)) + magic + u32(UInt32(entries.count)), payload = Data(), offset: UInt32 = 0
        for (name, data) in entries {
            let bytes = Data(name.utf8)
            header += u32(UInt32(bytes.count)) + bytes + u32(offset) + u32(UInt32(data.count))
            payload += data; offset += UInt32(data.count)
        }
        try (header + payload).write(to: url)
    }
    static func project(_ root: URL, scripted: Bool, packaged: Bool, extras: [(String, Data)]) throws -> URL {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try write(root, "project.json", json(["type":"scene", "file":"scene.json"]))
        var layer: [String: Any] = ["id":1, "name":"module fixture", "image":"model.json", "size":"16 16", "origin":"8 8 0"]
        if scripted { layer["alpha"] = ["value":1,"script":"import {gain} from './scripts/gain.js'; export function update(v){return gain;}"] }
        var tex = Data("TEXV0005\0TEXI0001\0".utf8)
        for n: UInt32 in [0,0,2,2,2,2,0] { tex += u32(n) }
        tex += Data("TEXB0001\0".utf8)
        for n: UInt32 in [1,1,2,2,16] { tex += u32(n) }; tex += Data(repeating:255,count:16)
        let entries: [(String, Data)] = [
            ("scene.json",try json(["general":["orthogonalprojection":["width":16,"height":16]],"objects":[layer]])),
            ("model.json",try json(["material":"material.json"])),
            ("material.json",try json(["passes":[["shader":"genericimage2","blending":"translucent","textures":["image"]]]])),
            ("materials/image.tex",tex)
        ] + extras
        if packaged { try package(entries,at:root.appendingPathComponent("scene.pkg")) }
        else { for (name,data) in entries { try write(root,name,data) } }
        return root.appendingPathComponent("project.json")
    }
    static func main() throws {
        let root = fm.temporaryDirectory.appendingPathComponent("GW-SceneScript-Modules-\(UUID())")
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? fm.removeItem(at:root) }
        func fresh() throws -> URL {
            let url = root.appendingPathComponent(UUID().uuidString)
            try fm.createDirectory(at:url,withIntermediateDirectories:true); return url
        }
        let valid = Data("export const gain = 0.5; // 中文 🌕".utf8)
        let invalidSyntax = Data("export this is NOT JavaScript!!!".utf8)
        for packaged in [false,true] {
            let directory = try fresh()
            let url = try project(directory,scripted:true,packaged:packaged,extras:[("scripts/gain.js",valid),("unused/broken.js",invalidSyntax)])
            if packaged { try write(directory,"outside-archive.js",Data([0xff])) }
            let before = try sourceBytes(directory)
            let inspected = try SceneWallpaperInspector.inspect(projectURL:url)
            guard let program = inspected.scriptProgram else { throw SceneWallpaperFailure(message:"Missing program: \(inspected.diagnostics)") }
            try check(inspected.isRenderableSubset && program.modules.count == 2,"\(packaged ? "PKG" : "loose") snapshots exactly project-visible modules")
            try check(program.modules["scripts/gain.js"] == String(data:valid,encoding:.utf8),"module UTF-8 source is preserved byte-for-byte")
            try check(program.modules["unused/broken.js"] != nil,"unreferenced syntax errors are not parsed by Inspector")
            let decoded = try JSONDecoder().decode(SceneScriptProgram.self,from:JSONEncoder().encode(program))
            try check(decoded.modules == program.modules,"Codable module map round trip")
            try check(SceneScriptProgram(inspection:inspected).modules == program.modules,"inspection initializer preserves module snapshot")
            let source = try SceneAssetSource(rootURL:directory,limits:.init())
            if packaged { try source.useArchive("scene.pkg") }
            try check(try source.scriptModules(inlineByteCount:0) == source.scriptModules(inlineByteCount:0),"repeated enumeration is independent of directory offset")
            try check(try sourceBytes(directory) == before,"inspection and repeated module snapshots leave every source byte unchanged")
        }
        let legacy = try JSONDecoder().decode(SceneScriptProgram.self,from:Data("{\"bindings\":[],\"layers\":[]}".utf8))
        try check(legacy.modules.isEmpty,"legacy program without modules decodes safely")
        for packaged in [false,true] {
            let directory = try fresh()
            let url = try project(directory,scripted:false,packaged:packaged,extras:[("invalid.js",Data([0xff])),("large.js",Data(repeating:1,count:256*1024+1))])
            if !packaged { try fm.createSymbolicLink(atPath:directory.appendingPathComponent("escape").path,withDestinationPath:"/") }
            let inspected = try SceneWallpaperInspector.inspect(projectURL:url)
            try check(inspected.isRenderableSubset && inspected.scriptProgram == nil,"\(packaged ? "PKG" : "loose") static scene never scans or reads module candidates")
        }
        for (label,data) in [("invalid UTF-8",Data([0xff])),("NUL",Data([65,0,66])),("oversize",Data(repeating:65,count:256*1024+1))] {
            for packaged in [false,true] {
                let directory = try fresh()
                let url = try project(directory,scripted:true,packaged:packaged,extras:[("bad.js",data)])
                let result = try SceneWallpaperInspector.inspect(projectURL:url)
                try check(!result.isRenderableSubset && result.scriptProgram == nil && result.diagnostics.contains { $0.path == "SceneScript" },"\(packaged ? "PKG" : "loose") \(label) candidate gives explicit diagnostic")
            }
        }
        func inventory(_ entries: [(String,Data)], inline: Int = 0, packaged: Bool = false, limits: SceneReadLimits = .init()) throws -> [String:String] {
            let directory = try fresh()
            if packaged { try package(entries,at:directory.appendingPathComponent("scene.pkg")) }
            else { for (path,data) in entries { try write(directory,path,data) } }
            let source = try SceneAssetSource(rootURL:directory,limits:limits)
            if packaged { try source.useArchive("scene.pkg") }
            return try source.scriptModules(inlineByteCount:inline)
        }
        for packaged in [false,true] {
            try check(try inventory([("limit.js",Data(repeating:65,count:256*1024))],packaged:packaged).count == 1,"exact 256 KiB module accepted")
            try check(try inventory((0..<128).map { ("m\($0).js",Data()) },packaged:packaged).count == 128,"exact 128 modules accepted")
            try rejects("129 modules rejected") { _ = try inventory((0..<129).map { ("m\($0).js",Data()) },packaged:packaged) }
            try check(try inventory([("a.js",Data(repeating:65,count:256*1024))],inline:768*1024,packaged:packaged).count == 1,"inline plus modules exact one MiB accepted")
            try rejects("inline plus modules one MiB overflow rejected") { _ = try inventory([("a.js",Data(repeating:65,count:256*1024))],inline:768*1024+1,packaged:packaged) }
            try rejects("uppercase extension is not silently normalized") { _ = try inventory([("A.JS",valid)],packaged:packaged) }
            if packaged {
                try rejects("case alias modules rejected") { _ = try inventory([("a.js",valid),("A.js",valid)],packaged:true) }
                try rejects("directory case alias modules rejected") { _ = try inventory([("A/a.js",valid),("a/b.js",valid)],packaged:true) }
            }
            var limits = SceneReadLimits(); limits.maximumEntries = 2
            try rejects("bounded inventory counts irrelevant non-JS entries") { _ = try inventory([("a.txt",Data()),("b.txt",Data()),("c.txt",Data())],packaged:packaged,limits:limits) }
            try rejects("path depth above 32 rejected") { _ = try inventory([(Array(repeating:"a",count:32).joined(separator:"/")+"/x.js",valid)],packaged:packaged) }
            try check(try inventory([(Array(repeating:"a",count:31).joined(separator:"/")+"/x.js",valid)],packaged:packaged).count == 1,"exact 32 path components accepted")
        }
        let inflatedURL = try project(try fresh(),scripted:true,packaged:false,extras:[("a.js",Data(repeating:1,count:200_000)),("b.js",Data(repeating:1,count:200_000))])
        let inflated = try SceneWallpaperInspector.inspect(projectURL:inflatedURL)
        try check(inflated.scriptProgram == nil && inflated.diagnostics.contains { $0.path == "SceneScript" && $0.message.contains("2 MiB") },"JSON escaping cannot bypass encoded two MiB IPC guard")
        try check(try inventory((0..<20_000).map { ("f\($0).txt",Data()) },packaged:true).isEmpty,"default twenty-thousand-entry inventory boundary accepted")
        try rejects("default twenty-thousand-entry inventory overflow rejected") { _ = try inventory((0..<20_001).map { ("f\($0).txt",Data()) },packaged:true) }
        try rejects("PKG NFC alias rejected by archive index") { _ = try inventory([("é.js",valid),("e\u{301}.js",valid)],packaged:true) }
        try rejects("PKG traversal candidate cannot escape root") { _ = try inventory([("../outside.js",valid)],packaged:true) }
        let escapeRoot = try fresh(), outside = try fresh()
        try write(outside,"private.js",valid)
        try fm.createSymbolicLink(atPath:escapeRoot.appendingPathComponent("escape").path,withDestinationPath:outside.path)
        try rejects("loose symbolic-link directory is never followed") { _ = try SceneAssetSource(rootURL:escapeRoot,limits:.init()).scriptModules(inlineByteCount:0) }
        let leaf = try fresh()
        try fm.createSymbolicLink(atPath:leaf.appendingPathComponent("leaf.js").path,withDestinationPath:outside.appendingPathComponent("private.js").path)
        try rejects("loose symbolic-link file is never read") { _ = try SceneAssetSource(rootURL:leaf,limits:.init()).scriptModules(inlineByteCount:0) }
        let fifo = try fresh()
        guard mkfifo(fifo.appendingPathComponent("pipe.js").path,0o600) == 0 else { throw SceneWallpaperFailure(message:"mkfifo failed") }
        try rejects("FIFO module is rejected without blocking read") { _ = try SceneAssetSource(rootURL:fifo,limits:.init()).scriptModules(inlineByteCount:0) }
        print("SceneScriptModuleSnapshotTests: \(checks) passed; temporary sources only, no JavaScript execution")
    }
}
