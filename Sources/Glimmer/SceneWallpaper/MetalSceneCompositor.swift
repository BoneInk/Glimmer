import Foundation
import Metal

/// Original bounded offscreen prototype. No runtime hookup, arbitrary shader
/// compilation, proprietary resources, device window, or CPU fallback.
final class MetalSceneCompositor {
    private let renderLock = NSLock()
    static let maximumSampleWork = 128 * 1024 * 1024
    static let maximumPeakBytes = 512 * 1024 * 1024
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipelines: [MetalSceneBlend: MTLRenderPipelineState]
    private let nearest: MTLSamplerState
    private let linear: MTLSamplerState
    var deviceName: String { device.name }
    private static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct V { float4 position [[position]]; float2 uv; };
    struct U { float4 tintOpacity; float4 clip; uint premultiplied; };
    vertex V gw_vertex(uint id [[vertex_id]], constant float4 *v [[buffer(0)]]) {
        V o; o.position=float4(v[id].xy,0,1); o.uv=v[id].zw; return o;
    }
    fragment float4 gw_fragment(V v [[stage_in]], texture2d<float> t [[texture(0)]],
                               sampler s [[sampler(0)]], constant U &u [[buffer(0)]]) {
        if (v.position.x<u.clip.x || v.position.y<u.clip.y || v.position.x>=u.clip.z || v.position.y>=u.clip.w) discard_fragment();
        float4 c=t.sample(s,v.uv);
        float3 rgb=c.rgb*u.tintOpacity.rgb*u.tintOpacity.a;
        if (!u.premultiplied) rgb*=c.a;
        return float4(rgb,c.a*u.tintOpacity.a);
    }
    """
    init() throws {
        guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue() else {
            throw SceneWallpaperFailure(message: "A real Metal device/command queue is required; no CPU fallback.")
        }
        device = d; queue = q
        let library = try d.makeLibrary(source: Self.source, options: nil)
        var states: [MetalSceneBlend: MTLRenderPipelineState] = [:]
        for blend in MetalSceneBlend.allCases {
            let p = MTLRenderPipelineDescriptor()
            p.vertexFunction = library.makeFunction(name: "gw_vertex")
            p.fragmentFunction = library.makeFunction(name: "gw_fragment")
            let a = p.colorAttachments[0]!
            a.pixelFormat = .rgba8Unorm
            a.isBlendingEnabled = blend != .copy
            a.sourceRGBBlendFactor = .one; a.sourceAlphaBlendFactor = .one
            a.destinationRGBBlendFactor = blend == .additive ? .one : .oneMinusSourceAlpha
            a.destinationAlphaBlendFactor = blend == .additive ? .one : .oneMinusSourceAlpha
            a.rgbBlendOperation = .add; a.alphaBlendOperation = .add
            states[blend] = try d.makeRenderPipelineState(descriptor: p)
        }
        pipelines = states
        func sampler(_ filter: MTLSamplerMinMagFilter) throws -> MTLSamplerState {
            let s = MTLSamplerDescriptor(); s.minFilter = filter; s.magFilter = filter
            s.sAddressMode = .clampToEdge; s.tAddressMode = .clampToEdge
            guard let result = d.makeSamplerState(descriptor: s) else { throw SceneWallpaperFailure(message: "Metal sampler allocation failed.") }
            return result
        }
        nearest = try sampler(.nearest); linear = try sampler(.linear)
    }
    /// Sequential render-target graph: a pass may only sample inputs or a prior
    /// pass. Same-target read/write, forward references and duplicate IDs reject.
    /// Caller must run away from UI. The exclusive lease includes preparation and GPU
    /// completion; concurrent calls reject rather than accumulate allocations/submissions.
    /// Cancellation before commit submits nothing; committed GPU work must finish before
    /// resources and the lease are released. No forced GPU cancellation is promised.
    func render(textures: [String: MetalSceneTexture], passes: [MetalScenePass]) throws -> MetalSceneReadback {
        try withExclusiveRender { try renderLocked(textures: textures, passes: passes) }
    }

    /// Adapter shares the same lease across decoding and submission.
    func withExclusiveRender<T>(_ body: () throws -> T) throws -> T {
        try Task.checkCancellation()
        guard renderLock.try() else { throw failure("Metal compositor is already rendering; concurrent submission rejected.") }
        defer { renderLock.unlock() }
        return try body()
    }

    /// Internal entry for the adapter while it owns withExclusiveRender's lease.
    func renderLocked(textures: [String: MetalSceneTexture], passes: [MetalScenePass],
                      additionalResidentBytes: Int = 0) throws -> MetalSceneReadback {
        try Task.checkCancellation()
        guard !passes.isEmpty, passes.count <= 8, textures.count <= 512,
              passes.reduce(0, { $0 + $1.draws.count }) <= 2048 else { throw failure("Pass/resource/draw count limit exceeded.") }
        var budget = 0, sourceBytes = 0, largestUpload = 0, work = 0
        var dimensions: [String: (Int, Int)] = [:]
        func reserve(_ name: String, _ width: Int, _ height: Int) throws {
            guard !name.isEmpty, name.utf8.count <= 1024, dimensions[name] == nil,
                  width > 0, height > 0, width <= 8192, height <= 8192,
                  width * height <= 32 * 1024 * 1024 else { throw failure("Invalid/duplicate resource or dimensions.") }
            budget += width * height * 4
            guard budget <= 256 * 1024 * 1024 else { throw failure("Metal texture budget exceeded.") }
            dimensions[name] = (width, height)
        }
        for (name, texture) in textures {
            try reserve(name, texture.width, texture.height)
            guard texture.rgba.count == texture.width * texture.height * 4 else { throw failure("RGBA byte count mismatch.") }
            sourceBytes += texture.rgba.count
            largestUpload = max(largestUpload, texture.rgba.count)
        }
        var available = Set(textures.keys)
        for pass in passes {
            try reserve(pass.target, pass.width, pass.height)
            guard (0..<4).allSatisfy({pass.clear[$0].isFinite && (0...1).contains(pass.clear[$0])}) else { throw failure("Invalid clear color.") }
            if let clip = pass.clip {
                guard (0..<4).allSatisfy({clip[$0].isFinite}), clip.x >= 0, clip.y >= 0,
                      clip.z >= clip.x, clip.w >= clip.y, clip.z <= Double(pass.width), clip.w <= Double(pass.height) else { throw failure("Invalid clip bounds.") }
            }
            try addWork(pass.width * pass.height, total: &work) // clear cost, even for an empty pass
            for draw in pass.draws {
                try Task.checkCancellation()
                guard available.contains(draw.source), draw.source != pass.target,
                      [draw.transform.a,draw.transform.b,draw.transform.c,draw.transform.d,draw.transform.tx,draw.transform.ty].allSatisfy({$0.isFinite && abs($0) <= 1e12}),
                      [draw.size.x,draw.size.y].allSatisfy({$0.isFinite && $0 > 0 && $0 <= 1e6}),
                      [draw.tint.x,draw.tint.y,draw.tint.z,draw.opacity].allSatisfy({$0.isFinite && (0...1).contains($0)}) else { throw failure("Invalid draw or unsafe/unavailable texture reference.") }
                try addWork(try sampleWork(draw, pass: pass), total: &work)
            }
            available.insert(pass.target)
        }
        let last = passes.last!, readbackStride = ((last.width * 4 + 255) / 256) * 256
        // Conservative simultaneous memory: source RGBA, all GPU textures, largest
        // upload copy, aligned readback, returned pixels, plus adapter-owned sources.
        // Driver/codec-private overhead is not claimed as a process RSS hard limit.
        try Self.checkPeak([sourceBytes, budget, largestUpload, readbackStride * last.height,
                            last.width * last.height * 4, additionalResidentBytes])
        try Task.checkCancellation()
        guard let command = queue.makeCommandBuffer() else { throw failure("Command buffer allocation failed.") }
        var resources: [String: MTLTexture] = [:]
        var premultiplied = Set<String>()
        for (name, input) in textures {
            try Task.checkCancellation()
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: input.width, height: input.height, mipmapped: false)
            desc.storageMode = .shared; desc.usage = .shaderRead
            guard let t = device.makeTexture(descriptor: desc) else { throw failure("Input texture allocation failed.") }
            // Filter premultiplied texels, otherwise RGB in transparent texels
            // creates halos when bilinear sampling crosses an alpha edge.
            var upload = input.rgba
            try upload.withUnsafeMutableBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self)
                for row in 0..<input.height {
                    try Task.checkCancellation()
                    for i in stride(from: row * input.width * 4, to: (row + 1) * input.width * 4, by: 4) {
                        let alpha = Int(bytes[i+3])
                        for c in 0..<3 { bytes[i+c] = UInt8((Int(bytes[i+c])*alpha+127)/255) }
                    }
                }
            }
            upload.withUnsafeBytes { p in t.replace(region: MTLRegionMake2D(0,0,input.width,input.height), mipmapLevel: 0, withBytes: p.baseAddress!, bytesPerRow: input.width * 4) }
            resources[name] = t; premultiplied.insert(name)
        }
        for pass in passes {
            try Task.checkCancellation()
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: pass.width, height: pass.height, mipmapped: false)
            desc.storageMode = .private; desc.usage = [.renderTarget, .shaderRead]
            guard let target = device.makeTexture(descriptor: desc) else { throw failure("Target texture allocation failed.") }
            resources[pass.target] = target
            let rp = MTLRenderPassDescriptor(), attachment = rp.colorAttachments[0]!
            attachment.texture = target; attachment.loadAction = .clear; attachment.storeAction = .store
            attachment.clearColor = MTLClearColor(red:pass.clear.x*pass.clear.w,green:pass.clear.y*pass.clear.w,blue:pass.clear.z*pass.clear.w,alpha:pass.clear.w)
            guard let encoder = command.makeRenderCommandEncoder(descriptor: rp) else { throw failure("Render encoder allocation failed.") }
            defer { encoder.endEncoding() }
            encoder.setCullMode(.none)
            // Bound rasterization itself, rather than merely discarding fragments
            // outside clip in the shader after they have already consumed work.
            let clip = pass.clip ?? SIMD4(0,0,Double(pass.width),Double(pass.height))
            let scissor = MTLScissorRect(x: Int(floor(clip.x)), y: Int(floor(clip.y)),
                width: Int(ceil(clip.z)-floor(clip.x)), height: Int(ceil(clip.w)-floor(clip.y)))
            let hasRasterClip = clip.z > clip.x && clip.w > clip.y && scissor.width > 0 && scissor.height > 0
            if hasRasterClip { encoder.setScissorRect(scissor) }
            for draw in pass.draws {
                try Task.checkCancellation()
                guard hasRasterClip else { continue }
                let m = draw.transform, w = draw.size.x/2, h = draw.size.y/2
                func vertex(_ x: Double, _ y: Double, _ u: Float, _ v: Float) -> SIMD4<Float> {
                    let wx = m.a*x+m.c*y+m.tx, wy = m.b*x+m.d*y+m.ty
                    return SIMD4(Float(2*wx/Double(pass.width)-1),Float(2*wy/Double(pass.height)-1),u,v)
                }
                // Metal texture row 0 is top; scene geometry is y-up.
                let vertices = [vertex(-w,-h,0,1),vertex(w,-h,1,1),vertex(-w,h,0,0),vertex(w,-h,1,1),vertex(w,h,1,0),vertex(-w,h,0,0)]
                struct Uniform { var tintOpacity: SIMD4<Float>; var clip: SIMD4<Float>; var premultiplied: UInt32 }
                var uniform = Uniform(tintOpacity: SIMD4(Float(draw.tint.x),Float(draw.tint.y),Float(draw.tint.z),Float(draw.opacity)),clip: pass.clip.map { SIMD4<Float>(Float($0.x),Float($0.y),Float($0.z),Float($0.w)) } ?? SIMD4<Float>(0,0,Float(pass.width),Float(pass.height)),premultiplied: premultiplied.contains(draw.source) ? 1 : 0)
                encoder.setRenderPipelineState(pipelines[draw.blend]!)
                vertices.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length:$0.count,index:0) }
                encoder.setFragmentBytes(&uniform,length:MemoryLayout<Uniform>.stride,index:0)
                encoder.setFragmentTexture(resources[draw.source]!, index:0)
                encoder.setFragmentSamplerState(draw.sampling == .nearest ? nearest : linear,index:0)
                encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6)
            }
            premultiplied.insert(pass.target)
        }
        try Task.checkCancellation()
        guard let buffer = device.makeBuffer(length:readbackStride * last.height,options:.storageModeShared),
              let blit = command.makeBlitCommandEncoder() else { throw failure("Readback allocation failed.") }
        blit.copy(from:resources[last.target]!,sourceSlice:0,sourceLevel:0,sourceOrigin:MTLOrigin(x:0,y:0,z:0),sourceSize:MTLSize(width:last.width,height:last.height,depth:1),to:buffer,destinationOffset:0,destinationBytesPerRow:readbackStride,destinationBytesPerImage:readbackStride*last.height)
        blit.endEncoding()
        try Task.checkCancellation() // final checkpoint: no work submitted on cancellation
        command.commit()
        command.waitUntilCompleted() // retain resources/lease until GPU actually completes
        guard command.status == .completed else { throw failure("GPU command failed: \(command.error?.localizedDescription ?? "unknown")") }
        try Task.checkCancellation()
        var bytes = Data(count:last.width * last.height * 4)
        try bytes.withUnsafeMutableBytes { out in
            for y in 0..<last.height {
                try Task.checkCancellation()
                out.baseAddress!.advanced(by:y*last.width*4).copyMemory(from:buffer.contents().advanced(by:y*readbackStride),byteCount:last.width*4)
            }
        }
        return MetalSceneReadback(width:last.width,height:last.height,rgba:bytes,deviceName:device.name)
    }
    static func checkPeak(_ components: [Int]) throws {
        var sum = 0
        for value in components {
            guard value >= 0, value <= maximumPeakBytes - sum else {
                throw SceneWallpaperFailure(message: "Metal conservative peak memory budget exceeded.")
            }
            sum += value
        }
    }
    private func addWork(_ value: Int, total: inout Int) throws {
        guard value >= 0, value <= Self.maximumSampleWork - total else {
            throw failure("Metal workload budget exceeded before GPU submission.")
        }
        total += value
    }
    private func sampleWork(_ draw: MetalSceneDraw, pass: MetalScenePass) throws -> Int {
        let w = draw.size.x / 2, h = draw.size.y / 2, m = draw.transform
        let corners = [(-w,-h),(w,-h),(-w,h),(w,h)].map { x, y in
            (m.a*x+m.c*y+m.tx, Double(pass.height)-(m.b*x+m.d*y+m.ty))
        }
        guard corners.allSatisfy({ $0.0.isFinite && $0.1.isFinite }) else { throw failure("Nonfinite raster bounds.") }
        let clip = pass.clip ?? SIMD4(0,0,Double(pass.width),Double(pass.height))
        let left = max(clip.x, 0, corners.map(\.0).min()!), top = max(clip.y, 0, corners.map(\.1).min()!)
        let right = min(clip.z, Double(pass.width), corners.map(\.0).max()!)
        let bottom = min(clip.w, Double(pass.height), corners.map(\.1).max()!)
        guard right > left, bottom > top else { return 0 }
        // Whole pixel-edge cells are an upper bound on covered sample centers.
        let area = Int(ceil(right)-floor(left)) * Int(ceil(bottom)-floor(top))
        return area * (draw.sampling == .linear ? 4 : 1)
    }
    private func failure(_ message: String) -> SceneWallpaperFailure { .init(message:message) }
}
