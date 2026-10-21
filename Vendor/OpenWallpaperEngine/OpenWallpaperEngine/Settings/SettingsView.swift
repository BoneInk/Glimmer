//
//  SettingsView.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/6/5.
//

import Cocoa
import SwiftUI
import UniformTypeIdentifiers

protocol SettingsPage: View {
    var viewModel: GlobalSettingsViewModel { get set }

    init(globalSettings: GlobalSettingsViewModel)
}

extension AppDelegate {
    /// A toolbar button: shows the tab whose identifier the button carries.
    @objc func selectSettingsTab(_ sender: NSToolbarItem) {
        if let tab = SettingsTab(toolbarIdentifier: sender.itemIdentifier) { settingsNavigation.show(tab) }
    }
}

struct SettingsView: View {
    @EnvironmentObject var viewModel: GlobalSettingsViewModel
    @EnvironmentObject var navigation: SettingsNavigation
    @State private var query = ""
    @FocusState private var isSearchFocused: Bool
    @State private var confirmsReset = false
    @State private var transferError: String?
    /// Redraws after a reset or an import changed preferences outside `GlobalSettings`.
    @State private var preferencesRevision = 0

    var body: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 20)
                .padding(.top, 10)
            Group {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    page(navigation.tab)
                        .id(preferencesRevision)
                } else {
                    SettingsSearchResults(query: query) { entry in
                        query = ""
                        navigation.show(entry.tab, anchor: entry.anchor)
                    }
                }
            }
            .frame(minHeight: 400, maxHeight: .infinity)
            footer
                .padding(20)
        }
        .frostedWindowBackground()
        .onChange(of: navigation.focusesSearch) { _, focuses in
            if focuses {
                isSearchFocused = true
                navigation.focusesSearch = false
            }
        }
        .confirmationDialog(Text("Restore the defaults of \(Text(navigation.tab.title))?",
                                 comment: "%@ is a settings tab, e.g. Performance"),
                            isPresented: $confirmsReset) {
            Button("Restore Defaults", role: .destructive) {
                SettingsTabReset.reset(navigation.tab, viewModel: viewModel, defaults: .app,
                                       updater: AppDelegate.shared.updater,
                                       screenSaver: AppDelegate.shared.screenSaverSelection)
                preferencesRevision += 1
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only the settings on this tab change.")
        }
        .alert(Text("Settings Not Imported"), isPresented: Binding(
            get: { transferError != nil }, set: { if !$0 { transferError = nil } })) {
            Button("OK") { transferError = nil }
        } message: {
            Text(verbatim: transferError ?? "")
        }
    }

    @ViewBuilder
    private func page(_ tab: SettingsTab) -> some View {
        switch tab {
        case .general: GeneralPage(globalSettings: viewModel)
        case .performance: PerformancePage(globalSettings: viewModel)
        case .optimizations: OptimizationsPage(globalSettings: viewModel)
        case .assets: AssetsPage(globalSettings: viewModel)
        case .updates: UpdatesPage(updater: AppDelegate.shared.updater)
        case .privacy: PrivacyPage()
        case .permissions: PermissionsPage(globalSettings: viewModel)
        case .diagnostics: DiagnosticsPage(globalSettings: viewModel, onReset: { preferencesRevision += 1 })
        case .plugins: PluginsPage(globalSettings: viewModel)
        case .about: AboutUsView()
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search Settings", text: $query)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .onSubmit {
                    if let first = SettingsSearch.results(for: query).first {
                        query = ""
                        navigation.show(first.tab, anchor: first.anchor)
                    }
                }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear")
                .accessibilityLabel(Text("Clear"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
    }

    private var footer: some View {
        HStack {
            Menu {
                Button("Export Settings…", action: exportSettings)
                Button("Import Settings…", action: importSettings)
                Divider()
                Button("Restore Defaults of This Tab…") { confirmsReset = true }
                    .disabled(!navigation.tab.isResettable)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Export, import or restore settings")
            // Against the settings the window opened with, which Cancel goes back to.
            if viewModel.hasUnconfirmedEdits {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.yellow)
                Text("Edited")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            GlassGroup {
                HStack {
                    Button {
                        viewModel.commitEdits()
                        AppDelegate.shared.settingsWindow.close()
                    } label: {
                        Text("OK").frame(minWidth: 50)
                    }
                    .glassButtonStyle(.prominent)
                    Button {
                        // The delegate goes back to the settings the window opened with as it closes.
                        AppDelegate.shared.settingsWindow.close()
                    } label: {
                        Text("Cancel").frame(minWidth: 50)
                    }
                    .glassButtonStyle()
                }
            }
        }
    }

    // MARK: Export and import

    private var currentUpdates: SettingsTransfer.Updates? {
        let updater = AppDelegate.shared.updater
        guard updater.isEnabled else { return nil }
        return .init(automaticallyChecksForUpdates: updater.automaticallyChecksForUpdates,
                     updatesAutomatically: updater.updatesAutomatically)
    }

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = String(localized: "Open Wallpaper Engine Settings") + ".json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let transfer = SettingsTransfer.export(settings: viewModel.settings, defaults: .app,
                                               updates: currentUpdates, appVersion: AppVersion.current)
        do {
            try transfer.encoded().write(to: url, options: .atomic)
            OWELog.info(.settings, "Exported settings to \(url.path)")
        } catch {
            OWELog.error(.settings, "Exporting settings to \(url.path) failed: \(error)")
            transferError = error.localizedDescription
        }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let transfer = try SettingsTransfer.decode(Data(contentsOf: url), migration: .current())
            viewModel.settings = transfer.settings
            // The other preferences it sets stay, so Cancel goes back to the imported settings.
            viewModel.commitEdits()
            viewModel.beginEditing()
            transfer.applyPreferences(to: .app)
            if let folders = transfer.folders {
                AppDelegate.shared.contentViewModel.library.folders.merge(folders.folders)
            }
            let updater = AppDelegate.shared.updater
            if let updates = transfer.updates, updater.isEnabled {
                updater.automaticallyChecksForUpdates = updates.automaticallyChecksForUpdates
                updater.updatesAutomatically = updates.updatesAutomatically
            }
            preferencesRevision += 1
            OWELog.info(.settings, "Imported settings from \(url.path)")
        } catch {
            OWELog.error(.settings, "Importing settings from \(url.path) failed: \(error)")
            transferError = error.localizedDescription
        }
    }
}

