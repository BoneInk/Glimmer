import Carbon.HIToolbox
import Foundation

/// What registering a global shortcut came to.
enum HotKeyRegistration: Equatable {
    case registered
    /// `eventHotKeyExistsErr`: another app holds the shortcut (macOS doesn't say which).
    case takenByAnotherApp
    case failed(OSStatus)
}

/// Registers system-wide shortcuts. `CarbonHotKeyRegistrar` is the real one; tests use a fake.
@MainActor
protocol HotKeyRegistering: AnyObject {
    /// Called with the id of a registered shortcut when it is pressed.
    var onPress: ((UInt32) -> Void)? { get set }
    func register(_ shortcut: GlobalShortcut, id: UInt32) -> HotKeyRegistration
    func unregister(id: UInt32)
}

/// Global shortcuts through Carbon's `RegisterEventHotKey`, which needs no Accessibility
/// permission: macOS delivers the press to this app whichever app is in front. Each registrar
/// has its own signature and handler, and passes on the presses of hot keys it didn't register.
@MainActor
final class CarbonHotKeyRegistrar: HotKeyRegistering {
    var onPress: ((UInt32) -> Void)?
    private var hotKeys: [UInt32: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    /// Identifies this registrar's hot keys in the events.
    private let signature: OSType
    /// "OWEp": the playlists' shortcuts.
    static let playlistSignature: OSType = 0x4F57_4570
    /// "OWEh": the hotkey actions'.
    static let actionSignature: OSType = 0x4F57_4568

    init(signature: OSType = CarbonHotKeyRegistrar.playlistSignature) {
        self.signature = signature
    }

    func register(_ shortcut: GlobalShortcut, id: UInt32) -> HotKeyRegistration {
        installHandlerIfNeeded()
        unregister(id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.carbonModifiers,
                                         EventHotKeyID(signature: signature, id: id),
                                         GetEventDispatcherTarget(), 0, &ref)
        switch status {
        case noErr:
            if let ref { hotKeys[id] = ref }
            return .registered
        case OSStatus(eventHotKeyExistsErr):
            return .takenByAnotherApp
        default:
            return .failed(status)
        }
    }

    func unregister(id: UInt32) {
        guard let ref = hotKeys.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(ref)
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return OSStatus(eventNotHandledErr) }
            let registrar = Unmanaged<CarbonHotKeyRegistrar>.fromOpaque(context).takeUnretainedValue()
            let id = hotKeyID.id
            // Carbon dispatches on the main thread's event loop. Another registrar's press goes on
            // to its handler.
            return MainActor.assumeIsolated {
                guard hotKeyID.signature == registrar.signature, registrar.hotKeys[id] != nil else {
                    return OSStatus(eventNotHandledErr)
                }
                registrar.onPress?(id)
                return noErr
            }
        }, 1, &spec, context, &handler)
    }
}
