import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import Vision

/// A monocular depth model: a picture in, its raw depth out at the model's own resolution.
/// The generator loads one only while it generates (`DepthMapGenerator`).
public protocol DepthEstimating: AnyObject, Sendable {
    /// Larger values are nearer (relative inverse depth, as Depth Anything gives).
    var outputIsInverseDepth: Bool { get }
    func estimate(_ image: CGImage) throws -> DepthMapBuffer
}

/// Depth Anything V2 Small (Apple's Core ML package, `DepthAnythingV2SmallF16`), on every
/// compute unit Core ML picks (`.all`: the Neural Engine where it can). The input and output are
/// read from the model's description rather than assumed: an image input (518 × 392 for Apple's
/// package, the picture stretched to fill it) and an image or array output.
public final class CoreMLDepthEstimator: DepthEstimating, @unchecked Sendable { // `lock` guards `model`.
    public enum Failure: LocalizedError {
        case noImageInput
        case noOutput
        case unreadableOutput

        public var errorDescription: String? {
            switch self {
            case .noImageInput, .noOutput: return DL("The depth model isn’t one this app can use. Reinstall Depth Map Generation in Settings › Plugins.")
            case .unreadableOutput: return DL("The depth model gave a result this app can’t read.")
            }
        }
    }

    public let outputIsInverseDepth = true
    private let model: MLModel
    private let inputName: String
    private let constraint: MLImageConstraint
    private let outputName: String
    private let lock = NSLock()

    /// Loads the compiled model at `url`.
    public init(contentsOf url: URL) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        model = try MLModel(contentsOf: url, configuration: configuration)
        let description = model.modelDescription
        guard let (name, input) = description.inputDescriptionsByName.first(where: { $0.value.type == .image }),
              let constraint = input.imageConstraint else { throw Failure.noImageInput }
        inputName = name
        self.constraint = constraint
        let outputs = description.outputDescriptionsByName
        guard let output = outputs.first(where: { $0.value.type == .image })?.key
                ?? outputs.first(where: { $0.value.type == .multiArray })?.key else { throw Failure.noOutput }
        outputName = output
    }

    public func estimate(_ image: CGImage) throws -> DepthMapBuffer {
        try lock.withLock {
            try autoreleasepool {
                let value = try MLFeatureValue(cgImage: image, constraint: constraint,
                                               options: [.cropAndScale: VNImageCropAndScaleOption.scaleFill.rawValue])
                let input = try MLDictionaryFeatureProvider(dictionary: [inputName: value])
                let output = try model.prediction(from: input)
                guard let feature = output.featureValue(for: outputName) else { throw Failure.unreadableOutput }
                if let buffer = feature.imageBufferValue { return try Self.read(buffer) }
                if let array = feature.multiArrayValue { return try Self.read(array) }
                throw Failure.unreadableOutput
            }
        }
    }

    // MARK: Reading the output

    static func read(_ buffer: CVPixelBuffer) throws -> DepthMapBuffer {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw Failure.unreadableOutput }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        var values = [Float](repeating: 0, count: width * height)
        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_OneComponent16Half:
            for y in 0..<height {
                let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt16.self)
                for x in 0..<width { values[y * width + x] = halfToFloat(row[x]) }
            }
        case kCVPixelFormatType_OneComponent32Float:
            for y in 0..<height {
                let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: Float.self)
                for x in 0..<width { values[y * width + x] = row[x] }
            }
        case kCVPixelFormatType_OneComponent8:
            for y in 0..<height {
                let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width { values[y * width + x] = Float(row[x]) / 255 }
            }
        case kCVPixelFormatType_32BGRA, kCVPixelFormatType_32ARGB:
            for y in 0..<height {
                let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                // Grey either way: any colour channel.
                for x in 0..<width { values[y * width + x] = Float(row[x * 4 + 1]) / 255 }
            }
        default:
            throw Failure.unreadableOutput
        }
        return DepthMapBuffer(width: width, height: height, values: values)
    }

    static func read(_ array: MLMultiArray) throws -> DepthMapBuffer {
        let shape = array.shape.map(\.intValue)
        guard shape.count >= 2 else { throw Failure.unreadableOutput }
        let height = shape[shape.count - 2], width = shape[shape.count - 1]
        let strides = array.strides.map(\.intValue)
        let rowStride = strides[strides.count - 2], columnStride = strides[strides.count - 1]
        var values = [Float](repeating: 0, count: width * height)
        let pointer = array.dataPointer
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * rowStride + x * columnStride
                let value: Float
                switch array.dataType {
                case .float32: value = pointer.assumingMemoryBound(to: Float.self)[offset]
                case .double: value = Float(pointer.assumingMemoryBound(to: Double.self)[offset])
                case .float16: value = halfToFloat(pointer.assumingMemoryBound(to: UInt16.self)[offset])
                case .int32: value = Float(pointer.assumingMemoryBound(to: Int32.self)[offset])
                default: throw Failure.unreadableOutput
                }
                values[y * width + x] = value
            }
        }
        return DepthMapBuffer(width: width, height: height, values: values)
    }

    /// IEEE 754 half to float, on every architecture.
    static func halfToFloat(_ bits: UInt16) -> Float {
        let sign = UInt32(bits & 0x8000) << 16
        let exponent = Int((bits >> 10) & 0x1f)
        let mantissa = UInt32(bits & 0x3ff)
        if exponent == 0 {
            if mantissa == 0 { return Float(bitPattern: sign) }
            let value = Float(mantissa) / 1024 * powf(2, -14)
            return sign == 0 ? value : -value
        }
        if exponent == 31 {
            return Float(bitPattern: sign | 0x7f80_0000 | (mantissa << 13))
        }
        return Float(bitPattern: sign | (UInt32(exponent + 112) << 23) | (mantissa << 13))
    }
}
