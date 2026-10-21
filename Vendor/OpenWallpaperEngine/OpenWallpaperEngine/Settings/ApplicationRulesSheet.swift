import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Performance › Application Rules › Edit: WE's per-application rules
/// (`ApplicationRule`). Each row picks an application, a condition and an action, and can be
/// turned off without deleting it. Changes apply as they are made, as the other settings do.
struct ApplicationRulesSheet: View {
    @Binding var rules: [ApplicationRule]
    @Environment(\.dismiss) private var dismiss
    @State private var selection: ApplicationRule.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Application Rules")
                .font(.title2.bold())
            Text("Pause, stop or mute wallpapers, or load a wallpaper, playlist or profile, while an application is running, focused, maximized, fullscreen or playing audio. Pausing, stopping and muting combine with the Playback settings; the most restrictive wins. When several rules load something, the first in the list wins, and what was shown before comes back once no rule matches.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List(selection: $selection) {
                ForEach($rules) { $rule in
                    ApplicationRuleRow(rule: $rule).tag(rule.id)
                }
                .onDelete { rules.remove(atOffsets: $0) }
            }
            .overlay {
                if rules.isEmpty {
                    Text("No Application Rules")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 220)

            HStack {
                Menu {
                    ApplicationChoices { add($0) }
                } label: {
                    Label("Add Rule", systemImage: "plus")
                }
                .fixedSize()
                .glassButtonStyle()
                Button {
                    rules.removeAll { $0.id == selection }
                    selection = nil
                } label: {
                    Label("Remove Rule", systemImage: "minus")
                }
                .glassButtonStyle()
                .disabled(selection == nil)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .glassButtonStyle(.prominent)
            }
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 420)
    }

    private func add(_ application: ApplicationChoice) {
        let rule = ApplicationRule(bundleIdentifier: application.bundleIdentifier, name: application.name)
        rules.append(rule)
        selection = rule.id
    }
}

/// One rule: on/off, the application, the condition and the action, and below them what a load
/// action loads.
private struct ApplicationRuleRow: View {
    @Binding var rule: ApplicationRule

    /// "Is playing audio" needs Core Audio's process objects (macOS 14.2).
    private var lacksAudioProcesses: Bool { rule.condition == .playingAudio && !ProcessAudioOutputWatch.isSupported }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Toggle("Enabled", isOn: $rule.isEnabled)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .help("Turn this rule on or off")
                Menu {
                    ApplicationChoices { choice in
                        rule.bundleIdentifier = choice.bundleIdentifier
                        rule.name = choice.name
                    }
                } label: {
                    Label {
                        Text(verbatim: rule.name)
                    } icon: {
                        Image(nsImage: ApplicationChoice.icon(for: rule.bundleIdentifier))
                    }
                }
                .help(Text(verbatim: rule.bundleIdentifier))
                .frame(width: 190, alignment: .leading)
                Picker("Condition", selection: $rule.condition) {
                    Text("Is Running").tag(ApplicationRule.Condition.running)
                    Text("Is Focused").tag(ApplicationRule.Condition.focused)
                    Text("Is Maximized").tag(ApplicationRule.Condition.maximized)
                    Text("Is Fullscreen").tag(ApplicationRule.Condition.fullscreen)
                    Text("Is Playing Audio").tag(ApplicationRule.Condition.playingAudio)
                }
                .labelsHidden()
                Picker("Action", selection: $rule.action) {
                    ApplicationRuleActionChoices(condition: rule.condition, selected: rule.action)
                }
                .labelsHidden()
            }
            if rule.action.loadKind != nil || lacksAudioProcesses {
                HStack(spacing: 10) {
                    ApplicationRuleTargetPicker(rule: $rule)
                    if lacksAudioProcesses {
                        Label("Needs macOS 14.2 or later", systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 28)
            }
        }
        .opacity(rule.isEnabled ? 1 : 0.6)
        .onChange(of: rule.condition) { _, condition in
            // WE offers no Stop while an application plays audio.
            if !condition.offersStop, rule.action == .stop || rule.action == .stopAll { rule.action = .pause }
        }
        .onChange(of: rule.action) { old, new in
            // A wallpaper's folder isn't a playlist or a profile.
            if old.loadKind != new.loadKind {
                rule.file = nil
                rule.fileName = nil
            }
        }
    }
}

/// The actions WE offers for a condition (its rule editor's `actionOptions`): with several
/// displays a window condition can pause or stop its own display or all of them; with one
/// display, or for "is running" and "is playing audio", there is one Pause and one Stop. "Is
/// playing audio" offers no Stop. An action already chosen stays listed, so the picker shows it.
private struct ApplicationRuleActionChoices: View {
    let condition: ApplicationRule.Condition
    let selected: ApplicationRule.Action

    private var splitsDisplays: Bool { condition.actsPerDisplay && NSScreen.screens.count > 1 }

    var body: some View {
        Text("Mute").tag(ApplicationRule.Action.mute)
        if splitsDisplays || selected == .pauseAll {
            Text("Pause per Display").tag(ApplicationRule.Action.pause)
            Text("Pause All").tag(ApplicationRule.Action.pauseAll)
        } else {
            Text("Pause").tag(ApplicationRule.Action.pause)
        }
        if condition.offersStop || selected == .stop || selected == .stopAll {
            Text("Stop (free memory)").tag(ApplicationRule.Action.stop)
            if splitsDisplays || selected == .stopAll {
                Text("Stop All").tag(ApplicationRule.Action.stopAll)
            }
        }
        Divider()
        Text("Load Wallpaper").tag(ApplicationRule.Action.loadWallpaper)
        Text("Load Playlist").tag(ApplicationRule.Action.loadPlaylist)
        Text("Load Profile").tag(ApplicationRule.Action.loadProfile)
    }
}

/// An application a rule can name.
struct ApplicationChoice: Equatable {
    var bundleIdentifier: String
    var name: String

    /// The running applications with a Dock icon, by name, without this app.
    @MainActor
    static func running() -> [ApplicationChoice] {
        let own = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications.compactMap { app -> ApplicationChoice? in
            // Optional: a process without a bundle identifier can't be named by a rule.
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier, id != own,
                  seen.insert(id).inserted else { return nil }
            return ApplicationChoice(bundleIdentifier: id, name: app.localizedName ?? id)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The application in the bundle at `url`; nil when it has no bundle identifier.
    static func bundle(at url: URL) -> ApplicationChoice? {
        // Optional: a folder that isn't a bundle has no Bundle.
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return nil }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        return ApplicationChoice(bundleIdentifier: id, name: name)
    }

    /// The application's icon, or the generic application icon when it isn't installed.
    @MainActor
    static func icon(for bundleIdentifier: String) -> NSImage {
        let image: NSImage
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            image = NSWorkspace.shared.icon(for: .application)
        }
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}

/// The menu items to pick an application: the running ones, then an .app bundle.
private struct ApplicationChoices: View {
    let choose: (ApplicationChoice) -> Void

    var body: some View {
        Section("Running Applications") {
            ForEach(ApplicationChoice.running(), id: \.bundleIdentifier) { app in
                Button {
                    choose(app)
                } label: {
                    Label {
                        Text(verbatim: app.name)
                    } icon: {
                        Image(nsImage: ApplicationChoice.icon(for: app.bundleIdentifier))
                    }
                }
            }
        }
        Divider()
        Button("Choose Application…") { chooseBundle() }
    }

    private func chooseBundle() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let choice = ApplicationChoice.bundle(at: url) {
            choose(choice)
        } else {
            OWELog.error(.settings, "Application Rules: \(url.path) has no bundle identifier")
        }
    }
}
