import Foundation
import Observation

/// A shared request also works before the manager window has appeared. A new
/// identity lets repeated Settings shortcuts select the same destination again.
@MainActor @Observable
final class AppWorkspaceNavigation {
    struct Route: Equatable {
        let id: UUID
        let destination: AppDestination
    }
    private(set) var route: Route?
    func request(_ destination: AppDestination) {
        route = Route(id: UUID(), destination: destination)
    }
}
