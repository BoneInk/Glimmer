import CoreAudio
import XCTest
@testable import OpenWallpaperEngine

/// Choosing between the Core Audio process tap and the ScreenCaptureKit fallback.
final class SystemAudioBackendTests: XCTestCase {
    private func candidates(tapSupported: Bool = true,
                            tap: SystemAudioRecordingPermission.Status,
                            screenRecording: Bool) -> [SystemAudioBackend] {
        SystemAudioBackend.candidates(tapSupported: tapSupported, tapPermission: tap,
                                      screenRecordingGranted: screenRecording)
    }

    func testGrantedTapIsTriedFirstWithScreenCaptureAsFallback() {
        XCTAssertEqual(candidates(tap: .authorized, screenRecording: true), [.processTap, .screenCapture])
        XCTAssertEqual(candidates(tap: .authorized, screenRecording: false), [.processTap])
    }

    func testTapNeverStartsWithoutItsPermission() {
        // Starting it then would show the prompt (not asked yet) or deliver silence (denied).
        XCTAssertEqual(candidates(tap: .notDetermined, screenRecording: false), [])
        XCTAssertEqual(candidates(tap: .denied, screenRecording: false), [])
        XCTAssertEqual(candidates(tap: .denied, screenRecording: true), [.screenCapture])
        XCTAssertEqual(candidates(tap: .notDetermined, screenRecording: true), [.screenCapture])
    }

    func testUnreadableTapPermissionStillTriesTheTap() {
        XCTAssertEqual(candidates(tap: .unknown, screenRecording: false), [.processTap])
        XCTAssertEqual(candidates(tap: .unknown, screenRecording: true), [.processTap, .screenCapture])
    }

    func testBeforeMacOS14_2OnlyScreenCaptureIsUsed() {
        XCTAssertEqual(candidates(tapSupported: false, tap: .authorized, screenRecording: true), [.screenCapture])
        XCTAssertEqual(candidates(tapSupported: false, tap: .authorized, screenRecording: false), [])
    }

    func testRequestedPermissionFollowsTheBackend() {
        XCTAssertEqual(SystemAudioBackend.requestedPermission(tapSupported: true), .processTap)
        XCTAssertEqual(SystemAudioBackend.requestedPermission(tapSupported: false), .screenCapture)
    }

    func testPreflightResultsMapToStatuses() {
        XCTAssertEqual(SystemAudioRecordingPermission.status(preflightResult: 0), .authorized)
        XCTAssertEqual(SystemAudioRecordingPermission.status(preflightResult: 1), .denied)
        XCTAssertEqual(SystemAudioRecordingPermission.status(preflightResult: 2), .notDetermined)
    }

    // MARK: Aggregate device

    func testAggregateDeviceIsPrivateAndCarriesTheTap() {
        let description = ProcessTapAudioCapture.aggregateDescription(outputUID: "speakers", tapUID: "tap-uid")
        XCTAssertEqual(description[kAudioAggregateDeviceIsPrivateKey] as? Bool, true)
        XCTAssertEqual(description[kAudioAggregateDeviceTapAutoStartKey] as? Bool, true)
        XCTAssertEqual(description[kAudioAggregateDeviceMainSubDeviceKey] as? String, "speakers")
        let taps = description[kAudioAggregateDeviceTapListKey] as? [[String: Any]]
        XCTAssertEqual(taps?.count, 1)
        XCTAssertEqual(taps?.first?[kAudioSubTapUIDKey] as? String, "tap-uid")
        let unique = ProcessTapAudioCapture.aggregateDescription(outputUID: "speakers", tapUID: "tap-uid")
        XCTAssertNotEqual(description[kAudioAggregateDeviceUIDKey] as? String,
                          unique[kAudioAggregateDeviceUIDKey] as? String, "each capture gets its own device")
    }

    func testTapBuffersAreTheTrailingOnes() {
        let storage = (0..<3).map { _ in UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 4) }
        let all = AudioBufferList.allocate(maximumBuffers: 3)
        let target = AudioBufferList.allocate(maximumBuffers: 1)
        defer {
            storage.forEach { $0.deallocate() }
            free(all.unsafeMutablePointer)
            free(target.unsafeMutablePointer)
        }
        for index in 0..<3 {
            all[index] = AudioBuffer(mNumberChannels: 2, mDataByteSize: 8, mData: storage[index])
        }
        XCTAssertTrue(ProcessTapAudioCapture.copyTrailingBuffers(from: all, into: target))
        XCTAssertEqual(target[0].mData, all[2].mData, "a microphone's input streams come before the tap")

        let tooMany = AudioBufferList.allocate(maximumBuffers: 4)
        defer { free(tooMany.unsafeMutablePointer) }
        XCTAssertFalse(ProcessTapAudioCapture.copyTrailingBuffers(from: all, into: tooMany))
    }
}
