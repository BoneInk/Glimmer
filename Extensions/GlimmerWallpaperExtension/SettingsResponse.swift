import Foundation

// Codable/XPC remapping follows Phosphene's MIT-licensed implementation. The archive
// is produced and consumed only in this process; untrusted archives never reach this helper.
func GWSettingsResponse() -> AnyObject? {
    guard let realClass = objc_getClass("WallpaperSettingsViewModelsXPC") as? AnyClass else { return nil }
    let video = GWConfiguration.directory.appendingPathComponent("config.json")
    let thumbnail = Bundle.main.url(forResource: "thumbnail", withExtension: "png") ?? video
    let provider = ChoiceProviderID(rawValue: GWBundleID)
    let descriptor = ChoiceIDDescriptor(provider: provider, identifier: GWChoiceID, files: [], configuration: Data(GWChoiceID.utf8))
    let choice = ChoiceID(id: GWChoiceID, descriptor: descriptor)
    let item = SettingsItem(id: choice, localizedName: "Glimmer", thumbnail: .image(url: thumbnail),
        choice: ChoiceDescriptor(id: choice, provider: provider, identifier: GWChoiceID, name: "Glimmer",
                                 localizedDescription: "Live Scene / Web or video; choose wallpaper in Glimmer", thumbnail: .image(url: thumbnail), isDownloaded: (try? GWConfiguration.load()) != nil, options: []),
        contentBadge: .video, showInTopLevel: true, sortOrder: 0, disposability: .none, contextMenu: nil)
    let group = SettingsGroup(id: GroupID(id: "native-video"), items: [item], localizedName: "Glimmer",
        disposability: .none, sortOrder: 0, sortID: GroupSortID(id: "native-video"), allChoiceID: nil, shouldHideItemLabels: false, contextMenu: nil, thumbnail: nil)
    let view = SettingsViewModel(groups: [group], refreshPolicy: .default, isModificationDisabled: false)
    let shim = ShimViewModelsXPC(value: SettingsViewModels(desktop: view, screenSaver: view))
    guard let data = try? NSKeyedArchiver.archivedData(withRootObject: shim, requiringSecureCoding: false) else { return nil }
    return GWDecodeAsClass(data, realClass, "ShimViewModelsXPC") as AnyObject?
}
