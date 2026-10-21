import AVFoundation
import Accelerate

/// RMS level of one `AVPlayerItem`'s own audio.
///
/// The system-wide ScreenCaptureKit capture in `WallpaperServices` cannot tell a
/// wallpaper's own soundtrack apart from whatever else is playing, so music sync needs a tap on
/// the wallpaper's audio track to drive visuals from its own music.
final class AudioLevelTap {
    /// Shared with the C tap callbacks, which run on a realtime audio thread.
    final class Storage {
        private let lock = NSLock()
        private var value: Double = 0

        var level: Double {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func store(_ newValue: Double) {
            lock.lock()
            value = newValue
            lock.unlock()
        }
    }

    private let storage = Storage()
    private let stateLock = NSLock()
    private var isAttached = false
    private var attachGeneration = 0

    var level: Double { storage.level }

    /// Whether a tap is installed. Many video wallpapers have no audio track at all; callers then
    /// need another level source, because `level` would stay 0 forever.
    var isMeasuring: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isAttached
    }

    /// Starts a new attachment and returns its token; an older, slower attach must not mark the
    /// newly attached item as measured.
    private func beginAttach() -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        attachGeneration &+= 1
        isAttached = false
        return attachGeneration
    }

    private func finishAttach(_ generation: Int) {
        stateLock.lock()
        if generation == attachGeneration { isAttached = true }
        stateLock.unlock()
    }

    /// Installs the tap on `item`'s first audio track. Track loading is async, so the level stays
    /// at 0 until it completes.
    func attach(to item: AVPlayerItem) {
        let generation = beginAttach()
        storage.store(0)
        let asset = item.asset
        Task { [weak self] in
            guard let self,
                  let track = await OWELog.attemptAsync(.audio, "Video audio level: the movie's tracks", {
                      try await asset.loadTracks(withMediaType: .audio).first
                  }) ?? nil else { return }
            guard let tap = self.makeTap() else { return }
            self.finishAttach(generation)
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.audioTapProcessor = tap
            let mix = AVMutableAudioMix()
            mix.inputParameters = [parameters]
            await MainActor.run { item.audioMix = mix }
        }
    }

    private func makeTap() -> MTAudioProcessingTap? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(storage).toOpaque()),
            init: audioLevelTapInit,
            finalize: audioLevelTapFinalize,
            prepare: nil,
            unprepare: nil,
            process: audioLevelTapProcess
        )
        // The SDK in Xcode 26+ returns the tap directly; earlier SDKs (CI's Xcode 16) as Unmanaged.
        #if compiler(>=6.2)
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                                kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr else { return nil }
        return tap
        #else
        var tap: Unmanaged<MTAudioProcessingTap>?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                                kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr else { return nil }
        return tap?.takeRetainedValue()
        #endif
    }
}

private func audioLevelTapInit(tap: MTAudioProcessingTap,
                               clientInfo: UnsafeMutableRawPointer?,
                               tapStorageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>) {
    tapStorageOut.pointee = clientInfo
}

private func audioLevelTapFinalize(tap: MTAudioProcessingTap) {
    Unmanaged<AudioLevelTap.Storage>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
}

private func audioLevelTapProcess(tap: MTAudioProcessingTap,
                                  numberFrames: CMItemCount,
                                  flags: MTAudioProcessingTapFlags,
                                  bufferListInOut: UnsafeMutablePointer<AudioBufferList>,
                                  numberFramesOut: UnsafeMutablePointer<CMItemCount>,
                                  flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>) {
    guard MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut,
                                             flagsOut, nil, numberFramesOut) == noErr else { return }
    let storage = Unmanaged<AudioLevelTap.Storage>
        .fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()

    var squaredSum: Float = 0
    var sampleCount = 0
    for buffer in UnsafeMutableAudioBufferListPointer(bufferListInOut) {
        guard let data = buffer.mData else { continue }
        let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        guard count > 0 else { continue }
        var partial: Float = 0
        vDSP_svesq(data.assumingMemoryBound(to: Float.self), 1, &partial, vDSP_Length(count))
        squaredSum += partial
        sampleCount += count
    }
    guard sampleCount > 0 else { return }
    // Matches the gain the ScreenCaptureKit path applies, so sync amounts feel the same
    // regardless of which source is driving them.
    storage.store(min(Double(sqrt(squaredSum / Float(sampleCount))) * 8, 1))
}
