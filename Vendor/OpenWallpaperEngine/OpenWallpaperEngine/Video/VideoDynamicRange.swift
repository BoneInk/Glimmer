import AVFoundation
import CoreMedia

/// The transfer function of a video's picture: SDR, or one of the two HDR ones (BT.2100 PQ, as
/// HDR10 and Dolby Vision 8.1 use, and HLG).
///
/// WE 2.8's "Scene DX11 (HDR Support)" video framework plays a HDR video through the scene
/// renderer as linear light, finished by `combine_video_hdr` (`SceneHDRChain`); an SDR video keeps
/// the 8-bit path. The transfer function comes from the first video track's format description,
/// as the decoder reads it.
enum VideoDynamicRange: Equatable, Sendable {
    case sdr
    case pq
    case hlg

    var isHDR: Bool { self != .sdr }

    /// The range a format description's transfer function says.
    init(transferFunction: String?) {
        switch transferFunction {
        case String(kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ): self = .pq
        case String(kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG): self = .hlg
        default: self = .sdr
        }
    }

    /// The range of `url`'s first video track, read from its format description; SDR when the file
    /// has no video track or can't be read (playback then reports that error itself). Blocks while
    /// AVFoundation reads the header, so call it off the main thread.
    static func of(_ url: URL) -> VideoDynamicRange {
        ThreadGuards.assertBackground("VideoDynamicRange.of")
        let result = LoadedRange()
        let done = DispatchSemaphore(value: 0)
        let asset = AVURLAsset(url: url)
        Task.detached {
            defer { done.signal() }
            do {
                guard let track = try await asset.loadTracks(withMediaType: .video).first,
                      let format = try await track.load(.formatDescriptions).first else { return }
                let transfer = CMFormatDescriptionGetExtension(
                    format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
                result.set(VideoDynamicRange(transferFunction: transfer))
            } catch {
                OWELog.error(.scene, "Could not read the format of video \(url.lastPathComponent): \(error)")
            }
        }
        done.wait()
        return result.value
    }
}

/// The range a detached load found, handed back to the thread that waits for it.
private final class LoadedRange: @unchecked Sendable {
    private let lock = NSLock()
    private var range = VideoDynamicRange.sdr
    /// Guarded by `lock`.
    var value: VideoDynamicRange { lock.withLock { range } }
    func set(_ value: VideoDynamicRange) { lock.withLock { range = value } }
}
