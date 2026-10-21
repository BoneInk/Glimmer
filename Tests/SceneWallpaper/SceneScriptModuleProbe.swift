import CryptoKit
import Darwin
import Foundation

/// Independent black-box module regression. Every accepted program crosses the real
/// child-process transport and runs JavaScriptCore; this file contains no JS evaluator.
@main @MainActor
enum SceneScriptModuleProbe {
    struct ResultRow: Codable {
        let name: String
        let passed: Bool
        let assertions: Int
        let seconds: Double
        let error: String?
    }
    static var rows: [ResultRow] = []
    static var assertions = 0
    static var heartbeat = 0
    static var rejectionMessages: [String: String] = [:]
    static var timeoutSeconds: Double?
    static var worker: URL { URL(fileURLWithPath: CommandLine.arguments[1]) }

    static func check(_ value: Bool, _ name: String) throws {
        guard value else { throw SceneWallpaperFailure(message: name) }
        assertions += 1
    }
    static func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.000001 }
    static func layer(_ id: Int = 1) -> SceneScriptLayerState {
        .init(id: id, name: "layer\(id)", origin: .init(x: 0, y: 0, z: 0),
              angles: .init(x: 0, y: 0, z: 0), scale: .init(x: 1, y: 1, z: 1),
              size: .init(x: 10, y: 10), color: .init(x: 1, y: 1, z: 1), alpha: 1, visible: true)
    }
    static func binding(_ source: String, id: String = "entry", layerID: Int = 1,
                        target: String = "alpha") -> SceneScriptBindingSpec {
        .init(id: id, layerID: layerID, target: target, source: source,
              initialValue: .number(1), scriptProperties: [:], scriptPropertyBindings: [:])
    }
    static func program(_ source: String, modules: [String: String] = [:], target: String = "alpha",
                        extraBindings: [SceneScriptBindingSpec] = []) throws -> SceneScriptProgram {
        let base = SceneScriptProgram(bindings: [binding(source, target: target)] + extraBindings,
                                      layers: extraBindings.isEmpty ? [layer()] : [layer(), layer(2)])
        // Exercise the actual Codable wire contract without depending on init argument order.
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as! [String: Any]
        json["modules"] = modules
        return try JSONDecoder().decode(SceneScriptProgram.self,
            from: JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]))
    }
    static func withClient(_ body: (SceneScriptWorkerClient) async throws -> Void) async throws {
        let client = SceneScriptWorkerClient(executableURL: worker)
        do { try await body(client); await client.dispose() }
        catch { await client.dispose(); throw error }
    }
    static func configure(_ client: SceneScriptWorkerClient, _ source: String,
                          modules: [String: String] = [:], target: String = "alpha",
                          extraBindings: [SceneScriptBindingSpec] = []) async throws -> SceneScriptFrame {
        try await client.configure(program: program(source, modules: modules, target: target, extraBindings: extraBindings),
                                   userProperties: Data("{}".utf8))
    }
    static func alpha(_ source: String, modules: [String: String] = [:], equals expected: Double) async throws {
        try await withClient { client in
            let frame = try await configure(client, source, modules: modules)
            try check(near(frame.layers[0].alpha, expected), "expected alpha \(expected), got \(frame.layers[0].alpha)")
        }
    }
    static func reject(_ name: String, source: String, modules: [String: String] = [:], tdz: Bool = false) async throws {
        let fixture = try program(source, modules: modules)
        let client = SceneScriptWorkerClient(executableURL: worker)
        var message: String?
        do { _ = try await client.configure(program: fixture, userProperties: Data("{}".utf8)) }
        catch { message = error.localizedDescription }
        await client.dispose()
        try check(message != nil, "invalid module unexpectedly configured: " + name)
        try check(!message!.contains("断开连接") && !message!.contains("超时"),
                  "rejection must come from module validation, not a crashed/timed-out worker: " + message!)
        rejectionMessages[name] = message
        if tdz {
            let text = message!.lowercased()
            try check(text.contains("initializ") || text.contains("referenceerror") || text.contains("temporal") || text.contains("未初始化"),
                      "cycle must report an uninitialized/TDZ reference, not silently return undefined: " + message!)
        }
    }
    static func run(_ name: String, _ body: () async throws -> Void) async {
        let start = Date(), previous = assertions
        do {
            try await body()
            rows.append(.init(name: name, passed: true, assertions: assertions - previous,
                              seconds: Date().timeIntervalSince(start), error: nil))
        } catch {
            rows.append(.init(name: name, passed: false, assertions: assertions - previous,
                              seconds: Date().timeIntervalSince(start), error: error.localizedDescription))
        }
    }

    static func acceptedModules() async {
        await run("named/default/namespace imports and nested relative resolution") {
            try await alpha("""
            import read, { value as named } from './lib/entry.js';
            import * as ns from './lib/entry.js';
            export function init() { if (ns.value !== named || read() !== named) throw Error('link'); return named; }
            """, modules: ["lib/entry.js": "import { n } from './value.js'; export const value=n; export default function read(){return n;}",
                            "lib/value.js": "export const n=.25;"], equals: 0.25)
        }
        await run("mutable imported export let stays live across updates") {
            try await withClient { client in
                _ = try await configure(client, "import { n, bump } from './counter.js'; export function update(){bump(); return n/10;}",
                    modules: ["counter.js": "export let n=0; export function bump(){n++;}"])
                let one = try await client.step(runtime: 1, frameTime: 0.1)
                let two = try await client.step(runtime: 2, frameTime: 0.1)
                try check(near(one.layers[0].alpha, 0.1) && near(two.layers[0].alpha, 0.2), "imported n was snapshotted")
            }
        }
        await run("root export let remains mutable") {
            try await withClient { client in
                _ = try await configure(client, "export let count=0; export function update(){return ++count/10;}")
                let one = try await client.step(runtime: 1, frameTime: 0.1)
                let two = try await client.step(runtime: 2, frameTime: 0.1)
                try check(near(one.layers[0].alpha, 0.1) && near(two.layers[0].alpha, 0.2), "root export let lost local state")
            }
        }
        await run("shadowing/shorthand/template/regex/quoted export text preserve scope") {
            try await alpha(#"""
            import { value } from './value.js';
            const text = "import x from './missing.js'; export default value";
            const pattern = /export\s+default|import/;
            function shadow(value) { return { value }; }
            const template = `value=${value}; nested=${(() => { let value=9; return value; })()}`;
            export function init() {
              const object = { value }; const literal = { value: 7 };
              if (shadow(3).value !== 3 || object.value !== .2 || Object.keys(object)[0] !== 'value' || literal.value !== 7 ||
                  template !== 'value=0.2; nested=9' || !pattern.test(text) || !text.includes('export default value')) throw Error('rewritten literal/scope');
              return value;
            }
            """#, modules: ["value.js": "export const value=.2;"], equals: 0.2)
        }
        await run("imported call receiver is undefined rather than namespace") {
            try await alpha("import { receiver } from './receiver.js'; export function init(){return receiver();}",
                modules: ["receiver.js": "export function receiver(){return this === undefined ? .4 : .9;}"], equals: 0.4)
        }
        await run("default expression snapshots while export alias stays live") {
            let modules = ["snapshot.js": "let n=.2; export default n; export function bump(){n=.7;}",
                           "live.js": "let n=.2; export { n as default }; export function bump(){n=.7;}"]
            try await alpha("import n,{bump} from './snapshot.js'; export function init(){bump();return n;}", modules: modules, equals: 0.2)
            try await alpha("import n,{bump} from './live.js'; export function init(){bump();return n;}", modules: modules, equals: 0.7)
        }
        await run("default function shares mutable named export") {
            try await alpha("import read,{set} from './read.js'; export function init(){set();return read();}",
                modules: ["read.js": "export let n=.1; export default function read(){return n;} export function set(){n=.6;}"], equals: 0.6)
        }
        await run("anonymous default function and arrow preserve imported values") {
            try await alpha("import read from './read.js';export function init(){return read();}",
                modules: ["read.js": "import n from './value.js';export default function(){return n;}",
                          "value.js": "export default .35;"], equals: 0.35)
            try await alpha("import read from './read.js';export function init(){return read();}",
                modules: ["read.js": "export default ()=>.45;"], equals: 0.45)
        }
        await run("named and anonymous default classes preserve constructors and inner names") {
            try await alpha("import C from'./m.js';export function init(){return new C().value();}",
                modules: ["m.js": "export default class Named{value(){return Named===this.constructor ? .7 : .9;}}"], equals: 0.7)
            try await alpha("import C from'./m.js';export function init(){return new C().value();}",
                modules: ["m.js": "export default class{value(){return .75;}}"], equals: 0.75)
        }
        await run("anonymous default function is hoisted across cyclic dependencies") {
            try await alpha("import{result}from'./a.js';export function init(){return result;}", modules: [
                "a.js": "import{value}from'./b.js';export default function(){return .3;}export const result=value;",
                "b.js": "import f from'./a.js';export const value=f();"], equals: 0.3)
        }
        await run("named aliases/reexports/star/namespace reexport and quoted export names") {
            try await alpha("""
            import { alias, quoted, group } from './barrel.js';
            export function init(){if(group.x !== alias || quoted !== alias)throw Error('reexport');return alias;}
            """, modules: ["base.js": "const n=.3; export {n as x, n as 'odd-name'};",
                            "barrel.js": "export {x as alias, 'odd-name' as quoted} from './base.js'; export * as group from './base.js';"], equals: 0.3)
            try await alpha("import {x} from './star.js'; export function init(){return x;}",
                modules: ["base.js": "export const x=.4;", "star.js": "export * from './base.js';"], equals: 0.4)
        }
        await run("explicit named export resolves conflicting star names") {
            try await alpha("import{x}from'./barrel.js';export function init(){return x;}",
                modules: ["a.js": "export const x=.2;", "b.js": "export const x=.3;",
                          "barrel.js": "export * from './a.js';export * from './b.js';export {x} from './a.js';"], equals: 0.2)
        }
        await run("diamond star reexports of the same binding are unambiguous and live") {
            try await alpha("import{x,bump}from'./barrel.js';export function init(){bump();return x;}", modules: [
                "base.js": "export let x=.1;export function bump(){x=.65;}",
                "a.js": "export * from './base.js';", "b.js": "export * from './base.js';",
                "barrel.js": "export * from './a.js';export * from './b.js';"], equals: 0.65)
        }
        await run("star excludes default and unused conflicting names") {
            try await alpha("import*as ns from'./barrel.js';export function init(){if('default'in ns||'x'in ns)throw Error('star leaked default/ambiguous name');return ns.y;}", modules: [
                "a.js": "export default .9;export const x=.1;export const y=.4;", "b.js": "export const x=.2;",
                "barrel.js": "export * from './a.js';export * from './b.js';"], equals: 0.4)
        }
        await run("namespace imported values stay live") {
            try await alpha("import*as ns from'./m.js';export function init(){ns.bump();return ns.value;}",
                modules: ["m.js": "export let value=.1;export function bump(){value=.55;}"], equals: 0.55)
        }
        await run("module top-level this is undefined") {
            try await alpha("import value from'./m.js';export function init(){return value;}",
                modules: ["m.js": "export default this===undefined ? .6 : .9;"], equals: 0.6)
        }
        await run("cycles allow hoisted exported functions") {
            try await alpha("import{a}from'./a.js';export function init(){return a(2)/10;}", modules: [
                "a.js": "import{b}from'./b.js';export function a(n){return n ? b(n-1) : 2;}",
                "b.js": "import{a}from'./a.js';export function b(n){return n ? a(n-1) : 3;}"], equals: 0.2)
        }
        await run("side effect import and duplicate import evaluate once per binding") {
            try await alpha("import './side.js';import {n} from './side.js';import * as ns from './side.js';export function init(){if(n!==ns.n)throw Error('identity');return thisLayer.alpha;}",
                modules: ["side.js": "thisLayer.alpha /= 2;export const n=1;"], equals: 0.5)
        }
        await run("diamond dependency side effect executes once") {
            try await alpha("import './a.js';import './b.js';export function init(){return thisLayer.alpha;}", modules: [
                "a.js": "import './side.js';", "b.js": "import './side.js';", "side.js": "thisLayer.alpha /= 2;"], equals: 0.5)
        }
        await run("unreferenced module is not evaluated") {
            try await alpha("export function init(){return .4;}", modules: ["unused.js": "while(true){}"], equals: 0.4)
        }
        await run("module cache is isolated per binding") {
            try await withClient { client in
                let source = "import{next}from'./counter.js';export function init(){return next()/10;}"
                let frame = try await configure(client, source, modules: ["counter.js": "let n=0;export function next(){return ++n;}"],
                    extraBindings: [binding(source, id: "second", layerID: 2)])
                try check(frame.layers.count == 2 && frame.layers.allSatisfy { near($0.alpha, 0.1) }, "bindings shared module singleton state")
            }
        }
        await run("module cache is isolated per runtime and reset on reconfigure") {
            let a = SceneScriptWorkerClient(executableURL: worker), b = SceneScriptWorkerClient(executableURL: worker)
            do {
                let source = "import{next}from'./counter.js';export function init(){return next()/10;}export function update(){return next()/10;}"
                let modules = ["counter.js": "let n=0;export function next(){return ++n;}"]
                let af = try await configure(a, source, modules: modules), bf = try await configure(b, source, modules: modules)
                let a2 = try await a.step(runtime: 1, frameTime: 0.1), b2 = try await b.step(runtime: 1, frameTime: 0.1)
                let reset = try await configure(a, source, modules: modules)
                try check(near(af.layers[0].alpha, 0.1) && near(bf.layers[0].alpha, 0.1) && near(a2.layers[0].alpha, 0.2) && near(b2.layers[0].alpha, 0.2) && near(reset.layers[0].alpha, 0.1), "runtime/reconfigure state leaked")
                await a.dispose(); await b.dispose()
            } catch { await a.dispose(); await b.dispose(); throw error }
        }
    }

    static func builtins() async {
        await run("WEMath named/namespace imports change actual alpha and position") {
            try await withClient { client in
                let frame = try await configure(client, """
                import * as M from 'WEMath'; import {mix, smoothStep} from 'WEMath';
                export function init(){if(Math.abs(M.deg2rad*180-Math.PI)>1e-9 || Math.abs(M.rad2deg*Math.PI-180)>1e-9)throw Error('angle constants');thisLayer.origin=new Vec3(mix(2,6,.5),0,0);return smoothStep(0,1,.5);}
                """)
                try check(near(frame.layers[0].alpha, 0.5) && near(frame.layers[0].origin.x, 4), "WEMath numerical layer result")
            }
        }
        await run("WEColor normalized conversions preserve Vec3 identity and layer color") {
            try await withClient { client in
                let frame = try await configure(client, """
                import * as C from 'WEColor';
                export function init(){let green=C.hsv2rgb(new Vec3(1/3,1,1));let blueHSV=C.rgb2hsv(new Vec3(0,0,1));let normalized=C.normalizeColor(new Vec3(255,128,0));let expanded=C.expandColor(normalized);if(!(green instanceof Vec3)||!(blueHSV instanceof Vec3)||!(normalized instanceof Vec3)||!(expanded instanceof Vec3)||Math.abs(blueHSV.x-2/3)>1e-6||expanded.y!==128)throw Error('color identity/math');return green;}
                """, target: "color")
                try check(near(frame.layers[0].color.x, 0) && near(frame.layers[0].color.y, 1) && near(frame.layers[0].color.z, 0), "WEColor did not produce green layer")
            }
        }
        await run("WEVector degree conversions preserve Vec2 identity and layer size") {
            try await withClient { client in
                let frame = try await configure(client, """
                import * as V from 'WEVector';
                export function init(){let d=V.angleVector2(90);if(!(d instanceof Vec2)||Math.abs(V.vectorAngle2(new Vec2(0,1))-90)>1e-6)throw Error('vector identity/math');return d.copy().multiply(10).add(new Vec2(20,20));}
                """, target: "size")
                try check(near(frame.layers[0].size.x, 20) && near(frame.layers[0].size.y, 30), "WEVector did not change actual size")
            }
        }
    }

    static func rejectedModules() async {
        let cases: [(String, String, [String: String])] = [
            ("missing module", "import './missing.js';", [:]),
            ("unknown builtin", "import * as X from 'WENotReal';", [:]),
            ("known unsupported cursor event", "export function cursorMove(){}", [:]),
            ("unknown builtin named export", "import {notAnAPI} from 'WEMath';", [:]),
            ("missing named export even unused", "import {missing} from './m.js';", ["m.js": "export const present=1;"]),
            ("missing default export", "import missing from './m.js';", ["m.js": "export const present=1;"]),
            ("conflicting star exports", "import{x}from'./barrel.js';", ["a.js":"export const x=.1;","b.js":"export const x=.2;","barrel.js":"export * from './a.js';export * from './b.js';"]),
            ("import assignment even in unused function", "import{n}from'./m.js';export function unused(){n=2;}", ["m.js":"export let n=1;"]),
            ("import postfix write", "import{n}from'./m.js';export function init(){n++;return .5;}", ["m.js":"export let n=1;"]),
            ("import destructuring write", "import{n}from'./m.js';export function init(){({x:n}={x:2});return .5;}", ["m.js":"export let n=1;"]),
            ("readonly namespace assignment", "import*as ns from'./m.js';export function init(){ns.n=2;return .5;}", ["m.js":"export let n=1;"]),
            ("readonly namespace deletion", "import*as ns from'./m.js';export function init(){delete ns.n;return .5;}", ["m.js":"export let n=1;"]),
            ("readonly builtin namespace", "import*as M from'WEMath';export function init(){M.mix=1;return .5;}", [:]),
            ("root traversal", "import{n}from'../escape.js';export function init(){return n;}", ["../escape.js":"export const n=.2;"]),
            ("absolute module path", "import{n}from'/escape.js';export function init(){return n;}", ["/escape.js":"export const n=.2;"]),
            ("URL module path", "import{n}from'https://example.invalid/a.js';export function init(){return n;}", ["https://example.invalid/a.js":"export const n=.2;"]),
            ("file URL module path", "import{n}from'file:///private/tmp/secret.js';export function init(){return n;}", ["file:///private/tmp/secret.js":"export const n=.2;"]),
            ("NUL module path", "import{n}from'./ok.js\\u0000tail';export function init(){return n;}", ["ok.js\0tail":"export const n=.2;"]),
            ("dynamic import", "export function init(){import('./m.js');return .5;}", ["m.js":"export const n=1;"]),
            ("top-level await", "await Promise.resolve();export function init(){return .5;}", [:])
        ]
        for (name, source, modules) in cases {
            await run("reject " + name) { try await reject(name, source: source, modules: modules) }
        }
        await run("cyclic let access reports temporal dead zone") {
            try await reject("cycle TDZ", source: "import{a}from'./a.js';export function init(){return a;}",
                modules: ["a.js":"import{b}from'./b.js';export const a=b+1;", "b.js":"import{a}from'./a.js';export const b=a+1;"], tdz: true)
        }
        await run("infinite module configure has bounded timeout and responsive MainActor") {
            let client = SceneScriptWorkerClient(executableURL: worker), start = Date(), ticks = heartbeat
            var failureMessage: String?
            do { _ = try await configure(client, "import './loop.js';", modules: ["loop.js":"while(true){}"])}
            catch { failureMessage = error.localizedDescription }
            timeoutSeconds = Date().timeIntervalSince(start)
            await client.dispose()
            try check(failureMessage != nil, "infinite module unexpectedly returned success")
            try check(failureMessage!.contains("超时"), "infinite module must hit the execution deadline: " + failureMessage!)
            try check(timeoutSeconds! < 4.5, "infinite module exceeded configure deadline: \(timeoutSeconds!)")
            try check(heartbeat > ticks + 10, "module evaluation blocked MainActor")
            rejectionMessages["infinite module"] = failureMessage
        }
    }

    static func ownChildren() throws -> Set<Int32> {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,comm="]
        process.standardOutput = output
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        return Set(String(decoding: bytes, as: UTF8.self).split(separator: "\n").compactMap { line in
            let values = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard values.count >= 3, Int32(values[1]) == getpid(),
                  values.dropFirst(2).joined(separator: " ").hasSuffix("GlimmerSceneScriptWorker") else { return nil }
            return Int32(values[0])
        })
    }
    static func main() async {
        let ticker = Task { while !Task.isCancelled { heartbeat += 1; try? await Task.sleep(for: .milliseconds(5)) } }
        await run("real worker executable exists") { try check(FileManager.default.isExecutableFile(atPath: worker.path), "missing real worker") }
        await acceptedModules(); await builtins(); await rejectedModules()
        await run("all probe-owned worker processes are reaped") {
            for _ in 0..<100 {
                if try ownChildren().isEmpty { try check(true, "no own helper remains"); return }
                try await Task.sleep(for: .milliseconds(10))
            }
            try check(false, "probe-owned worker remains")
        }
        ticker.cancel()
        let failed = rows.filter { !$0.passed }
        do {
            let hash = try Data(contentsOf: worker)
            let report: [String: Any] = [
                "passed": failed.isEmpty, "caseCount": rows.count, "assertionCount": assertions,
                "failures": failed.map { ["name": $0.name, "error": $0.error ?? "unknown"] },
                "results": try JSONSerialization.jsonObject(with: JSONEncoder().encode(rows)),
                "rejectionMessages": rejectionMessages, "heartbeatTicks": heartbeat,
                "infiniteModuleSeconds": timeoutSeconds as Any? ?? NSNull(),
                "workerSHA256": SHA256.hash(data: hash).map { String(format: "%02x", $0) }.joined(),
                "mode": "Real child IPC + production worker JavaScriptCore; in-memory modules, no GUI/project-file/network access or renderer simulation/production settings mutation",
                "moduleContract": "Normalized in-memory project-root modules; each binding/runtime owns its module cache",
                "primaryReferences": [
                    "https://docs.wallpaperengine.io/en/scene/scenescript/reference/module/WEMath.html",
                    "https://docs.wallpaperengine.io/en/scene/scenescript/reference/module/WEColor.html",
                    "https://docs.wallpaperengine.io/en/scene/scenescript/reference/module/WEVector.html"
                ]
            ]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
            print(String(decoding: data, as: UTF8.self))
        } catch { fputs("Failed to write module regression report: \(error)\n", stderr); exit(2) }
        exit(failed.isEmpty ? 0 : 1)
    }
}
