import Foundation
import Metal

/// The engine's own Metal functions. The `.metal` files build into the OpenWallpaperEngine
/// framework's `default.metallib`, which the app and the Wallpaper Editor's app both load from the
/// framework (`MTLDevice.makeDefaultLibrary()` would look in the running app's bundle).
enum SceneMetalLibrary {
    // Research-only shared source library, equivalent to the original offline default.metallib.
    private static let researchLock = NSLock()
    nonisolated(unsafe) private static var researchLibraries: [UInt64: MTLLibrary] = [:]
    static func load(device: MTLDevice) throws -> MTLLibrary {
        if SceneBackendRuntimeContext.isActive {
            return try researchLock.withLock {
                if let library = researchLibraries[device.registryID] { return library }
                guard let sourceURL = AppBundleLayout.framework.url(forResource: "BackendBuiltins", withExtension: "metal.txt") else { throw SceneBackendFailure.notReady }
                let source = try String(contentsOf: sourceURL, encoding: .utf8)
                let library = try device.makeLibrary(source: source, options: nil)
                researchLibraries[device.registryID] = library
                return library
            }
        }
        return try device.makeDefaultLibrary(bundle: AppBundleLayout.framework)
    }
    /// The library, or nil (logged) when it can't be read.
    static func make(device: MTLDevice) -> MTLLibrary? {
        do {
            return try load(device: device)
        } catch {
            OWELog.error(.scene, "The engine's Metal library can't be loaded: \(error)")
            return nil
        }
    }
}
