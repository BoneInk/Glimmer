import Foundation

/// The process `NowPlayingAdapter` streams from: `/usr/bin/perl` running `nowPlayingAdapter.pl`
/// in the app (`PerlNowPlayingAdapterProcess`), a recording in tests.
protocol NowPlayingAdapterProcess: AnyObject {
    /// Starts it. `output` receives its standard output in chunks as they come, and `exit` its
    /// status once it has ended, each on any thread.
    func start(output: @escaping (Data) -> Void, exit: @escaping (Int32) -> Void) throws

    /// Ends it: closes its input, which makes it exit, and terminates it.
    func stop()
}
