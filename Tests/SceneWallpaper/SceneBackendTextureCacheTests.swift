import AppKit
import Darwin
import IOSurface
import Metal

@main @MainActor enum SceneBackendTextureCacheTests {
    struct Failure: Error { let message: String }
    static func check(_ value: Bool, _ name: String) throws {
        guard value else { throw Failure(message: name) }
        print("PASS \(name)"); fflush(stdout)
    }

    static func surface(width: Int = 64, height: Int = 32, extraRowBytes: Int = 0,
                        format: UInt32 = 0x4247_5241) throws -> IOSurface {
        let row = ((width * 4 + 255) & ~255) + extraRowBytes
        let properties: [String: Any] = [
            kIOSurfaceWidth as String: width, kIOSurfaceHeight as String: height,
            kIOSurfaceBytesPerRow as String: row, kIOSurfacePixelFormat as String: format
        ]
        guard let result = IOSurfaceCreate(properties as CFDictionary) else {
            throw Failure(message: "IOSurface allocation failed")
        }
        return result
    }

    static func token(_ surface: IOSurface, session: UUID, generation: UInt64 = 1,
                      slot: UUID, sequence: UInt64 = 1, width: Int? = nil, height: Int? = nil,
                      row: Int? = nil, format: String = "BGRA8Unorm") -> SceneFrameToken {
        SceneFrameToken(sessionID: session, generation: generation, sequence: sequence, slotID: slot,
                        width: width ?? IOSurfaceGetWidth(surface), height: height ?? IOSurfaceGetHeight(surface),
                        bytesPerRow: row ?? IOSurfaceGetBytesPerRow(surface), pixelFormat: format)
    }

