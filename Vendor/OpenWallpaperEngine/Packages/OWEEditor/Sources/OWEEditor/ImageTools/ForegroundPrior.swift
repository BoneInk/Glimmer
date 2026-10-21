import CoreVideo
import OWESceneEditing
import Vision

/// The automatic part of Foreground Separation on a Mac: the objects macOS's Vision finds in front
/// of the picture's background (`VNGenerateForegroundInstanceMaskRequest`, on the device, nothing
/// downloaded), each as a 0…1 mask at the picture's size. WE's editor starts from the strokes
/// alone; this gives an unmarked picture a separation to correct.
enum ForegroundPrior {
    static func instances(of image: CGImage) throws -> [ImagePlane] {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first else { return [] }
        return try observation.allInstances.map { (instance: Int) -> ImagePlane in
            let buffer = try observation.generateScaledMaskForImage(forInstances: IndexSet(integer: instance), from: handler)
            return plane(buffer, width: image.width, height: image.height)
        }
    }

    /// A one-channel float mask as a plane of the picture's size.
    private static func plane(_ buffer: CVPixelBuffer, width: Int, height: Int) -> ImagePlane {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let bufferWidth = CVPixelBufferGetWidth(buffer), bufferHeight = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var plane = ImagePlane(width: bufferWidth, height: bufferHeight)
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent32Float else { return ImagePlane(width: width, height: height) }
        for y in 0..<bufferHeight {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float.self)
            for x in 0..<bufferWidth { plane.pixels[y * bufferWidth + x] = row[x] }
        }
        return bufferWidth == width && bufferHeight == height ? plane : plane.resized(width: width, height: height)
    }
}
