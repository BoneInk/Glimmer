import AVFoundation
import XCTest
@testable import OpenWallpaperEngine

/// A process tap's buffers converted to the pipeline's 48 kHz non-interleaved float stereo.
final class CaptureFormatConverterTests: XCTestCase {
    private func format(rate: Double, channels: AVAudioChannelCount, interleaved: Bool) throws -> AVAudioFormat {
        guard channels > 2 else {
            return try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                               channels: channels, interleaved: interleaved))
        }
        // More than two channels need a layout.
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels))
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, interleaved: interleaved,
                             channelLayout: layout)
    }

    /// `frames` frames of a sine per channel (channel c at amplitude `amplitudes[c]`), starting at
    /// frame `offset` so consecutive buffers continue the wave.
    private func sine(_ format: AVAudioFormat, frames: Int, offset: Int, frequency: Double = 440,
                      amplitudes: [Float]) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let channels = Int(format.channelCount)
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for frame in 0..<frames {
            let phase = 2 * Double.pi * frequency * Double(frame + offset) / format.sampleRate
            for channel in 0..<channels {
                let value = amplitudes[channel] * Float(sin(phase))
                if format.isInterleaved {
                    list[0].mData!.assumingMemoryBound(to: Float.self)[frame * channels + channel] = value
                } else {
                    list[channel].mData!.assumingMemoryBound(to: Float.self)[frame] = value
                }
            }
        }
        return buffer
    }

    /// Converts `count` consecutive buffers and returns the concatenated left and right channels.
    private func convert(_ converter: CaptureFormatConverter, buffers count: Int, frames: Int,
                         amplitudes: [Float]) throws -> (left: [Float], right: [Float]) {
        var left: [Float] = []
        var right: [Float] = []
        for index in 0..<count {
            let input = try sine(converter.inputFormat, frames: frames, offset: index * frames, amplitudes: amplitudes)
            guard let output = converter.convert(input) else { continue }
            XCTAssertEqual(output.format, CaptureFormatConverter.outputFormat)
            let channels = try XCTUnwrap(output.floatChannelData)
            let length = Int(output.frameLength)
            left += Array(UnsafeBufferPointer(start: channels[0], count: length))
            right += Array(UnsafeBufferPointer(start: channels[1], count: length))
        }
        return (left, right)
    }

    private func rms(_ samples: ArraySlice<Float>) -> Float {
        sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
    }

    func testOutputFormatIsWhatTheSpectrumExpects() {
        let output = CaptureFormatConverter.outputFormat
        XCTAssertEqual(output.sampleRate, 48_000)
        XCTAssertEqual(output.channelCount, 2)
        XCTAssertFalse(output.isInterleaved)
        XCTAssertEqual(output.commonFormat, .pcmFormatFloat32)
    }

    func testPipelineFormatPassesThroughUnchanged() throws {
        let converter = try XCTUnwrap(CaptureFormatConverter(inputFormat: CaptureFormatConverter.outputFormat))
        let input = try sine(CaptureFormatConverter.outputFormat, frames: 480, offset: 0, amplitudes: [0.5, 0.25])
        XCTAssertTrue(converter.convert(input) === input)
    }

    func testInterleaved44_1kHzIsResampledTo48kHzStereo() throws {
        let converter = try XCTUnwrap(CaptureFormatConverter(
            inputFormat: format(rate: 44_100, channels: 2, interleaved: true)))
        // One second in 100 buffers of 441 frames, as a tap delivers it.
        let (left, right) = try convert(converter, buffers: 100, frames: 441, amplitudes: [0.8, 0.4])
        XCTAssertEqual(left.count, right.count)
        XCTAssertEqual(Double(left.count), 48_000, accuracy: 256, "one second of input is about 48 000 frames")
        // A sine's RMS is amplitude / √2; skip the resampler's start-up.
        XCTAssertEqual(rms(left[4_800...]), 0.8 / Float(2).squareRoot(), accuracy: 0.02)
        XCTAssertEqual(rms(right[4_800...]), 0.4 / Float(2).squareRoot(), accuracy: 0.02, "channels stay apart")
    }

    func testInterleaved48kHzIsOnlyDeinterleaved() throws {
        let converter = try XCTUnwrap(CaptureFormatConverter(
            inputFormat: format(rate: 48_000, channels: 2, interleaved: true)))
        let (left, right) = try convert(converter, buffers: 10, frames: 480, amplitudes: [0.6, 0.3])
        XCTAssertEqual(left.count, 4_800)
        XCTAssertEqual(rms(left[...]), 0.6 / Float(2).squareRoot(), accuracy: 0.01)
        XCTAssertEqual(rms(right[...]), 0.3 / Float(2).squareRoot(), accuracy: 0.01)
    }

    func testMonoIsCopiedToBothChannels() throws {
        let converter = try XCTUnwrap(CaptureFormatConverter(
            inputFormat: format(rate: 48_000, channels: 1, interleaved: false)))
        let (left, right) = try convert(converter, buffers: 4, frames: 480, amplitudes: [0.5])
        XCTAssertFalse(left.isEmpty)
        XCTAssertEqual(left, right)
        XCTAssertEqual(rms(left[...]), 0.5 / Float(2).squareRoot(), accuracy: 0.01)
    }

    func testMoreThanTwoChannelsKeepFrontLeftAndRight() throws {
        let converter = try XCTUnwrap(CaptureFormatConverter(
            inputFormat: format(rate: 48_000, channels: 4, interleaved: true)))
        let (left, right) = try convert(converter, buffers: 4, frames: 480, amplitudes: [0.6, 0.2, 0.9, 0.9])
        XCTAssertEqual(rms(left[...]), 0.6 / Float(2).squareRoot(), accuracy: 0.01)
        XCTAssertEqual(rms(right[...]), 0.2 / Float(2).squareRoot(), accuracy: 0.01)
    }

    func testEmptyBufferGivesNothing() throws {
        let converter = try XCTUnwrap(CaptureFormatConverter(
            inputFormat: format(rate: 44_100, channels: 2, interleaved: true)))
        let empty = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: 16))
        XCTAssertNil(converter.convert(empty))
    }

    func testNonPCMInputIsRejected() throws {
        var description = AudioStreamBasicDescription(
            mSampleRate: 44_100, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        let aac = try XCTUnwrap(AVAudioFormat(streamDescription: &description))
        XCTAssertNil(CaptureFormatConverter(inputFormat: aac))
    }
}
