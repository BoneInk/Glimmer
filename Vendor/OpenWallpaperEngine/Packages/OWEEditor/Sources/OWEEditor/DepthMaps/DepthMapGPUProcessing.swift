import Foundation
import Metal

/// `DepthMapProcessing`'s upscale and smoothing on the GPU, the same filters with the same
/// parameters: the joint bilateral upsampling one thread per output pixel, and the guided
/// filter's box means as separable passes (rows, then columns, which also work out the filter's
/// coefficients), each window clamped to the map as the CPU's summed-area table is.
///
/// On the system's default device, which the scene renderer draws with too. The kernels are
/// compiled on first use, off the main thread; the buffers live for one call.
public final class DepthMapGPUProcessing: @unchecked Sendable { // `lock` guards `pipelines`.
    public enum Failure: Error {
        case unavailable
    }

    private struct Pipelines {
        var cellMeans: MTLComputePipelineState
        var upscale: MTLComputePipelineState
        var guidedRows: MTLComputePipelineState
        var guidedCoefficients: MTLComputePipelineState
        var coefficientRows: MTLComputePipelineState
        var guidedOutput: MTLComputePipelineState
    }

    public let device: MTLDevice
    private let queue: MTLCommandQueue
    private let lock = NSLock()
    private var pipelines: Pipelines?

