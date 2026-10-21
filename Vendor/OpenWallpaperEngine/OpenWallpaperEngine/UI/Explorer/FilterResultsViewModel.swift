import Foundation
import Observation

/// The Installed tab's filter sidebar (`FilterResults`): one option set per filter, kept across
/// launches under the keys and raw values `@AppStorage` stored them with.
@MainActor @Observable
final class FilterResultsViewModel {
    var showOnly = FilterResultsViewModel.stored("FRShowOnly", default: FRShowOnly.all) { didSet { store(showOnly, "FRShowOnly") } }
    var type = FilterResultsViewModel.stored("FRType", default: FRType.all) { didSet { store(type, "FRType") } }
    var category = FilterResultsViewModel.stored("FRCategory", default: FRCategory.all) { didSet { store(category, "FRCategory") } }
    var ageRating = FilterResultsViewModel.stored("FRAgeRating", default: FRAgeRating.all) { didSet { store(ageRating, "FRAgeRating") } }
    var widescreenResolution = FilterResultsViewModel.stored("FRWidescreenResolution", default: FRWidescreenResolution.all) {
        didSet { store(widescreenResolution, "FRWidescreenResolution") }
    }
    var ultraWidescreenResolution = FilterResultsViewModel.stored("FRUltraWidescreenResolution", default: FRUltraWidescreenResolution.all) {
        didSet { store(ultraWidescreenResolution, "FRUltraWidescreenResolution") }
    }
    var dualscreenResolution = FilterResultsViewModel.stored("FRDualscreenResolution", default: FRDualscreenResolution.all) {
        didSet { store(dualscreenResolution, "FRDualscreenResolution") }
    }
    var triplescreenResolution = FilterResultsViewModel.stored("FRTriplescreenResolution", default: FRTriplescreenResolution.all) {
        didSet { store(triplescreenResolution, "FRTriplescreenResolution") }
    }
    var potraitscreenResolution = FilterResultsViewModel.stored("FRPortraitScreenResolution", default: FRPortraitScreenResolution.all) {
        didSet { store(potraitscreenResolution, "FRPortraitScreenResolution") }
    }
    var miscResolution = FilterResultsViewModel.stored("FRMiscResolution", default: FRMiscResolution.all) {
        didSet { store(miscResolution, "FRMiscResolution") }
    }
    var source = FilterResultsViewModel.stored("FRSource", default: FRSource.all) { didSet { store(source, "FRSource") } }
    var tag = FilterResultsViewModel.stored("FRTag", default: FRTag.all) { didSet { store(tag, "FRTag") } }

    /// Called after any filter changed (the Installed list re-filters).
    @ObservationIgnored var onChange: (() -> Void)?

    /// Reads every filter, so whoever asks observes all of them (the Installed list depends on them
    /// even when it answers from its memo).
    func observeAll() {
        _ = (showOnly, type, category, ageRating, widescreenResolution, ultraWidescreenResolution)
        _ = (dualscreenResolution, triplescreenResolution, potraitscreenResolution, miscResolution, source, tag)
    }

    /// Provide a filter reset to default function, usually being used to show all wallpapers without filtered
    func reset() {
        showOnly                   = .none // notice it's show ONLY, it acts oppositely to the others
        type                       = .all
        category                   = .all
        ageRating                  = .all
        widescreenResolution       = .all
        ultraWidescreenResolution  = .all
        dualscreenResolution       = .all
        triplescreenResolution     = .all
        potraitscreenResolution    = .all
        miscResolution             = .all
        source                     = .all
        tag                        = .all
    }

    /// The stored value, as `@AppStorage` reads a raw-representable one.
    nonisolated private static func stored<Option: FilterResultsModel>(_ key: String, default value: Option) -> Option {
        (UserDefaults.app.object(forKey: key) as? Int).map(Option.init(rawValue:)) ?? value
    }

    private func store<Option: FilterResultsModel>(_ value: Option, _ key: String) {
        UserDefaults.app.set(value.rawValue, forKey: key)
        onChange?()
    }
}
