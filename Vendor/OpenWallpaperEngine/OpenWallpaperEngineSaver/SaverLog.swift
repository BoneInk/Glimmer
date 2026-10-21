import Foundation
import os

/// The savers' log (the `.saver` and the extension; the app logs through `OWELog`). The lab
/// builds (`OWE_SAVER_LAB`, `Scripts/build-saver-lab.sh`) log under the lab subsystem the live
/// screen saver's Phase 0 reads; key events are `.notice` so `log show` keeps them.
enum SaverLog {
    #if OWE_SAVER_LAB
    static let subsystem = "app.openwallpaper.engine.saverlab"
    #else
    static let subsystem = "app.openwallpaperengine.saver"
    #endif

    static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
    static let frames = Logger(subsystem: subsystem, category: "frames")
    static let transport = Logger(subsystem: subsystem, category: "transport")
    static let cost = Logger(subsystem: subsystem, category: "cost")
}
