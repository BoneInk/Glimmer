import AppKit

/// Opens a Workshop item's page, where the user can read it, rate it or report it to Steam
/// themselves: in the Steam client when it is installed, else in the browser. Nothing is sent to
/// Steam from here, and a report is never filed for the user.
enum WorkshopPageLink {
    /// The page to open for `id`; nil for something that isn't a Workshop id.
    static func url(for id: String, steamClientInstalled: Bool) -> URL? {
        if steamClientInstalled, let steam = WorkshopItemAvailability.steamClientPageURL(for: id) {
            return steam
        }
        return WorkshopItemAvailability.workshopPageURL(for: id)
    }

    /// Whether an app (the Steam client) handles `steam://` links.
    @MainActor
    static func steamClientInstalled(workspace: NSWorkspace = .shared) -> Bool {
        guard let probe = WorkshopItemAvailability.steamClientPageURL(for: "1") else { return false }
        return workspace.urlForApplication(toOpen: probe) != nil
    }

    @MainActor
    static func open(_ id: String, workspace: NSWorkspace = .shared) {
        guard let url = url(for: id, steamClientInstalled: steamClientInstalled(workspace: workspace)) else {
            OWELog.error(.workshop, "Can't open the Workshop page of \(id): not a Workshop id")
            return
        }
        workspace.open(url)
    }
}
