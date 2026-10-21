import AVFoundation

/// Converts captured PCM to the format the consumer pipeline (`SystemAudioCapture.consume`, the
/// level and `AudioSpectrumAnalyzer`) is built for: 48 kHz, non-interleaved float32 stereo, the
/// format the ScreenCaptureKit stream delivers.
///
/// A process tap delivers the output device's format instead: any rate, usually interleaved.
/// Mono is copied to both channels and more than two channels keep the first two (front left and
/// right). Resampling state carries over between buffers, so call it with consecutive buffers of
/// one stream on one thread.
final class CaptureFormatConverter {
    static let outputSampleRate: Double = 48_000
    // Float32 non-interleaved stereo at a positive rate is always a valid format.
    static let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outputSampleRate,
                                            channels: 2, interleaved: false)!

    let inputFormat: AVAudioFormat
    /// nil when the input already is the output format.
    private let converter: AVAudioConverter?

    /// nil when the format can't be converted (not linear PCM, or no channels).
    init?(inputFormat: AVAudioFormat) {
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0,
              inputFormat.streamDescription.pointee.mFormatID == kAudioFormatLinearPCM else { return nil }
        self.inputFormat = inputFormat
        if Self.matchesOutput(inputFormat) {
            converter = nil
            return
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: Self.outputFormat) else { return nil }
        if inputFormat.channelCount != 2 {
            // Output channel i reads input channel channelMap[i].
            converter.channelMap = inputFormat.channelCount == 1 ? [0, 0] : [0, 1]
        }
        self.converter = converter
    }

    private static func matchesOutput(_ format: AVAudioFormat) -> Bool {
        format.commonFormat == .pcmFormatFloat32 && !format.isInterleaved && format.channelCount == 2
            && format.sampleRate == outputSampleRate
    }

    /// The converted frames, or nil when there are none yet (a resampler holds back a few frames
    /// at the start) or conversion failed. Returns `buffer` itself when no conversion is needed.
    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else { return nil }
        guard let converter else { return buffer }
        let ratio = Self.outputSampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            // `.noDataNow`, not `.endOfStream`: the resampler keeps its state for the next buffer.
            guard !supplied else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            OWELog.debug(.audio, "Captured audio conversion failed: \(error?.localizedDescription ?? "unknown error")")
            return nil
        }
        return output.frameLength > 0 ? output : nil
    }
}