    static func fill(_ surface: IOSurface, blue: UInt8, red: UInt8) {
        IOSurfaceLock(surface, [], nil)
        defer { IOSurfaceUnlock(surface, [], nil) }
        let pixels = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)
        for y in 0..<IOSurfaceGetHeight(surface) {
            for x in 0..<IOSurfaceGetWidth(surface) {
                let offset = y * IOSurfaceGetBytesPerRow(surface) + x * 4
                pixels[offset] = blue; pixels[offset + 1] = 0
                pixels[offset + 2] = red; pixels[offset + 3] = 255
            }
        }
    }

    static func rejects(_ host: SceneBackendMetalHostView, _ surface: IOSurface,
                        _ token: SceneFrameToken) async throws -> Bool {
        do { try await host.consume(surface: surface, token: token); return false }
        catch UniversalSceneBackendError.invalidFrame { return true }
    }

    static func main() async throws {
        _ = NSApplication.shared
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw Failure(message: "real Metal device required")
        }
        let host = try SceneBackendMetalHostView.make()
        let session = UUID(), slots = [UUID(), UUID(), UUID()]
        let surfaces = try (0..<3).map { _ in try surface() }
        for frame in 0..<30 {
            let index = frame % 3, blue = UInt8(frame * 7), red = UInt8(255 - frame * 7)
            fill(surfaces[index], blue: blue, red: red)
            try await host.consume(surface: surfaces[index], token: token(
                surfaces[index], session: session, slot: slots[index], sequence: UInt64(frame + 1)))
            let bytes = try await host.retainedFrameBytesForTesting()
            try check(bytes[0] == blue && bytes[2] == red,
                      "frame \(frame + 1) sees the latest pixels in a reused input surface")
        }
        try check(host.sourceTextureAllocationCountForTesting == 3 && host.sourceTextureCountForTesting == 3,
                  "30 consumes across the helper's 3 slots create exactly 3 input Metal textures")

        // Match the cross-process capability boundary: a received surface may
        // have a different Swift wrapper while referring to the same allocation.
        let port = IOSurfaceCreateMachPort(surfaces[0])
        defer { mach_port_deallocate(mach_task_self_, port) }
        guard port != MACH_PORT_NULL, let imported = IOSurfaceLookupFromMachPort(port) else {
            throw Failure(message: "could not import the IOSurface Mach capability")
        }
        try await host.consume(surface: imported, token: token(
            imported, session: session, slot: slots[0], sequence: 31))
        try check(IOSurfaceGetID(imported) == IOSurfaceGetID(surfaces[0]) &&
                  host.sourceTextureAllocationCountForTesting == 3,
                  "a Mach-port-imported wrapper of the same IOSurface reuses its input mapping")

        let invalidTokens = [
            token(surfaces[0], session: session, slot: slots[0], format: "RGBA8Unorm"),
            token(surfaces[0], session: session, slot: slots[0], row: 0),
            token(surfaces[0], session: session, slot: slots[0], row: IOSurfaceGetBytesPerRow(surfaces[0]) + 256),
            token(surfaces[0], session: session, slot: slots[0], width: 0),
            token(surfaces[0], session: session, slot: slots[0], width: 63),
            token(surfaces[0], session: session, slot: slots[0], height: 31),
            token(surfaces[0], session: session, slot: slots[0], width: Int.max),
            token(surfaces[0], session: session, slot: slots[0], height: -1),
            token(surfaces[0], session: session, slot: slots[0], width: 8192, height: 8192)
        ]
        var rejected = 0
        for invalid in invalidTokens {
            if try await rejects(host, surfaces[0], invalid) { rejected += 1 }
        }
        let wrongFormatSurface = try surface(format: 0x5247_4241)
        if try await rejects(host, wrongFormatSurface, token(wrongFormatSurface, session: session, slot: slots[0])) {
            rejected += 1
        }
        let wrongSizeSurface = try surface(width: 32)
        if try await rejects(host, wrongSizeSurface, token(surfaces[0], session: session, slot: slots[0])) {
            rejected += 1
        }
        try check(rejected == invalidTokens.count + 2 && host.sourceTextureAllocationCountForTesting == 3 &&
                  host.sourceTextureCountForTesting == 3,
                  "cache-hit slots still reject invalid token and actual surface metadata without cache mutation")
        let replacement = try surface()
        fill(replacement, blue: 0, red: 255)
        try await host.consume(surface: replacement, token: token(replacement, session: session, slot: slots[0]))
        let replacedBytes = try await host.retainedFrameBytesForTesting()
        try check(host.sourceTextureAllocationCountForTesting == 4 && host.sourceTextureCountForTesting == 3 &&
                  replacedBytes[0] == 0 && replacedBytes[2] == 255,
                  "replacing a surface in the same slot creates a new mapping and reads that surface")

        let switchedSession = UUID()
        try await host.consume(surface: replacement, token: token(replacement, session: switchedSession, slot: slots[0]))
        try check(host.sourceTextureAllocationCountForTesting == 5 && host.sourceTextureCountForTesting == 1,
                  "session change drops all mappings even for the same slot and surface")
        try await host.consume(surface: replacement, token: token(
            replacement, session: switchedSession, generation: 2, slot: slots[0]))
        try check(host.sourceTextureAllocationCountForTesting == 6 && host.sourceTextureCountForTesting == 1,
                  "generation change creates a fresh input mapping")
        let resized = try surface(width: 32, height: 16)
        try await host.consume(surface: resized, token: token(resized, session: switchedSession, generation: 2, slot: slots[0]))
        try check(host.sourceTextureAllocationCountForTesting == 7 && host.sourceTextureCountForTesting == 1 &&
                  host.retainedFrameSizeForTesting == CGSize(width: 32, height: 16),
                  "dimension change creates a fresh input mapping and retains the new size")
        let padded = try surface(width: 32, height: 16, extraRowBytes: 256)
        try await host.consume(surface: padded, token: token(padded, session: switchedSession, generation: 2, slot: slots[0]))
        try check(host.sourceTextureAllocationCountForTesting == 8 && host.sourceTextureCountForTesting == 1,
                  "row-stride change drops mappings from the prior layout")

        // Each adversarial slot is valid but the helper contract only needs 3.
        // Exercise bounded retention and deterministic least-recently-used eviction.
        let bounded = try SceneBackendMetalHostView.make()
        let boundedSlots = (0..<4).map { _ in UUID() }
        for index in 0..<3 {
            try await bounded.consume(surface: surfaces[index], token: token(
                surfaces[index], session: session, slot: boundedSlots[index]))
        }
        try await bounded.consume(surface: surfaces[0], token: token(surfaces[0], session: session, slot: boundedSlots[0]))
        try await bounded.consume(surface: replacement, token: token(replacement, session: session, slot: boundedSlots[3]))
        try await bounded.consume(surface: surfaces[0], token: token(surfaces[0], session: session, slot: boundedSlots[0]))
        try check(bounded.sourceTextureAllocationCountForTesting == 4 && bounded.sourceTextureCountForTesting == 3,
                  "a fourth slot evicts the least-recently-used mapping and keeps the recently used one")
        try await bounded.consume(surface: surfaces[1], token: token(surfaces[1], session: session, slot: boundedSlots[1]))
        try check(bounded.sourceTextureAllocationCountForTesting == 5,
                  "the evicted slot requires a new Metal mapping")
        for _ in 0..<50 {
            let next = try surface()
            try await bounded.consume(surface: next, token: token(next, session: session, slot: UUID()))
            guard bounded.sourceTextureCountForTesting <= 3 else { throw Failure(message: "unbounded input cache") }
        }
        try check(bounded.sourceTextureCountForTesting == 3,
                  "50 additional surfaces cannot retain more than 3 cached input mappings")
        bounded.resetSourceTextureCache()
        try check(bounded.sourceTextureCountForTesting == 0,
                  "session teardown explicitly releases every cached input mapping")

        // Reset during an async consume must not invalidate its submitted input.
        let inFlightSurface = try surface(width: 2048, height: 1024)
        fill(inFlightSurface, blue: 73, red: 182)
        let inFlight = Task { @MainActor in
            try await bounded.consume(surface: inFlightSurface, token: token(
                inFlightSurface, session: session, slot: UUID()))
        }
        await Task.yield()
        bounded.resetSourceTextureCache()
        try await inFlight.value
        let finalBytes = try await bounded.retainedFrameBytesForTesting()
        try check(finalBytes[0] == 73 && finalBytes[2] == 182,
                  "reset across GPU completion preserves the in-flight surface and its exact pixels")
        print("Scene input IOSurface texture cache checks passed; stable 3-slot path: 3 allocations / 32 frames")
    }
}
