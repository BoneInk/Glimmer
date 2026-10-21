import Foundation

/// The message a failed `VersionedInstaller` install shows: one the user can act on for being
/// offline, an HTTP error and a full disk, else the error's own description.
enum VersionedInstallFailure {
    static func message(for error: Error, offline: () -> String, diskFull: () -> String) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
                 .dnsLookupFailed, .timedOut, .internationalRoamingOff, .dataNotAllowed:
                return offline()
            default:
                break
            }
        }
        if case URLSessionSteamCmdDownloader.Failure.httpStatus(let code) = error {
            return String(localized: "The download server answered with HTTP status \(code).",
                          comment: "Chromium engine install error; %lld is an HTTP status code")
        }
        if isDiskFull(error) {
            return diskFull()
        }
        return error.localizedDescription
    }

    /// The volume ran out of space, as Foundation, POSIX or a download reports it.
    static func isDiskFull(_ error: Error) -> Bool {
        let nsError = error as NSError
        return (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError)
            || (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOSPC))
            || (error as? URLError)?.code == .cannotWriteToFile
    }
}
