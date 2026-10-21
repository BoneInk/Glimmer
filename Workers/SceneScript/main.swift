import Foundation
import JavaScriptCore
import Darwin

// The app can exit while JavaScript is busy and cannot read stdin EOF. A native
// background watchdog prevents an unresponsive script from outliving its owner.
let ownerPID = getppid()
guard ownerPID > 1 else { exit(76) }
let ownerWatch = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
ownerWatch.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
ownerWatch.setEventHandler { @Sendable in
    if getppid() != ownerPID { _exit(76) }
}
ownerWatch.resume()

// No native filesystem, network, Objective-C objects or credentials are exposed
// to user JavaScript. The parent owns wall-time deadlines and kills this process.
var noCore = rlimit(rlim_cur: 0, rlim_max: 0)
_ = setrlimit(RLIMIT_CORE, &noCore)
var files = rlimit(rlim_cur: 32, rlim_max: 32)
_ = setrlimit(RLIMIT_NOFILE, &files)
guard let context = JSContext() else { exit(70) }
context.exceptionHandler = { _, _ in }
context.evaluateScript(SceneScriptEngineSource.acorn)
guard context.exception == nil else { exit(71) }
context.evaluateScript("var GWSceneScriptScope = " + SceneScriptEngineSource.scope + ";\nvar GWSceneScriptModules = " + SceneScriptEngineSource.modules + ";\nvar GWSceneScriptHierarchy = " + SceneScriptEngineSource.hierarchy + ";\nvar GWSceneScriptBuiltins = " + SceneScriptEngineSource.builtins + ";")
guard context.exception == nil, let rpc = context.evaluateScript(SceneScriptEngineSource.engine),
      context.exception == nil, !rpc.isUndefined else { exit(71) }
while let line = readLine() {
    if line.utf8.count > 2_097_152 { exit(72) }
    autoreleasepool {
        do {
            let bytes = Data(line.utf8)
            guard let request = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { exit(73) }
            context.exception = nil
            guard let result = rpc.call(withArguments: [request]), context.exception == nil,
                  let string = result.toString(), string.utf8.count <= 524_287 else { exit(74) }
            try FileHandle.standardOutput.write(contentsOf: Data((string + "\n").utf8))
        } catch { exit(75) }
    }
}
