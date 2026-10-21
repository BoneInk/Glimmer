import Foundation

/// The user properties of every running wallpaper instance, their music-synced modulation and the
/// per-frame snapshot the render loop reads them from. Owned by `WallpaperServices`.
final class SceneUserPropertyService {
    /// Guards every stored property. `frameSnapshot` is the rendering thread's own (`FrameSlot`).
    private let levelLock = NSLock()
    /// The current system audio level, used by music-synced properties.
    private let audioLevel: () -> Double
    private var level: Double { audioLevel() }
    /// Per-wallpaper user properties (guarded by `levelLock`). `userPropertyStrings` and
    /// `globalValues` are views of the active wallpaper's entry.
    private var propertyStores = SceneUserPropertyStores()
    private var globalValues: [String: Double] {
        get { propertyStores.active.numbers }
        set { propertyStores.active.numbers = newValue }
    }
    private var userPropertyStrings: [String: String] {
        get { propertyStores.active.strings }
        set { propertyStores.active.strings = newValue }
    }
    /// Per store: the pending change notification and the keys it reports (guarded by `levelLock`).
    private var propertyNotificationWorkItems: [String: DispatchWorkItem] = [:]
    private var pendingChangedKeys: [String: Set<String>] = [:]
    /// Bumped at once by every change to any store (guarded by `levelLock`): what a frame compares
    /// to see a change before the batched notification arrives.
    private var changeRevision: UInt64 = 0

    var revision: UInt64 {
        levelLock.lock()
        defer { levelLock.unlock() }
        return changeRevision
    }

    init(audioLevel: @escaping () -> Double) {
        self.audioLevel = audioLevel
    }

    /// Sets the user properties of one wallpaper instance (keyed by its store key,
    /// `WallpaperPropertyScope.runtimeKey`). With `replacing`, properties missing from `values` are
    /// dropped, so nothing from a previous configuration of that wallpaper lingers. A burst of
    /// changes to one store is reported once, with every key it changed, and the store it changed
    /// (`"wallpaper"`), so only the instances running that store react.
    func setUserProperties(_ values: [String: String], wallpaper: String, replacing: Bool) {
        levelLock.lock()
        let changedKeys = propertyStores.set(values, for: wallpaper, replacing: replacing)
        if !changedKeys.isEmpty { changeRevision &+= 1 }
        if frameSnapshot == nil { propertyStores.activeKey = wallpaper }
        pendingChangedKeys[wallpaper, default: []].formUnion(changedKeys)
        propertyNotificationWorkItems[wallpaper]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.levelLock.lock()
            let keys = Array(self.pendingChangedKeys.removeValue(forKey: wallpaper) ?? [])
            self.propertyNotificationWorkItems[wallpaper] = nil
            self.levelLock.unlock()
            NotificationCenter.default.post(name: .sceneUserPropertiesDidChange, object: nil,
                                            userInfo: ["keys": keys, "wallpaper": wallpaper])
        }
        propertyNotificationWorkItems[wallpaper] = work
        levelLock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    // MARK: - Frame snapshot

    /// Copy of the property state the render loop reads. Taken once per frame so per-layer reads
    /// stop contending with the audio thread. Dictionaries are copy-on-write so taking it is cheap.
    struct FrameSnapshot {
        var globalValues: [String: Double]
        var userPropertyStrings: [String: String]
        var level: Double
    }

    /// One thread's frame snapshot. Every wallpaper instance renders on a thread of its own
    /// (`SceneRenderThread`), and two instances (two displays' stores, or an isolated edit
    /// session's private instance beside the desktop's) render at once: each frame reads the
    /// snapshot its own thread took, never one another thread took or cleared meanwhile.
    private final class FrameSlot {
        var owner: ObjectIdentifier?
        var snapshot: FrameSnapshot?
    }

    private static let frameSlotKey: pthread_key_t = {
        var key = pthread_key_t()
        pthread_key_create(&key) { Unmanaged<FrameSlot>.fromOpaque($0).release() }
        return key
    }()

