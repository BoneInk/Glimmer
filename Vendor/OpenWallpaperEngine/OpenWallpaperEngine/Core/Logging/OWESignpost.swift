import Foundation
import QuartzCore
import os

enum OWESignpost {
    static let subsystem = "app.openwallpaperengine"

    static let render = OSLog(subsystem: subsystem, category: "Render")
    static let scene = OSLog(subsystem: subsystem, category: "Scene")
    static let audio = OSLog(subsystem: subsystem, category: "Audio")

    /// Scoped signpost interval. Hold the returned token; the interval ends when it deinits.
    struct Interval {
        let log: OSLog
        let name: StaticString
        let id: OSSignpostID

        init(_ log: OSLog, _ name: StaticString) {
            self.log = log
            self.name = name
            self.id = OSSignpostID(log: log)
            os_signpost(.begin, log: log, name: name, signpostID: id)
        }

        func end() {
            os_signpost(.end, log: log, name: name, signpostID: id)
        }
    }

    static func begin(_ log: OSLog, _ name: StaticString) -> Interval {
        Interval(log, name)
    }

    static func event(_ log: OSLog, _ name: StaticString) {
        os_signpost(.event, log: log, name: name)
    }
}
