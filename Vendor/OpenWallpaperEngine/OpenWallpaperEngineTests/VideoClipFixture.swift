import AVFoundation
import CoreVideo
import VideoToolbox
import XCTest

/// A short H.264 clip written on the fly, for tests that need a real movie to play.
enum VideoClipFixture {
    /// `frames` frames at `fps`, 64×64, each a flat grey that brightens frame by frame.
    static func make(frames: Int, fps: Int32 = 30, in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "clip.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for index in 0..<frames {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.001) }
            let pool = try XCTUnwrap(adaptor.pixelBufferPool)
            var created: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created)
            let buffer = try XCTUnwrap(created)
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
            let value: Int32 = Int32(index * 255 / max(1, frames - 1))
            memset(base, value, CVPixelBufferGetBytesPerRow(buffer) * 64)
            CVPixelBufferUnlockBaseAddress(buffer, [])
            let time = CMTime(value: CMTimeValue(index), timescale: fps)
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: time))
        }
        input.markAsFinished()
        let done = XCTestExpectation(description: "clip written")
        writer.finishWriting { done.fulfill() }
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 10), .completed)
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
        return url
    }

    /// A 10-bit HEVC clip in BT.2020 with `transfer` (PQ or HLG), `frames` frames of 64×64 in four
    /// vertical bands: grey at the code values `bands` gives, and a red-only band (R = `bands[0]`).
    /// The values are signals in 0…1 (`pqSignal(nits:)` for PQ).
    static func makeHDR(transfer: String, bands: [Double], frames: Int = 30, in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "hdr-clip.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                                        AVVideoTransferFunctionKey: transfer,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020],
            AVVideoCompressionPropertiesKey: [AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String],
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let bufferTransfer: CFString = transfer == AVVideoTransferFunction_ITU_R_2100_HLG
            ? kCVImageBufferTransferFunction_ITU_R_2100_HLG : kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        for index in 0..<frames {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.001) }
            let pool = try XCTUnwrap(adaptor.pixelBufferPool)
            var created: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created)
            let buffer = try XCTUnwrap(created)
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, bufferTransfer, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
            let row = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<64 {
                let pixels = (base + y * row).assumingMemoryBound(to: Float16.self)
                for x in 0..<64 {
                    let band = x / 16
                    let grey = Float16(bands[min(band, bands.count - 1)])
                    let rgb: [Float16] = band == 3 ? [Float16(bands[0]), 0, 0] : [grey, grey, grey]
                    pixels[x * 4] = rgb[0]
                    pixels[x * 4 + 1] = rgb[1]
                    pixels[x * 4 + 2] = rgb[2]
                    pixels[x * 4 + 3] = 1
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 30)))
        }
        input.markAsFinished()
        let done = XCTestExpectation(description: "HDR clip written")
        writer.finishWriting { done.fulfill() }
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 10), .completed)
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
        return url
    }

    /// The PQ signal (SMPTE ST 2084 inverse EOTF) of `nits`.
    static func pqSignal(nits: Double) -> Double {
        let m1 = 2610.0 / 16384, m2 = 2523.0 / 4096 * 128
        let c1 = 3424.0 / 4096, c2 = 2413.0 / 4096 * 32, c3 = 2392.0 / 4096 * 32
        let y = pow(nits / 10000, m1)
        return pow((c1 + c2 * y) / (1 + c3 * y), m2)
    }
}