extension AppDelegate: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsTab.allCases.map(\.toolbarIdentifier)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsTab.allCases.map(\.toolbarIdentifier)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsTab.allCases.map(\.toolbarIdentifier)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let tab = SettingsTab(toolbarIdentifier: itemIdentifier) else { return nil }
        let toolbarItem = NSToolbarItem(itemIdentifier: itemIdentifier)
        toolbarItem.action = #selector(selectSettingsTab(_:))
        toolbarItem.target = self
        toolbarItem.image = NSImage(systemSymbolName: tab.systemImage, accessibilityDescription: nil)
        toolbarItem.label = String(localized: tab.title)
        toolbarItem.isBordered = false
        return toolbarItem
    }
}

/// The settings matching a search, each opening its tab and section.
private struct SettingsSearchResults: View {
    let query: String
    let open: (SettingsSearch.Entry) -> Void

    var body: some View {
        let results = SettingsSearch.results(for: query)
        if results.isEmpty {
            VStack {
                Spacer()
                Text("No Results")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            List(results) { entry in
                Button {
                    open(entry)
                } label: {
                    HStack {
                        Image(systemName: entry.tab.systemImage)
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        Text(entry.title)
                        Spacer()
                        Text(entry.tab.title)
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .scrollContentBackground(.hidden)
        }
    }
}
