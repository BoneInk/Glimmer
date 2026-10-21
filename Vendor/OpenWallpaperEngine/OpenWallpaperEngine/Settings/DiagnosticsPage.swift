import SwiftUI

/// Surfaces the state the shader pipeline depends on, so a wallpaper that renders wrong can be
/// told apart from assets or a compiler that never loaded.
struct DiagnosticsPage: SettingsPage {
    @ObservedObject var viewModel: GlobalSettingsViewModel
    /// Called after "Reset Config", so views of preferences outside `GlobalSettings` redraw.
    var onReset: () -> Void = {}

    init(globalSettings: GlobalSettingsViewModel) {
        self.init(globalSettings: globalSettings, onReset: {})
    }

    init(globalSettings: GlobalSettingsViewModel, onReset: @escaping () -> Void) {
        self.viewModel = globalSettings
        self.onReset = onReset
    }

    @State private var shaderCounts = DiagnosticsPage.shaderCacheCounts()
    @ObservedObject private var threadGuards = ThreadGuardMonitor.shared

    var body: some View {
        SettingsForm {
            Section {
                if let directory = WallpaperEngineAssets.directory {
                    row("Path", directory.path, monospaced: true)
                } else {
                    Label("No assets available", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            } header: {
                Label("Assets", systemImage: "shippingbox")
            }

            Section {
                row("Built-in compiler", InProcessShaderCompiler.libraryFingerprint
                    .split(separator: "|").prefix(2).joined(separator: ", "))
            } header: {
                Label("Shader Compiler", systemImage: "hammer")
            } footer: {
                Text("Shaders are translated from GLSL to Metal by the compiler built into the app, once, and cached.")
            }

            Section {
                row("Translated variants", "\(shaderCounts)")
                Button("Refresh") { shaderCounts = DiagnosticsPage.shaderCacheCounts() }
            } header: {
                Label("Shader Cache", systemImage: "square.stack.3d.up")
            } footer: {
                Text("WE shaders are translated per combination of options the first time a scene uses them, then reused.")
            }
            .settingsAnchor(SettingsAnchor.diagnostics)

            if ThreadGuards.isDevBuild {
                Section {
                    if threadGuards.sites.isEmpty {
                        Text("No violations")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(threadGuards.sites) { site in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: site.first.summary)
                            Text(verbatim: "\(site.first.file):\(site.first.line) · \(site.first.thread) · ×\(site.count)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Text(verbatim: site.first.stack.prefix(4).joined(separator: "\n"))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                                .lineLimit(4)
                        }
                        .textSelection(.enabled)
                    }
                    if !threadGuards.sites.isEmpty {
                        Button("Clear") { threadGuards.clear() }
                    }
                } header: {
                    Label("Thread Guards", systemImage: "exclamationmark.triangle")
                } footer: {
                    Text("Heavy work that ran on the main or render thread, and frame work that ran off the render thread. Development builds only.")
                }
                .settingsAnchor(SettingsAnchor.threadGuards)
            }

            // MARK: Developer
            Section {
                Picker("Log Level", selection: $viewModel.settings.logLevel) {
                    Text("None").tag(GSLogLevel.none)
                    Text("Errors Only").tag(GSLogLevel.error)
                    Text("Verbose").tag(GSLogLevel.verbose)
                }
                .changedFromDefault(viewModel.isChanged(\.logLevel))
                .help("How much the app writes to the macOS log. Verbose adds debug messages and frame timings; None and Errors Only both log errors.")
            } header: {
                Label("Developer", systemImage: "number")
            }
            .settingsAnchor(SettingsAnchor.developer)

            // MARK: Reset
            Section {
                HStack {
                    Text("Reset Config")
                    Spacer()
                    Button {
                        SettingsTabReset.resetAll(viewModel: viewModel, defaults: .app,
                                                  updater: AppDelegate.shared.updater,
                                                  screenSaver: AppDelegate.shared.screenSaverSelection)
                        onReset()
                    } label: {
                        Text("Reset").frame(minWidth: 100)
                    }
                    .tint(Color.red)
                    .glassButtonStyle(.prominent)
                    .help("Puts the settings of every tab back to their defaults, Updates included. Your wallpapers and library aren't touched.")
                }
            } header: {
                Label("Reset", systemImage: "exclamationmark.triangle.fill")
            } footer: {
                Text("Resets every setting in Settings. To reset one tab, use Restore Defaults in the ⋯ menu below.")
            }
            .settingsAnchor(SettingsAnchor.reset)
        }
        .onAppear { shaderCounts = DiagnosticsPage.shaderCacheCounts() }
    }

    @ViewBuilder
    private func row(_ title: LocalizedStringKey, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer()
            Text(value)
                .font(monospaced ? .caption.monospaced() : .body)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    /// Shader variants translated so far (one per shader pair and option set).
    private static func shaderCacheCounts() -> Int {
        guard let directory = ShaderVariantTranslator.defaultCacheDirectory else { return 0 }
        return ShaderVariantTranslator.cachedVariantCount(in: directory)
    }
}
