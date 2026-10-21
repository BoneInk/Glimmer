import AppKit

/// Quits and opens the app again, e.g. so a new language applies (macOS reads an app's language
/// at launch). The new copy gets the same launch arguments and isolated-state tag, so a
/// development copy stays isolated; a test or preview host never relaunches (`AppHostContext`).
enum AppRelauncher {
    /// This app's own executable, for launching a background helper copy of it.
    nonisolated static var helperExecutable: URL? { Bundle.main.executableURL }

    /// How a copy this process opens through LaunchServices is configured: `host`'s isolated state
    /// (`AppHostContext.relaunchEnvironment`) is its whole environment, so an isolated copy only
    /// ever opens an isolated copy under the same tag, and the user's launch a plain one.
    nonisolated static func configuration(arguments: [String], host: AppHostContext,
                                          newInstance: Bool) -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = newInstance
        configuration.arguments = arguments
        configuration.environment = host.relaunchEnvironment
        return configuration
    }

    @MainActor
    static func relaunch(host: AppHostContext = .current) {
        guard host.mayRelaunch else {
            OWELog.error(.settings, "Not relaunching Open Wallpaper Engine: it runs as a test or preview host")
            return
        }
        let configuration = configuration(arguments: Array(CommandLine.arguments.dropFirst()), host: host, newInstance: true)
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error {
                    OWELog.error(.settings, "Can't relaunch Open Wallpaper Engine: \(error)")
                    return
                }
                AppTermination.shared.quit()
            }
        }
    }
}
