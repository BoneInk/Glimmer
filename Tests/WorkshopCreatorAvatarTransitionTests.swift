import AppKit
import SwiftUI

@main @MainActor
enum WorkshopCreatorAvatarTransitionTests {
    static func main() {
        var checks = 0
        func check(_ condition: Bool, _ name: String) {
            precondition(condition, name); checks += 1; print("PASS \(name)")
        }
        let transition = WorkshopCreatorAvatarTransition()
        let sourceKey = WorkshopCreatorAvatarKey(authorID: "author", role: .detail)
        let targetKey = WorkshopCreatorAvatarKey(authorID: "author", role: .gallery)
        let image = NSImage(size: NSSize(width: 44, height: 44))
        let source = WorkshopCreatorAvatarGeometry(frame: CGRect(x: 42, y: 640, width: 44, height: 44), image: image)
        let target = WorkshopCreatorAvatarGeometry(frame: CGRect(x: 300, y: 36, width: 44, height: 44), image: nil)
        transition.update([sourceKey: source])
        transition.begin(authorID: "author", reduceMotion: false)
        check(transition.authorID == "author" && transition.flight == nil && transition.source?.image === image,
              "the click captures the displayed avatar while waiting for a measured destination")
        transition.update([targetKey: target])
        let flight = transition.flight!
        check(flight.frame(at: 0) == source.frame && flight.frame(at: 1) == target.frame,
              "avatar endpoints match the detail and gallery header exactly")
        check(flight.frame(at: 0.5).midY < source.frame.midY && flight.frame(at: 0.5).midY > target.frame.midY,
              "avatar moves upward toward the gallery rather than toward the wallpaper card")
        check(flight.frame(at: -1) == source.frame && flight.frame(at: 2) == target.frame,
              "avatar interpolation clamps to its measured endpoints")
        check(transition.source == source && flight.source.image === image,
              "unmounting the wallpaper cannot replace the captured avatar bitmap")
        transition.finish(UUID())
        check(transition.flight?.id == flight.id, "an unrelated completion cannot finish this flight")
        transition.finish(flight.id)
        check(transition.authorID == nil && transition.source == nil && transition.flight == nil,
              "landing releases the overlay and reveals the destination avatar")
        transition.beginReturn(authorID: "author", reduceMotion: false)
        check(transition.source?.frame == target.frame && transition.flight == nil,
              "Back captures the gallery avatar before the gallery unmounts")
        transition.update([sourceKey: source])
        let returning = transition.flight!
        check(returning.frame(at: 0) == target.frame && returning.frame(at: 1) == source.frame,
              "Back reverses the original path from the gallery header to the detail badge")
        check(returning.frame(at: 0.5) == flight.frame(at: 0.5),
              "both directions share the same geometric path")
        transition.finish(flight.id)
        check(transition.flight?.id == returning.id, "a forward completion cannot interrupt the return flight")
        let relocatedDetail = WorkshopCreatorAvatarGeometry(frame: source.frame.offsetBy(dx: 20, dy: 0), image: image)
        transition.update([sourceKey: relocatedDetail])
        check(transition.flight == nil, "resizing during return cancels the stale detail destination")
        transition.update([targetKey: target])
        transition.beginReturn(authorID: "author", reduceMotion: true)
        check(transition.authorID == nil, "Reduce Motion also skips the return flight")
        transition.update([sourceKey: source, targetKey: target])
        transition.begin(authorID: "author", reduceMotion: true)
        check(transition.flight == nil && transition.authorID == nil, "Reduce Motion reveals the author page directly")
        transition.begin(authorID: "missing", reduceMotion: false)
        check(transition.flight == nil && transition.source == nil, "a missing source never invents a flight")
        transition.begin(authorID: "author", reduceMotion: false)
        let previous = transition.flight!.id
        transition.begin(authorID: "author", reduceMotion: false)
        let current = transition.flight!.id
        transition.finish(previous)
        check(transition.flight?.id == current, "rapid navigation ignores stale animation completion")
        let resized = WorkshopCreatorAvatarGeometry(frame: CGRect(x: 320, y: 36, width: 44, height: 44), image: nil)
        transition.update([targetKey: resized])
        check(transition.flight == nil && transition.authorID == nil, "resize cancels an obsolete landing point")
        transition.update([sourceKey: source])
        transition.begin(authorID: "author", reduceMotion: false)
        transition.cancel()
        transition.update([targetKey: target])
        check(transition.flight == nil && transition.authorID == nil, "leaving the page cancels a pending destination")
        print("RESULT \(checks) avatar geometry and lifecycle checks passed")
    }
}
