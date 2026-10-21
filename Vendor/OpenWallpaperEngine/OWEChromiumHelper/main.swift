import Foundation

// owe-chromium-helper: the XPC service that hosts CEF for Open Wallpaper Engine, so the app never
// loads Chromium. CEF also starts this executable for its renderer, GPU and utility processes;
// those runs carry a `--type=` switch and only run CEF's subprocess entry point.

if owe_cef_is_subprocess(CommandLine.argc, CommandLine.unsafeArgv) != 0 {
    exit(owe_cef_run_subprocess(CommandLine.argc, CommandLine.unsafeArgv))
}

owe_cef_prepare_application()
let listenerDelegate = ChromiumHelperListenerDelegate()
let listener = NSXPCListener.service()
listener.delegate = listenerDelegate
// Runs the main thread's NSRunLoop (Info.plist RunLoopType) and never returns.
listener.resume()
