import Foundation
import JavaScriptCore

/// WP5 of docs/scenescript-plan.md: `engine.registerAudioBuffers(resolution)`, as scenescript64.dll
/// does it (`0x181655170`):
///
/// - The first registration in a scene allocates nine arrays, left/right/average at 16, 32 and 64
///   bands, owned natively (`0x181655347`–`0x1816553ca`). The DLL's tick copies the host's spectrum
///   into them before timers and `update` (`0x18164f84d`); here `willRunFrame` does.
/// - Every call wraps them in new `ArrayBuffer`s with a no-op deleter (`0x1800193c0`): each
///   registration has its own `Float32Array`s over the same memory. Scripts see each other's writes
///   until the next refill, as in WE, and detaching one registration's buffer (`transfer()`)
///   touches neither the others nor the memory, which only this extension frees.
///
/// The values are WE's spectrum (`AudioSpectrumAnalyzer`, which also feeds the shaders'
/// `g_AudioSpectrum*`). Confined to the runtime's thread, like the runtime.
final class SceneScriptAudioBuffersExtension: SceneScriptRuntimeExtension {
    /// `engine.AUDIO_RESOLUTION_16/32/64`; WE has no other ("Resolution must be either 16, 32 or 64.").
    static let resolutions = [16, 32, 64]
    /// left, right, average.
    static let channelCount = 3

    let scriptResources = ["sceneScriptAudioBuffers"]

    private let spectrum: () -> AudioSpectrumSnapshot
    private let count = SceneScriptAudioBuffersExtension.resolutions.reduce(0, +) * SceneScriptAudioBuffersExtension.channelCount
    private let storage: UnsafeMutablePointer<Float>

    /// `spectrum` returns the current frame's arrays; the renderer advances its own spectrum clock
    /// once per frame (`AudioSpectrumClock`) and this only reads.
    private let acquireCapture: () -> AudioCaptureLease?
    private var captureLease: AudioCaptureLease?

    init(spectrum: @escaping () -> AudioSpectrumSnapshot,
         acquireCapture: @escaping () -> AudioCaptureLease? = { WallpaperServices.shared.acquireAudioCapture() }) {
        self.spectrum = spectrum
        self.acquireCapture = acquireCapture
        storage = UnsafeMutablePointer<Float>.allocate(capacity: count)
        storage.initialize(repeating: 0, count: count)
    }

    /// No script runs once the runtime that owns this extension is gone, and the typed arrays'
    /// deallocator does nothing, so freeing here is the only free.
    deinit {
        storage.deallocate()
    }

    func install(into runtime: SceneScriptRuntime) throws {
        guard let native = runtime.rt.forProperty("native"), native.isObject else {
            throw SceneScriptRuntime.CreationError(description: "runtime.js has no __rt.native")
        }
        let makeArray: @convention(block) (Int, Int) -> JSValue? = { [weak self] resolution, channel in
            guard let context = JSContext.current() else { return nil }
            return self?.makeArray(resolution: resolution, channel: channel, in: context)
        }
        native.setValue(unsafeBitCast(makeArray, to: AnyObject.self), forProperty: "audioBuffer")
    }

    func willRunFrame(_ runtime: SceneScriptRuntime, deltaTime: Double) {
        let snapshot = spectrum()
        for resolution in Self.resolutions {
            fill(resolution: resolution, channel: 0, with: snapshot.values(bands: resolution, right: false))
            fill(resolution: resolution, channel: 1, with: snapshot.values(bands: resolution, right: true))
            fill(resolution: resolution, channel: 2, with: snapshot.averages(bands: resolution))
        }
    }

    /// Where a resolution's channel starts in `storage`, or nil for a resolution WE doesn't have.
    private func offset(resolution: Int, channel: Int) -> Int? {
        guard let index = Self.resolutions.firstIndex(of: resolution), (0..<Self.channelCount).contains(channel) else {
            return nil
        }
        let before = Self.resolutions[..<index].reduce(0, +) * Self.channelCount
        return before + channel * resolution
    }

    /// A new `Float32Array` over one channel of `storage`, whose deallocator does nothing.
    private func makeArray(resolution: Int, channel: Int, in context: JSContext) -> JSValue? {
        guard let offset = offset(resolution: resolution, channel: channel),
              let contextRef = context.jsGlobalContextRef else { return nil }
        // A registration keeps system audio capture on for as long as the runtime lives.
        if captureLease == nil { captureLease = acquireCapture() }
        let noDeallocation: JSTypedArrayBytesDeallocator = { _, _ in }
        var exception: JSValueRef?
        guard let object = JSObjectMakeTypedArrayWithBytesNoCopy(
            contextRef, kJSTypedArrayTypeFloat32Array, storage + offset, resolution * MemoryLayout<Float>.stride,
            noDeallocation, nil, &exception), exception == nil else { return nil }
        return JSValue(jsValueRef: object, in: context)
    }

    /// Copies `values` into a channel; a missing or short array leaves zeros.
    private func fill(resolution: Int, channel: Int, with values: [Float]?) {
        guard let offset = offset(resolution: resolution, channel: channel) else { return }
        let values = values ?? []
        for index in 0..<resolution {
            storage[offset + index] = index < values.count ? values[index] : 0
        }
    }
}
