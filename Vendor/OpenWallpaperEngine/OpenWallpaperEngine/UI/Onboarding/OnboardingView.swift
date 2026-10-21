import OWEInspectorKit
import SwiftUI

/// Where the Done step's shortcuts go once the assistant closes.
enum OnboardingShortcut: Equatable {
    case installed
    case workshop
    case displaySettings
}

/// The setup assistant: the Terms of Use and Privacy Policy notice, welcome and language, privacy, Steam and SteamCMD, the Wallpaper Engine
/// assets, bringing wallpapers in, and a summary. Every step can be skipped and visited again,
/// here with Back or the step list, or later with Settings › General › "Run setup again…".
struct OnboardingView: View {
    @Environment(\.appAccentColor) private var accentColor
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var globalSettingsViewModel: GlobalSettingsViewModel
    @StateObject private var flow = OnboardingFlow()
    @ObservedObject var steamCmd: SteamCmdService
    @ObservedObject var installer: SteamCmdInstaller
    @ObservedObject var assets: WallpaperEngineAssetsService
    @ObservedObject var imports: OnboardingImports
    /// Called with the shortcut the user picked on the Done step, before the sheet closes.
    let onShortcut: (OnboardingShortcut?) -> Void
    /// The notice's checkbox: ticked already when the current documents were confirmed before.
    @State private var noticeRead = !LegalNotice.isDue(in: .app)

    /// Setup is done and only the notice is due (the documents changed, or setup was finished
    /// before the notice existed): the notice shows on its own.
    private var isNoticeOnly: Bool { !globalSettingsViewModel.isFirstLaunch }

    var body: some View {
        VStack(spacing: 0) {
            if !isNoticeOnly {
                stepList
                Divider()
            }
            ScrollView {
                stepBody
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
            }
            .id(flow.step)
            .transition(.opacity)
            Divider()
            footer
        }
        .frame(width: 720, height: 640)
    }

    // MARK: Steps

    private var stepList: some View {
        HStack(spacing: 4) {
            ForEach(OnboardingStep.allCases, id: \.self) { step in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { flow.go(to: step) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: icon(for: step))
                        Text(Self.title(of: step))
                    }
                    .font(.callout)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .foregroundStyle(step == flow.step ? accentColor : (flow.skipped.contains(step) ? Color.secondary : Color.primary))
                    .background(step == flow.step ? accentColor.opacity(0.15) : Color.clear, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(step != .notice && !noticeRead)
                .help(flow.skipped.contains(step) ? Text("Skipped. Click to set it up.") : Text(Self.title(of: step)))
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
    }

    private func icon(for step: OnboardingStep) -> String {
        if flow.completed.contains(step) && step != flow.step { return "checkmark.circle.fill" }
        switch step {
        case .notice: return "doc.text"
        case .welcome: return "hand.wave"
        case .privacy: return "hand.raised"
        case .steam: return "person.badge.key"
        case .assets: return "shippingbox"
        case .wallpapers: return "photo.on.rectangle.angled"
        case .done: return "flag.checkered"
        }
    }

    static func title(of step: OnboardingStep) -> LocalizedStringKey {
        switch step {
        case .notice: return "Terms"
        case .welcome: return "Welcome"
        case .privacy: return "Privacy"
        case .steam: return "Steam"
        case .assets: return "Assets"
        case .wallpapers: return "Wallpapers"
        case .done: return "Done"
        }
    }

    @ViewBuilder
    private var stepBody: some View {
        if isNoticeOnly {
            OnboardingNoticeStep(isRead: $noticeRead, isUpdate: true)
        } else {
            flowStepBody
        }
    }

    @ViewBuilder
    private var flowStepBody: some View {
        switch flow.step {
        case .notice:
            OnboardingNoticeStep(isRead: $noticeRead, isUpdate: false)
        case .welcome:
            OnboardingWelcomeStep(settings: globalSettingsViewModel, onRelaunch: relaunch)
        case .privacy:
            OnboardingPrivacyStep(updater: AppDelegate.shared.updater)
        case .steam:
            OnboardingSteamStep(steamCmd: steamCmd, installer: installer)
        case .assets:
            OnboardingAssetsStep(assets: assets, steamCmd: steamCmd,
                                 logIn: { withAnimation(.easeInOut(duration: 0.15)) { flow.go(to: .steam) } })
        case .wallpapers:
            OnboardingWallpapersStep(steamCmd: steamCmd, imports: imports)
        case .done:
            OnboardingDoneStep(flow: flow, steamCmd: steamCmd, assets: assets, imports: imports,
                               language: globalSettingsViewModel.settings.language,
                               onShortcut: finish)
        }
    }

    // MARK: Footer

    private var footer: some View {
        if isNoticeOnly { return AnyView(noticeFooter) }
        return AnyView(flowFooter)
    }

    /// The notice on its own: Continue records it and closes the sheet.
    private var noticeFooter: some View {
        HStack {
            Spacer()
            Button("Continue") {
                LegalNotice.acknowledge(in: .app)
                globalSettingsViewModel.needsLegalNotice = false
                dismiss()
            }
            .glassButtonStyle(.prominent)
            .keyboardShortcut(.defaultAction)
            .disabled(!noticeRead)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private var flowFooter: some View {
        HStack {
            Button("Back") {
                withAnimation(.easeInOut(duration: 0.15)) { flow.back() }
            }
            .disabled(flow.isFirst)
            Spacer()
            if flow.step == .notice && !noticeRead {
                Text("Tick the box to continue.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let note = skipNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !flow.isLast && flow.step != .notice {
                Button("Skip for Now") {
                    withAnimation(.easeInOut(duration: 0.15)) { flow.skip() }
                }
            }
            Button(flow.isLast ? "Finish" : "Continue") {
                if flow.isLast {
                    finish(nil)
                } else {
                    if flow.step == .notice {
                        LegalNotice.acknowledge(in: .app)
                        globalSettingsViewModel.needsLegalNotice = false
                    }
                    withAnimation(.easeInOut(duration: 0.15)) { flow.next() }
                }
            }
            .glassButtonStyle(.prominent)
            .keyboardShortcut(.defaultAction)
            .disabled(flow.step == .notice && !noticeRead)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private var skipNote: LocalizedStringKey? {
        switch flow.step {
        case .steam where !steamCmd.isLoggedIn:
            return "Without Steam, video and web wallpapers still work."
        case .assets where assets.isBusy:
            return "The download continues in the background."
        default:
            return nil
        }
    }

    private func finish(_ shortcut: OnboardingShortcut?) {
        flow.finish()
        onShortcut(shortcut)
        dismiss()
    }

    private func relaunch() {
        flow.prepareForRelaunch()
        AppRelauncher.relaunch()
    }
}

extension AppDelegate {
    /// Help › Debug › Reset First Launch: shows the setup assistant again now.
    @objc func resetFirstLaunch() {
        OnboardingFlow.reopen()
        globalSettingsViewModel.isFirstLaunch = true
        openMainWindow()
    }
}
