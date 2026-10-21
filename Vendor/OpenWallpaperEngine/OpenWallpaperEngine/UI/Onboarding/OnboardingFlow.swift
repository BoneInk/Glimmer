import Foundation
import Combine

/// The setup assistant's steps, in order.
enum OnboardingStep: Int, CaseIterable, Codable, Comparable {
    /// The Terms of Use and Privacy Policy notice (`LegalNotice`).
    case notice, welcome, privacy, steam, assets, wallpapers, done

    static func < (lhs: OnboardingStep, rhs: OnboardingStep) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Where the setup assistant is, what the user skipped, and whether it shows at launch.
///
/// Every step can be skipped; a skipped step is remembered for the summary and can be visited
/// again with Back or from the step list. The step is saved, so a restart for a new language
/// comes back to the assistant where the user left it. Finishing hides the assistant until
/// Settings › General › "Run setup again…" (`reopen`) or Help › Debug › Reset First Launch.
@MainActor
final class OnboardingFlow: ObservableObject {
    /// Shown at launch while true (set false on finish). The key predates the assistant.
    static let showsAtLaunchKey = "IsFirstLaunch"
    static let stepKey = "OnboardingStep"
    static let skippedKey = "OnboardingSkippedSteps"

    @Published private(set) var step: OnboardingStep
    @Published private(set) var skipped: Set<OnboardingStep>
    /// The steps the user moved on from with Continue.
    @Published private(set) var completed: Set<OnboardingStep> = []

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .app) {
        self.defaults = defaults
        step = OnboardingStep(rawValue: defaults.integer(forKey: Self.stepKey)) ?? .notice
        skipped = Set((defaults.array(forKey: Self.skippedKey) as? [Int] ?? []).compactMap(OnboardingStep.init(rawValue:)))
    }

    /// Whether the assistant shows at launch.
    static func showsAtLaunch(defaults: UserDefaults = .app) -> Bool {
        defaults.object(forKey: showsAtLaunchKey) as? Bool ?? true
    }

    var isFirst: Bool { step == OnboardingStep.allCases.first }
    var isLast: Bool { step == OnboardingStep.allCases.last }

    /// Continue: the step is done, on to the next.
    func next() {
        completed.insert(step)
        skipped.remove(step)
        advance()
    }

    /// Skip for now: remembered for the summary; the step stays reachable.
    /// The notice can't be skipped: Continue, once its checkbox is ticked, moves on.
    func skip() {
        guard !isLast, step != .notice else { return }
        skipped.insert(step)
        advance()
    }

    func back() {
        guard let previous = OnboardingStep(rawValue: step.rawValue - 1) else { return }
        move(to: previous)
    }

    /// Revisits any step, e.g. from the step list or the summary.
    func go(to target: OnboardingStep) {
        move(to: target)
    }

    /// Done: the assistant won't show at launch again, and starts from the top next time.
    func finish() {
        defaults.set(false, forKey: Self.showsAtLaunchKey)
        defaults.removeObject(forKey: Self.stepKey)
        defaults.removeObject(forKey: Self.skippedKey)
    }

    /// Before relaunching for a new language: the assistant comes back, on the step after
    /// the language choice.
    func prepareForRelaunch() {
        if step == .welcome { step = .privacy }
        save()
        defaults.set(true, forKey: Self.showsAtLaunchKey)
    }

    /// "Run setup again…": shows the assistant from the first step.
    static func reopen(defaults: UserDefaults = .app) {
        defaults.removeObject(forKey: stepKey)
        defaults.removeObject(forKey: skippedKey)
        defaults.set(true, forKey: showsAtLaunchKey)
    }

    private func advance() {
        guard let following = OnboardingStep(rawValue: step.rawValue + 1) else { return }
        move(to: following)
    }

    private func move(to target: OnboardingStep) {
        step = target
        save()
    }

    private func save() {
        defaults.set(step.rawValue, forKey: Self.stepKey)
        defaults.set(skipped.map(\.rawValue).sorted(), forKey: Self.skippedKey)
    }
}

/// Whether a language picked now needs a relaunch: the app's language is fixed at launch.
struct LanguageChange: Equatable {
    /// The language setting the process launched with.
    let atLaunch: GSLocalization

    func needsRelaunch(for chosen: GSLocalization) -> Bool {
        chosen != atLaunch
    }
}
