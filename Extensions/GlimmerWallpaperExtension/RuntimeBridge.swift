// Adapted from Phosphene, copyright (c) 2026 kageroumado. MIT; see ThirdParty/Phosphene-LICENSE.txt.
import Foundation
import IOSurface

/// Construct a WallpaperRemoteContextXPC wrapping the given CAContext ID.
/// The verified class has a runtime-discovered `box` ivar containing a
/// WallpaperExtensionRemoteContext with a single UInt32 remoteContextID.
func createRemoteContextXPC(contextId: UInt32) -> AnyObject? {
    guard let realClass = objc_getClass("WallpaperRemoteContextXPC") as? AnyClass,
          let raw = class_createInstance(realClass, 0) else {
        GWLog("  ERROR: Could not create WallpaperRemoteContextXPC")
        return nil
    }

    let obj = raw as AnyObject
    let ptr = Unmanaged.passUnretained(obj).toOpaque()
    guard let ivar = class_getInstanceVariable(realClass, "box") else { return nil }
    let ivarOffset = ivar_getOffset(ivar)
    // Bounds-check before the raw write: if the runtime layout shrank or the
    // offset assumption is stale, writing past the instance would corrupt the
    // heap. Fail closed instead.
    guard ivarOffset >= 0,
          ivarOffset + MemoryLayout<UInt32>.size <= class_getInstanceSize(realClass) else {
        GWLog("  ERROR: WallpaperRemoteContextXPC layout unexpected (offset \(ivarOffset), size \(class_getInstanceSize(realClass)))")
        return nil
    }
    ptr.advanced(by: ivarOffset).storeBytes(of: contextId, as: UInt32.self)
    GWLog("  Created WallpaperRemoteContextXPC (contextId: \(contextId), offset: \(ivarOffset))")
    return obj
}

/// Construct a WallpaperSnapshotXPC wrapping the given IOSurface.
/// The real class has a single `rawValue` ivar at offset 8 containing
/// a WallpaperSnapshot struct (8 bytes = IOSurface refcounted pointer).
func createSnapshotXPC(surface: IOSurface) -> AnyObject? {
    guard let snapshotXPCClass = objc_getClass("WallpaperSnapshotXPC") as? AnyClass,
          let instance = class_createInstance(snapshotXPCClass, 0) else {
        GWLog("  [Snapshot] Failed to create WallpaperSnapshotXPC")
        return nil
    }

    // Require the actual rawValue ivar and bounds-check it. Unknown runtime layouts
    // are rejected rather than guessing an offset into an Objective-C instance.
    guard let ivar = class_getInstanceVariable(snapshotXPCClass, "rawValue") else { return nil }
    let snapshotOffset = ivar_getOffset(ivar)
    guard snapshotOffset + MemoryLayout<UnsafeRawPointer>.size <= class_getInstanceSize(snapshotXPCClass) else {
        GWLog("  [Snapshot] WallpaperSnapshotXPC layout unexpected (size \(class_getInstanceSize(snapshotXPCClass)))")
        return nil
    }

    let surfaceRef = Unmanaged.passRetained(surface).toOpaque()
    let instancePtr = Unmanaged.passUnretained(instance as AnyObject).toOpaque()
    instancePtr.advanced(by: snapshotOffset).storeBytes(of: surfaceRef, as: UnsafeRawPointer.self)
    return instance as AnyObject
}
