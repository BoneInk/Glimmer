import Foundation
import notify

/// Announces a ring's newest frame: sets its notification's state to the stamp and posts it.
protocol ScreenSaverFrameNotifier: AnyObject, Sendable {
    func post(_ name: String, state: UInt64)
}

/// Darwin notifications, which the `.saver`'s sandboxed host may read (`notify_get_state`).
final class DarwinFrameNotifier: ScreenSaverFrameNotifier, @unchecked Sendable { // `lock` owns `tokens`.
    private let lock = NSLock()
    private var tokens: [String: Int32] = [:]

    func post(_ name: String, state: UInt64) {
        let token: Int32? = lock.withLock {
            if let token = tokens[name] { return token }
            var token: Int32 = 0
            guard notify_register_check(name, &token) == UInt32(NOTIFY_STATUS_OK) else { return nil }
            tokens[name] = token
            return token
        }
        guard let token else {
            OWELog.error(.app, "Live screen saver: can't register \(name)")
            return
        }
        notify_set_state(token, state)
        notify_post(name)
    }

    deinit {
        for token in tokens.values { notify_cancel(token) }
    }
}