    /// Nil without a device.
    public init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device, let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        queue.label = "Depth map processing"
    }

    // MARK: Filters

    /// `DepthMapProcessing.upscaled`.
    public func upscaled(_ depth: DepthMapBuffer, guide: DepthMapBuffer,
                         sigmaSpatial: Float = 1, sigmaRange: Float = 0.1) throws -> DepthMapBuffer {
        let width = guide.width, height = guide.height
        // Not larger: plain resampling, of a picture no bigger than the model's.
        guard width > depth.width || height > depth.height else {
            return DepthMapProcessing.resized(depth, width: width, height: height)
        }
        let pipelines = try loadedPipelines()
        let low = try buffer(depth.values), picture = try buffer(guide.values)
        let cells = try buffer(count: depth.values.count * MemoryLayout<Float>.stride)
        let output = try buffer(count: guide.values.count * MemoryLayout<Float>.stride)
        var sizes = SIMD4<UInt32>(UInt32(width), UInt32(height), UInt32(depth.width), UInt32(depth.height))
        var sigmas = SIMD2<Float>(sigmaSpatial, sigmaRange)
        try run { encoder in
            encoder.setComputePipelineState(pipelines.cellMeans)
            encoder.setBuffer(picture, offset: 0, index: 0)
            encoder.setBuffer(cells, offset: 0, index: 1)
            encoder.setBytes(&sizes, length: MemoryLayout<SIMD4<UInt32>>.stride, index: 2)
            dispatch(encoder, pipelines.cellMeans, width: depth.width, height: depth.height)

            encoder.setComputePipelineState(pipelines.upscale)
            encoder.setBuffer(low, offset: 0, index: 0)
            encoder.setBuffer(cells, offset: 0, index: 1)
            encoder.setBuffer(picture, offset: 0, index: 2)
            encoder.setBuffer(output, offset: 0, index: 3)
            encoder.setBytes(&sizes, length: MemoryLayout<SIMD4<UInt32>>.stride, index: 4)
            encoder.setBytes(&sigmas, length: MemoryLayout<SIMD2<Float>>.stride, index: 5)
            dispatch(encoder, pipelines.upscale, width: width, height: height)
        }
        return DepthMapBuffer(width: width, height: height, values: Self.values(of: output, count: guide.values.count))
    }

    /// `DepthMapProcessing.smoothed`.
    public func smoothed(_ depth: DepthMapBuffer, guide: DepthMapBuffer, smoothing: Double) throws -> DepthMapBuffer {
        precondition(depth.width == guide.width && depth.height == guide.height, "the guide must match the input")
        guard let filter = DepthMapProcessing.guidedFilterParameters(smoothing: smoothing, width: depth.width,
                                                                     height: depth.height) else { return depth }
        let pipelines = try loadedPipelines()
        let count = depth.values.count
        let input = try buffer(depth.values), picture = try buffer(guide.values)
        // The rows' means of I, p, I² and Ip, and later (in the same memory) of the coefficients.
        let rows = try buffer(count: count * MemoryLayout<SIMD4<Float>>.stride)
        let coefficients = try buffer(count: count * MemoryLayout<SIMD2<Float>>.stride)
        let output = try buffer(count: count * MemoryLayout<Float>.stride)
        var sizes = SIMD4<UInt32>(UInt32(depth.width), UInt32(depth.height), UInt32(filter.radius), 0)
        var epsilon = filter.epsilon
        try run { encoder in
            encoder.setComputePipelineState(pipelines.guidedRows)
            encoder.setBuffer(picture, offset: 0, index: 0)
            encoder.setBuffer(input, offset: 0, index: 1)
            encoder.setBuffer(rows, offset: 0, index: 2)
            encoder.setBytes(&sizes, length: MemoryLayout<SIMD4<UInt32>>.stride, index: 3)
            dispatch(encoder, pipelines.guidedRows, width: depth.width, height: depth.height)

            encoder.setComputePipelineState(pipelines.guidedCoefficients)
            encoder.setBuffer(rows, offset: 0, index: 0)
            encoder.setBuffer(coefficients, offset: 0, index: 1)
            encoder.setBytes(&sizes, length: MemoryLayout<SIMD4<UInt32>>.stride, index: 2)
            encoder.setBytes(&epsilon, length: MemoryLayout<Float>.stride, index: 3)
            dispatch(encoder, pipelines.guidedCoefficients, width: depth.width, height: depth.height)

            encoder.setComputePipelineState(pipelines.coefficientRows)
            encoder.setBuffer(coefficients, offset: 0, index: 0)
            encoder.setBuffer(rows, offset: 0, index: 1)
            encoder.setBytes(&sizes, length: MemoryLayout<SIMD4<UInt32>>.stride, index: 2)
            dispatch(encoder, pipelines.coefficientRows, width: depth.width, height: depth.height)

            encoder.setComputePipelineState(pipelines.guidedOutput)
            encoder.setBuffer(rows, offset: 0, index: 0)
            encoder.setBuffer(picture, offset: 0, index: 1)
            encoder.setBuffer(output, offset: 0, index: 2)
            encoder.setBytes(&sizes, length: MemoryLayout<SIMD4<UInt32>>.stride, index: 3)
            dispatch(encoder, pipelines.guidedOutput, width: depth.width, height: depth.height)
        }
        return DepthMapBuffer(width: depth.width, height: depth.height, values: Self.values(of: output, count: count))
    }

    // MARK: Running

    private func run(_ encode: (MTLComputeCommandEncoder) -> Void) throws {
        guard let commands = queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder() else {
            throw Failure.unavailable
        }
        encode(encoder)
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        if let error = commands.error { throw error }
    }

    private func dispatch(_ encoder: MTLComputeCommandEncoder, _ pipeline: MTLComputePipelineState, width: Int, height: Int) {
        let threadWidth = pipeline.threadExecutionWidth
        let threadHeight = max(1, pipeline.maxTotalThreadsPerThreadgroup / threadWidth)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: threadWidth, height: min(threadHeight, 8), depth: 1))
    }

    private func buffer(_ values: [Float]) throws -> MTLBuffer {
        let made = values.withUnsafeBytes { bytes in
            device.makeBuffer(bytes: bytes.baseAddress!, length: max(bytes.count, 4), options: .storageModeShared)
        }
        guard let made else { throw Failure.unavailable }
        return made
    }

    private func buffer(count: Int) throws -> MTLBuffer {
        guard let made = device.makeBuffer(length: max(count, 4), options: .storageModeShared) else { throw Failure.unavailable }
        return made
    }

    private static func values(of buffer: MTLBuffer, count: Int) -> [Float] {
        Array(UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: Float.self), count: count))
    }

    private func loadedPipelines() throws -> Pipelines {
        try lock.withLock {
            if let pipelines { return pipelines }
            let library = try device.makeLibrary(source: Self.source, options: nil)
            func pipeline(_ name: String) throws -> MTLComputePipelineState {
                guard let function = library.makeFunction(name: name) else { throw Failure.unavailable }
                return try device.makeComputePipelineState(function: function)
            }
            let made = Pipelines(cellMeans: try pipeline("depthCellMeans"), upscale: try pipeline("depthUpscale"),
                                 guidedRows: try pipeline("guidedRows"), guidedCoefficients: try pipeline("guidedCoefficients"),
                                 coefficientRows: try pipeline("coefficientRows"), guidedOutput: try pipeline("guidedOutput"))
            pipelines = made
            return made
        }
    }

    // MARK: Kernels

    /// Sizes are `uint4`: the upscale's (width, height, model width, model height); the guided
    /// filter's (width, height, radius, 0).
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    // The guide averaged over each model pixel's cell: the pixels x with x·low/width == cell.
    kernel void depthCellMeans(device const float *guide [[buffer(0)]], device float *cells [[buffer(1)]],
                               constant uint4 &size [[buffer(2)]], uint2 id [[thread_position_in_grid]]) {
        if (id.x >= size.z || id.y >= size.w) return;
        uint x0 = (id.x * size.x + size.z - 1) / size.z, x1 = min(size.x, ((id.x + 1) * size.x + size.z - 1) / size.z);
        uint y0 = (id.y * size.y + size.w - 1) / size.w, y1 = min(size.y, ((id.y + 1) * size.y + size.w - 1) / size.w);
        float sum = 0;
        for (uint y = y0; y < y1; y++) {
            for (uint x = x0; x < x1; x++) sum += guide[y * size.x + x];
        }
        uint count = (x1 > x0 && y1 > y0) ? (x1 - x0) * (y1 - y0) : 0;
        cells[id.y * size.z + id.x] = count > 0 ? sum / float(count) : 0.0;
    }

    // Joint bilateral upsampling over the model's 4 × 4 nearest samples.
    kernel void depthUpscale(device const float *low [[buffer(0)]], device const float *cells [[buffer(1)]],
                             device const float *guide [[buffer(2)]], device float *output [[buffer(3)]],
                             constant uint4 &size [[buffer(4)]], constant float2 &sigmas [[buffer(5)]],
                             uint2 id [[thread_position_in_grid]]) {
        if (id.x >= size.x || id.y >= size.y) return;
        float u = (float(id.x) + 0.5) * float(size.z) / float(size.x) - 0.5;
        float v = (float(id.y) + 0.5) * float(size.w) / float(size.y) - 0.5;
        int columnStart = int(floor(u)) - 1, rowStart = int(floor(v)) - 1;
        float spatialScale = 1.0 / (2.0 * sigmas.x * sigmas.x), rangeScale = 1.0 / (2.0 * sigmas.y * sigmas.y);
        float luminance = guide[id.y * size.x + id.x];
        float total = 0, sum = 0, spatialTotal = 0, spatialSum = 0;
        for (int rowTap = 0; rowTap < 4; rowTap++) {
            int j = rowStart + rowTap;
            if (j < 0 || j >= int(size.w)) continue;
            float dy = float(j) - v;
            float rowWeight = precise::exp(-(dy * dy) * spatialScale);
            for (int columnTap = 0; columnTap < 4; columnTap++) {
                int i = columnStart + columnTap;
                if (i < 0 || i >= int(size.z)) continue;
                float dx = float(i) - u;
                float spatial = rowWeight * precise::exp(-(dx * dx) * spatialScale);
                uint index = uint(j) * size.z + uint(i);
                float difference = min(255.0, floor(abs(luminance - cells[index]) * 255.0 + 0.5)) / 255.0;
                float weight = spatial * precise::exp(-(difference * difference) * rangeScale);
                total += weight;
                sum += weight * low[index];
                spatialTotal += spatial;
                spatialSum += spatial * low[index];
            }
        }
        float value = total > 1e-6 ? sum / total : (spatialTotal > 0 ? spatialSum / spatialTotal : 0.0);
        output[id.y * size.x + id.x] = clamp(value, 0.0, 1.0);
    }

    // Each row's window means of I, p, I² and Ip.
    kernel void guidedRows(device const float *guide [[buffer(0)]], device const float *input [[buffer(1)]],
                           device float4 *rows [[buffer(2)]], constant uint4 &size [[buffer(3)]],
                           uint2 id [[thread_position_in_grid]]) {
        if (id.x >= size.x || id.y >= size.y) return;
        int radius = int(size.z);
        int x0 = max(0, int(id.x) - radius), x1 = min(int(size.x), int(id.x) + radius + 1);
        uint row = id.y * size.x;
        float4 sum = 0;
        for (int x = x0; x < x1; x++) {
            float i = guide[row + uint(x)], p = input[row + uint(x)];
            sum += float4(i, p, i * i, i * p);
        }
        rows[row + id.x] = sum / float(x1 - x0);
    }

    // The columns' means of the rows' means, and from them the coefficients a and b.
    kernel void guidedCoefficients(device const float4 *rows [[buffer(0)]], device float2 *coefficients [[buffer(1)]],
                                   constant uint4 &size [[buffer(2)]], constant float &epsilon [[buffer(3)]],
                                   uint2 id [[thread_position_in_grid]]) {
        if (id.x >= size.x || id.y >= size.y) return;
        int radius = int(size.z);
        int y0 = max(0, int(id.y) - radius), y1 = min(int(size.y), int(id.y) + radius + 1);
        float4 sum = 0;
        for (int y = y0; y < y1; y++) sum += rows[uint(y) * size.x + id.x];
        float4 mean = sum / float(y1 - y0);
        float variance = mean.z - mean.x * mean.x;
        float covariance = mean.w - mean.x * mean.y;
        float a = covariance / (variance + epsilon);
        coefficients[id.y * size.x + id.x] = float2(a, mean.y - a * mean.x);
    }

    // Each row's window means of a and b.
    kernel void coefficientRows(device const float2 *coefficients [[buffer(0)]], device float2 *rows [[buffer(1)]],
                                constant uint4 &size [[buffer(2)]], uint2 id [[thread_position_in_grid]]) {
        if (id.x >= size.x || id.y >= size.y) return;
        int radius = int(size.z);
        int x0 = max(0, int(id.x) - radius), x1 = min(int(size.x), int(id.x) + radius + 1);
        uint row = id.y * size.x;
        float2 sum = 0;
        for (int x = x0; x < x1; x++) sum += coefficients[row + uint(x)];
        rows[row + id.x] = sum / float(x1 - x0);
    }

    // The columns' means of a and b, applied to the guide.
    kernel void guidedOutput(device const float2 *rows [[buffer(0)]], device const float *guide [[buffer(1)]],
                             device float *output [[buffer(2)]], constant uint4 &size [[buffer(3)]],
                             uint2 id [[thread_position_in_grid]]) {
        if (id.x >= size.x || id.y >= size.y) return;
        int radius = int(size.z);
        int y0 = max(0, int(id.y) - radius), y1 = min(int(size.y), int(id.y) + radius + 1);
        float2 sum = 0;
        for (int y = y0; y < y1; y++) sum += rows[uint(y) * size.x + id.x];
        float2 mean = sum / float(y1 - y0);
        uint index = id.y * size.x + id.x;
        output[index] = clamp(mean.x * guide[index] + mean.y, 0.0, 1.0);
    }
    """
}
