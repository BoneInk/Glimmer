import CoreAudio
import Foundation

/// Whether an application other than this one plays sound, from Core Audio's process objects
/// (macOS 14.2 and later; earlier systems report none).
final class OtherApplicationAudio {
    private let ownPID: pid_t
    private var reportedFailure = false

    init(ownPID: pid_t) {
        self.ownPID = ownPID
    }

    /// `ignoringWebKit` leaves out WebKit's helper processes, which play web wallpapers' sound.
    func isPlaying(ignoringWebKit: Bool) -> Bool {
        guard #available(macOS 14.2, *) else { return false }
        let processes: [AudioObjectID]
        switch CoreAudioProcessObjects.list() {
        case .success(let list):
            processes = list
        case .failure(let error):
            if !reportedFailure {
                reportedFailure = true
                OWELog.error(.audio, "Core Audio's process list can't be read (\(error)); \"Other application playing audio\" sees no audio")
            }
            return false
        }
        for process in processes {
            guard let pid = CoreAudioProcessObjects.pid(of: process), pid != ownPID,
                  CoreAudioProcessObjects.isRunningOutput(process) == true else { continue }
            if ignoringWebKit, CoreAudioProcessObjects.bundleIdentifier(of: process)?.hasPrefix("com.apple.WebKit") == true { continue }
            return true
        }
        return false
    }
}
