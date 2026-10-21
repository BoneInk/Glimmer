import CoreAudio
import Foundation

/// Which processes play sound, for Application Rules' "is playing audio", followed through Core
/// Audio's property listeners instead of a poll: one on the process list (a process starting or
/// stopping to use audio) and one on each process's `kAudioProcessPropertyIsRunningOutput`.
///
/// Reading every process object costs about 2 ms of CPU and a round trip to `coreaudiod` per
/// process, so it happens once when the watch starts and then only for processes that appear;
/// afterwards the listeners say what changed and `playingBundleIdentifiers` is a read under a
/// lock. Needs macOS 14.2 (the process objects); on earlier systems the watch reports nothing,
/// which the rule editor says.
///
/// `queue` owns `processes` and the listeners; `lock` guards `playing`, which the monitor's scan
/// queue reads.
final class ProcessAudioOutputWatch: @unchecked Sendable {
    /// Process objects of the sound-playing processes need macOS 14.2.
    static var isSupported: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    private let ownPID: pid_t
    private let queue = DispatchQueue(label: "OpenWallpaperEngine.ProcessAudioOutputWatch", qos: .utility)
    /// Called on `queue` whenever `playingBundleIdentifiers` changed.
    private var changed: (@Sendable () -> Void)?
    private var processes: [AudioObjectID: Process] = [:]
    private var listListener: AudioObjectPropertyListenerBlock?
    private let lock = NSLock()
    private var playing: Set<String> = []

    private struct Process {
        var bundleIdentifier: String?
        var isPlaying: Bool
        var listener: AudioObjectPropertyListenerBlock
    }

    init(ownPID: pid_t) {
        self.ownPID = ownPID
    }

    deinit {
        // The listener blocks hold the watch weakly; removing them needs no queue hop.
        removeListeners()
    }

    /// The bundle identifiers of the processes playing sound now, without this app's.
    var playingBundleIdentifiers: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return playing
    }

    /// Starts following the processes; `changed` is called on a background queue when the set of
    /// sound-playing processes changes. Starting again replaces `changed`.
    func start(changed: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            self.changed = changed
            guard listListener == nil else { return }
            guard #available(macOS 14.2, *) else { return }
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refreshList() }
            var address = CoreAudioProcessObjects.address(kAudioHardwarePropertyProcessObjectList)
            let status = AudioObjectAddPropertyListenerBlock(CoreAudioProcessObjects.system, &address, queue, listener)
            guard status == noErr else {
                OWELog.error(.audio, "Core Audio's process list can't be watched (OSStatus \(status)); \"Is playing audio\" rules see no audio")
                return
            }
            listListener = listener
            refreshList()
        }
    }

    /// Stops listening and forgets the processes.
    func stop() {
        queue.async { [self] in
            changed = nil
            removeListeners()
            publish()
        }
    }

    /// Adds listeners to processes that appeared and drops those that are gone. On `queue`.
    private func refreshList() {
        guard #available(macOS 14.2, *) else { return }
        let current: [AudioObjectID]
        switch CoreAudioProcessObjects.list() {
        case .success(let list): current = list
        case .failure(let error):
            OWELog.error(.audio, "Core Audio's process list can't be read (\(error)); \"Is playing audio\" rules keep the last state")
            return
        }
        let present = Set(current)
        for (object, process) in processes where !present.contains(object) {
            removeListener(process.listener, from: object)
            processes[object] = nil
        }
        for object in current where processes[object] == nil {
            // A process that quit between the list and these reads has no pid: skip it.
            guard let pid = CoreAudioProcessObjects.pid(of: object), pid != ownPID else { continue }
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refreshProcess(object) }
            var address = CoreAudioProcessObjects.address(kAudioProcessPropertyIsRunningOutput)
            let status = AudioObjectAddPropertyListenerBlock(object, &address, queue, listener)
            if status != noErr {
                OWELog.debug(.audio, "Core Audio process \(object) can't be watched (OSStatus \(status))")
                continue
            }
            processes[object] = Process(bundleIdentifier: CoreAudioProcessObjects.bundleIdentifier(of: object),
                                        isPlaying: CoreAudioProcessObjects.isRunningOutput(object) ?? false,
                                        listener: listener)
        }
        publish()
    }

    /// One process started or stopped playing. On `queue`.
    private func refreshProcess(_ object: AudioObjectID) {
        guard #available(macOS 14.2, *), processes[object] != nil else { return }
        processes[object]?.isPlaying = CoreAudioProcessObjects.isRunningOutput(object) ?? false
        publish()
    }

    /// Updates `playing`, and calls `changed` when it changed. On `queue`.
    private func publish() {
        let next = Set(processes.values.filter(\.isPlaying).compactMap(\.bundleIdentifier))
        lock.lock()
        let isChange = next != playing
        playing = next
        lock.unlock()
        if isChange { changed?() }
    }

    private func removeListeners() {
        for (object, process) in processes { removeListener(process.listener, from: object) }
        processes.removeAll()
        if #available(macOS 14.2, *), let listListener {
            var address = CoreAudioProcessObjects.address(kAudioHardwarePropertyProcessObjectList)
            _ = AudioObjectRemovePropertyListenerBlock(CoreAudioProcessObjects.system, &address, queue, listListener)
            self.listListener = nil
        }
    }

    private func removeListener(_ listener: @escaping AudioObjectPropertyListenerBlock, from object: AudioObjectID) {
        guard #available(macOS 14.2, *) else { return }
        var address = CoreAudioProcessObjects.address(kAudioProcessPropertyIsRunningOutput)
        // A process that already quit has dropped its listeners; the status doesn't matter.
        _ = AudioObjectRemovePropertyListenerBlock(object, &address, queue, listener)
    }
}
