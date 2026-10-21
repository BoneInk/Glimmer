import AppKit
import CoreVideo
import IOSurface
import Metal

@main @MainActor enum SceneLockScreenExportTests {
    struct Failure: Error { let message: String }
    static func check(_ value: Bool, _ name: String) throws {
        guard value else { throw Failure(message: name) }
        print("PASS \(name)"); fflush(stdout)
    }
    static func makeBGRASurface(width: Int, height: Int) throws -> (surface: IOSurface, bytesPerRow: Int) {
        let bytesPerRow = (width * 4 + 255) & ~255
        let properties: [String: Any] = [
            kIOSurfaceWidth as String: width,
            kIOSurfaceHeight as String: height,
            kIOSurfaceBytesPerRow as String: bytesPerRow,
            kIOSurfacePixelFormat as String: 0x4247_5241
        ]
        guard let surface = IOSurfaceCreate(properties as CFDictionary) else {
            throw Failure(message: "could not create \(width)x\(height) probe IOSurface")
        }
        return (surface, IOSurfaceGetBytesPerRow(surface))
    }
    static func main() async throws {
        _ = NSApplication.shared
        guard MTLCreateSystemDefaultDevice() != nil else {
            print("SKIP no Metal device")
            return
        }
        let width = 64, height = 32, bytesPerRow = width * 4
        let properties: [String: Any] = [
            kIOSurfaceWidth as String: width,
            kIOSurfaceHeight as String: height,
            kIOSurfaceBytesPerRow as String: bytesPerRow,
            kIOSurfacePixelFormat as String: 0x4247_5241
        ]
        guard let surface = IOSurfaceCreate(properties as CFDictionary) else {
            throw Failure(message: "could not create probe IOSurface")
        }
        IOSurfaceLock(surface, [], nil)
        let base = IOSurfaceGetBaseAddress(surface)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        let row = IOSurfaceGetBytesPerRow(surface)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * row + x * 4
                let red = y < height / 2
                pixels[offset] = red ? 0 : 255
                pixels[offset + 1] = 0
                pixels[offset + 2] = red ? 255 : 0
                pixels[offset + 3] = 255
            }
        }
        IOSurfaceUnlock(surface, [], nil)

        var optional: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_32BGRA, attributes as CFDictionary, &optional) == kCVReturnSuccess,
              let buffer = optional else {
            throw Failure(message: "could not create probe pixel buffer")
        }
        let token = SceneFrameToken(sessionID: UUID(), generation: 1, sequence: 1,
            slotID: UUID(), width: width, height: height, bytesPerRow: bytesPerRow,
            pixelFormat: "BGRA8Unorm")
        let host = try SceneBackendMetalHostView.make()
        try await host.copyFrame(surface: surface, token: token, into: buffer)

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let output = CVPixelBufferGetBaseAddress(buffer) else {
            throw Failure(message: "export buffer has no base address")
        }
        let out = output.assumingMemoryBound(to: UInt8.self)
        let outRow = CVPixelBufferGetBytesPerRow(buffer)
        func mean(rows: Range<Int>) -> (red: Double, blue: Double) {
            var red = 0.0, blue = 0.0, count = 0.0
            for y in rows {
                for x in stride(from: 0, to: width, by: 4) {
                    let offset = y * outRow + x * 4
                    blue += Double(out[offset]); red += Double(out[offset + 2]); count += 1
                }
            }
            return (red / count, blue / count)
        }
        let top = mean(rows: 0..<(height / 4))
        let bottom = mean(rows: (height * 3 / 4)..<height)
        try check(top.red > 180 && top.blue < 60,
                  "Scene export keeps the authored top edge at the top (no Y inversion)")
        try check(bottom.blue > 180 && bottom.red < 60,
                  "Scene export keeps the authored bottom edge at the bottom")

        // copyFrame only fills the export buffer; consume initializes the
        // retained frame exercised by the following checks.
        try await host.consume(surface: surface, token: token)
        let retained = try await host.retainedFrameBytesForTesting()
        func bgra(_ bytes: [UInt8], width: Int, x: Int, y: Int) -> (red: Int, green: Int, blue: Int) {
            let offset = (y * width + x) * 4
            return (Int(bytes[offset + 2]), Int(bytes[offset + 1]), Int(bytes[offset]))
        }
        let retainedTop = bgra(retained, width: width, x: width / 2, y: 0)
        let retainedBottom = bgra(retained, width: width, x: width / 2, y: height - 1)
        try check(retainedTop.red > 180 && retainedTop.blue < 60 &&
                  retainedBottom.blue > 180 && retainedBottom.red < 60,
                  "consume retains the source frame with its authored row order")
        try check(host.retainedFrameSizeForTesting == CGSize(width: width, height: height),
                  "retained frame keeps the exact token dimensions")

        let fitBytes = try await host.renderedFrameBytesForTesting(
            pixelSize: CGSize(width: 32, height: 32), aspectFill: false)
        let fillBytes = try await host.renderedFrameBytesForTesting(
            pixelSize: CGSize(width: 32, height: 32), aspectFill: true)
        let fitTop = bgra(fitBytes, width: 32, x: 16, y: 0)
        let fitBottom = bgra(fitBytes, width: 32, x: 16, y: 31)
        // renderedFrameBytesForTesting returns raw MTLTexture row order. Because
        // encode(forDrawable: true) applies the existing drawable Y flip, raw row 0
        // is blue and the final raw row is red.
        let fillFirstRawRow = bgra(fillBytes, width: 32, x: 16, y: 0)
        let fillLastRawRow = bgra(fillBytes, width: 32, x: 16, y: 31)
        try check(fitTop.red + fitTop.green + fitTop.blue < 30 &&
                  fitBottom.red + fitBottom.green + fitBottom.blue < 30,
                  "fit render preserves letterboxing through the drawable encode")
        try check(fillFirstRawRow.blue > 180 && fillFirstRawRow.red < 60 &&
                  fillLastRawRow.red > 180 && fillLastRawRow.blue < 60,
                  "fill raw readback has blue at row 0 and red at the last row (existing drawable Y flip)")

        try check(!SceneBackendMetalHostView.requestsRetainedRedraw(
                    presented: true, revisionChanged: false),
                  "a successful presented frame does not enqueue a duplicate retained draw")
        try check(SceneBackendMetalHostView.requestsRetainedRedraw(
                    presented: false, revisionChanged: false) &&
                  SceneBackendMetalHostView.requestsRetainedRedraw(
                    presented: true, revisionChanged: true),
                  "headless preload and fit/resize revision retain a recovery draw")

        // A second and third consume cannot mutate the texture currently held for
        // testing; the retired textures are only pooled after their GPU fence.
        for sequence in 2...3 {
            let nextToken = SceneFrameToken(
                sessionID: token.sessionID, generation: token.generation, sequence: UInt64(sequence),
                slotID: UUID(), width: width, height: height, bytesPerRow: bytesPerRow,
                pixelFormat: "BGRA8Unorm")
            try await host.consume(surface: surface, token: nextToken)
        }
        let poolDeadline = ContinuousClock.now + .seconds(3)
        while host.pooledTextureCountForTesting == 0, ContinuousClock.now < poolDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let pooledBeforeReuse = host.pooledTextureCountForTesting
        let allocationsBeforeReuse = host.textureAllocationCountForTesting
        try check(pooledBeforeReuse > 0 && pooledBeforeReuse <= 2,
                  "retired same-size textures enter the bounded fence-gated pool")
        let reuseToken = SceneFrameToken(
            sessionID: token.sessionID, generation: token.generation, sequence: 4,
            slotID: UUID(), width: width, height: height, bytesPerRow: bytesPerRow,
            pixelFormat: "BGRA8Unorm")
        try await host.consume(surface: surface, token: reuseToken)
        let latest = try await host.retainedFrameBytesForTesting()
        let latestTop = bgra(latest, width: width, x: width / 2, y: 0)
        try check(latestTop.red > 180 && latestTop.blue < 60 &&
                  host.retainedFrameSizeForTesting == CGSize(width: width, height: height) &&
                  host.textureAllocationCountForTesting == allocationsBeforeReuse &&
                  host.pooledTextureCountForTesting <= 2,
                  "a later same-size frame reuses the GPU-fenced pool without another allocation")

        // A resize sequence must not let retired textures from old sizes occupy
        // the globally bounded pool. Once the new active size has a fenced
        // retirement, the next frame must reuse it instead of allocating again.
        let resizedHost = try SceneBackendMetalHostView.make()
        for (index, size) in [(4, 4), (6, 5), (8, 7), (8, 7)].enumerated() {
            let probe = try makeBGRASurface(width: size.0, height: size.1)
            let token = SceneFrameToken(
                sessionID: token.sessionID, generation: token.generation,
                sequence: UInt64(10 + index), slotID: UUID(),
                width: size.0, height: size.1, bytesPerRow: probe.bytesPerRow,
                pixelFormat: "BGRA8Unorm")
            try await resizedHost.consume(surface: probe.surface, token: token)
        }
        let resizedPoolDeadline = ContinuousClock.now + .seconds(3)
        while resizedHost.pooledTextureCountForTesting == 0,
              ContinuousClock.now < resizedPoolDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try check(resizedHost.pooledTextureCountForTesting > 0,
                  "a fenced retirement from the new active size enters the pool")
        let allocationsBeforeStableSize = resizedHost.textureAllocationCountForTesting
        let stableProbe = try makeBGRASurface(width: 8, height: 7)
        let stableToken = SceneFrameToken(
            sessionID: token.sessionID, generation: token.generation, sequence: 20,
            slotID: UUID(), width: 8, height: 7, bytesPerRow: stableProbe.bytesPerRow,
            pixelFormat: "BGRA8Unorm")
        try await resizedHost.consume(surface: stableProbe.surface, token: stableToken)
        try check(resizedHost.retainedFrameSizeForTesting == CGSize(width: 8, height: 7) &&
                  resizedHost.textureAllocationCountForTesting == allocationsBeforeStableSize &&
                  resizedHost.pooledTextureCountForTesting <= 2,
                  "a stable size retains only active-size retirements and reuses one without another allocation")

        let window = NSWindow(
            contentRect: CGRect(x: -10_000, y: -10_000, width: 64, height: 32),
            styleMask: [.borderless], backing: .buffered, defer: false)
        host.frame = CGRect(x: 0, y: 0, width: 64, height: 32)
        host.needsDisplay = false
        window.contentView = host
        try check(host.window === window && host.needsDisplay,
                  "attaching a headless-preloaded host schedules its retained first frame")
        host.needsDisplay = false
        host.mtkView(host, drawableSizeWillChange: CGSize(width: 96, height: 64))
        try check(host.needsDisplay,
                  "drawable resize requests a retained redraw while paused")
        host.needsDisplay = false
        host.setAspectFill(false)
        try check(host.needsDisplay,
                  "fit/fill changes request a retained redraw while paused")
        window.contentView = nil
        window.close()
        print("Scene lock-screen export orientation and retained-frame recovery checks passed")
    }
}