    /// This thread's frame snapshot of this service; nil outside a frame.
    private var frameSnapshot: FrameSnapshot? {
        get {
            guard let raw = pthread_getspecific(Self.frameSlotKey) else { return nil }
            let slot = Unmanaged<FrameSlot>.fromOpaque(raw).takeUnretainedValue()
            return slot.owner == ObjectIdentifier(self) ? slot.snapshot : nil
        }
        set {
            let slot: FrameSlot
            if let raw = pthread_getspecific(Self.frameSlotKey) {
                slot = Unmanaged<FrameSlot>.fromOpaque(raw).takeUnretainedValue()
            } else {
                guard newValue != nil else { return }
                slot = FrameSlot()
                pthread_setspecific(Self.frameSlotKey, Unmanaged.passRetained(slot).toOpaque())
            }
            slot.owner = ObjectIdentifier(self)
            slot.snapshot = newValue
        }
    }

    /// The audio level captured with the current frame's snapshot; nil outside a frame.
    var frameAudioLevel: Double? { frameSnapshot?.level }

    /// Starts a frame of `wallpaper` (its directory path): reads until `endFrame` see that
    /// wallpaper's user properties.
    func beginFrame(wallpaper: String) {
        levelLock.lock()
        propertyStores.activeKey = wallpaper
        frameSnapshot = FrameSnapshot(globalValues: globalValues,
                                      userPropertyStrings: userPropertyStrings,
                                      level: level)
        levelLock.unlock()
    }

    func endFrame() {
        frameSnapshot = nil
    }

    private func modulatedValue(_ key: String, fallback: Double, in snapshot: FrameSnapshot) -> Double {
        let base = snapshot.globalValues[key] ?? fallback
        guard !key.hasSuffix("_musicSync"), !key.hasSuffix("_musicAmount"),
              snapshot.userPropertyStrings["\(key)_musicSync"] == "true" else { return base }
        let amount = snapshot.globalValues["\(key)_musicAmount"] ?? 0
        guard abs(amount) > 0.0001 else { return base }
        return base + snapshot.level * amount
    }

    func userPropertyValue(_ key: String, fallback: Float) -> Float {
        if let frameSnapshot {
            return Float(modulatedValue(key, fallback: Double(fallback), in: frameSnapshot))
        }
        OWEFrameMetrics.countLockAcquisition()
        levelLock.lock()
        defer { levelLock.unlock() }
        return Float(modulatedValueLocked(key, fallback: Double(fallback)))
    }

    private func modulatedValueLocked(_ key: String, fallback: Double = 0) -> Double {
        let base = globalValues[key] ?? fallback
        guard !key.hasSuffix("_musicSync"), !key.hasSuffix("_musicAmount"),
              userPropertyStrings["\(key)_musicSync"] == "true" else { return base }
        let amount = globalValues["\(key)_musicAmount"] ?? 0
        guard abs(amount) > 0.0001 else { return base }
        return base + level * amount
    }

    func isMusicSynced(_ key: String) -> Bool {
        if let frameSnapshot { return frameSnapshot.userPropertyStrings["\(key)_musicSync"] == "true" }
        OWEFrameMetrics.countLockAcquisition()
        levelLock.lock()
        defer { levelLock.unlock() }
        return userPropertyStrings["\(key)_musicSync"] == "true"
    }

    func userPropertyString(_ key: String) -> String? {
        if let frameSnapshot { return frameSnapshot.userPropertyStrings[key] }
        OWEFrameMetrics.countLockAcquisition()
        levelLock.lock()
        defer { levelLock.unlock() }
        return userPropertyStrings[key]
    }

    /// One wallpaper instance's property, independent of which wallpaper is being rendered.
    func userPropertyString(_ key: String, wallpaper: String) -> String? {
        levelLock.lock()
        defer { levelLock.unlock() }
        return propertyStores.entry(for: wallpaper).strings[key]
    }

    /// Every user property of one wallpaper instance.
    func userProperties(wallpaper: String) -> [String: String] {
        levelLock.lock()
        defer { levelLock.unlock() }
        return propertyStores.entry(for: wallpaper).strings
    }
}
