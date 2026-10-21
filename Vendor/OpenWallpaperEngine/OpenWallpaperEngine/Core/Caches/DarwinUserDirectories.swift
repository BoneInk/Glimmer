import Darwin
import Foundation

/// The per-user folders macOS gives a process under `/var/folders` (`confstr`'s
/// `_CS_DARWIN_USER_CACHE_DIR` and `_CS_DARWIN_USER_TEMP_DIR`). Metal keeps its shader cache there,
/// in `<cache dir>/<bundle id>/com.apple.metal` (`MetalShaderCache`), so every process with the
/// app's bundle id shares one: the user's copy, every Dev build, each test host and each isolated
/// copy.
///
/// An isolated copy (`AppStorageLocation.isIsolated`: a test host, `OWE_ISOLATED_STATE`) moves
/// both folders into a subfolder of its own with libSystem's `_set_user_dir_suffix`, the call
/// WebKit's and other system helpers make for the same reason. After it, `confstr` (which Metal,
/// `NSTemporaryDirectory` and `FileManager.temporaryDirectory` read) answers
/// `<cache dir>/<suffix>/` and `<temp dir>/<suffix>/`, so Metal writes
/// `<cache dir>/<suffix>/<bundle id>/com.apple.metal` and never the user's cache. It must run before
/// anything creates a Metal device or compiles a shader, which is why `AppMain` calls it first.
/// `_set_user_dir_suffix` is not in the SDK's headers but is exported by `libsystem_coreservices`
/// (listed in the SDK's `.tbd`), so it is looked up at run time; without it the copy logs an
/// error and keeps the shared folders.
enum DarwinUserDirectories {
    /// The suffix an isolated copy's folders get: `app.openwallpaperengine.isolated.<tag>`.
    static func suffix(isolationTag: String) -> String {
        "\(AppStorageLocation.realBundleIdentifier).isolated.\(isolationTag)"
    }

    /// `<cache dir>/`, as Metal sees it now; nil when macOS doesn't answer.
    static var cacheDirectory: URL? { directory(_CS_DARWIN_USER_CACHE_DIR) }

    /// Moves this process's cache and temporary folders into their isolated subfolder when
    /// `location` is isolated. Returns whether it did.
    @discardableResult
    static func isolate(for location: AppStorageLocation) -> Bool {
        guard let tag = location.isolationTag else { return false }
        typealias SetSuffix = @convention(c) (UnsafePointer<CChar>) -> Bool
        // Optional: dlsym's own handle for the symbols this process has loaded.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_set_user_dir_suffix") else {
            OWELog.error(.app, "This macOS has no _set_user_dir_suffix: the isolated copy \(tag) shares the app's Metal shader cache")
            return false
        }
        let setSuffix = unsafeBitCast(symbol, to: SetSuffix.self)
        let suffix = suffix(isolationTag: tag)
        guard suffix.withCString({ setSuffix($0) }) else {
            OWELog.error(.app, "Could not move the isolated copy \(tag)'s cache folder to \(suffix): it shares the app's Metal shader cache")
            return false
        }
        return true
    }

    private static func directory(_ name: Int32) -> URL? {
        let length = confstr(name, nil, 0)
        guard length > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: length)
        guard confstr(name, &buffer, length) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
    }
}
