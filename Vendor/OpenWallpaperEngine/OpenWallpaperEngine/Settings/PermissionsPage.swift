import Cocoa
import SwiftUI

struct PermissionsPage: SettingsPage {
    @ObservedObject var viewModel: GlobalSettingsViewModel
    @State private var hasAudioCapturePermission = PermissionHelper.hasAudioCapturePermission

    init(globalSettings viewModel: GlobalSettingsViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        SettingsForm {
            Section {
                if PermissionHelper.usesSystemAudioRecording {
                    permissionRow(
                        title: "System Audio Recording",
                        status: hasAudioCapturePermission ? "Allowed" : "Required",
                        isGranted: hasAudioCapturePermission,
                        description: "Needed for audio visualizers and audio-reactive SceneScript. Only system audio is read, never the screen."
                    )
                } else {
                    permissionRow(
                        title: "Screen & System Audio Recording",
                        status: hasAudioCapturePermission ? "Allowed" : "Required",
                        isGranted: hasAudioCapturePermission,
                        description: "Needed for audio visualizers and audio-reactive SceneScript. macOS exposes system audio capture through Screen Recording permission."
                    )
                }
                // Side by side when they fit; stacked when longer languages would truncate them.
                ViewThatFits(in: .horizontal) {
                    HStack { permissionButtons }
                    VStack(alignment: .leading) { permissionButtons }
                }
            } header: {
                Label("Audio Visualizers", systemImage: "waveform")
            } footer: {
                Text("Audio capture starts on its own once the permission is granted; no restart is needed.")
            }
            .settingsAnchor(SettingsAnchor.permissions)
        }
        .onAppear(perform: refresh)
    }

    @ViewBuilder private var permissionButtons: some View {
        Button("Grant Access") {
            PermissionHelper.grantAudioCaptureAccess { refresh() }
        }
        .disabled(hasAudioCapturePermission)
        .help("Asks macOS for the permission audio visualizers need. If it was denied before, opens System Settings instead.")
        Button("Open Privacy Settings") {
            PermissionHelper.openAudioCaptureSettings()
        }
        .help("Opens Privacy & Security in System Settings, at this permission.")
        Button("Recheck") {
            refresh()
        }
        .help("Reads the permission again and starts audio capture if it's now allowed.")
    }

    /// Never prompts: only re-reads the grant and starts capture if it was newly granted.
    private func refresh() {
        hasAudioCapturePermission = PermissionHelper.hasAudioCapturePermission
        WallpaperServices.shared.recheckCapturePermission()
    }

    private func permissionRow(title: LocalizedStringKey, status: LocalizedStringKey, isGranted: Bool,
                               description: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: isGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(isGranted ? .green : .orange)
                Spacer()
                Text(status)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isGranted ? .green : .orange)
            }
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// The permission system audio capture needs: System Audio Recording on macOS 14.2+, where a Core
/// Audio process tap captures it, and Screen Recording before, through ScreenCaptureKit
/// (`SystemAudioBackend`).
enum PermissionHelper {
    static var usesSystemAudioRecording: Bool {
        SystemAudioBackend.requestedPermission(tapSupported: ProcessTapAudioCapture.isSupported) == .processTap
    }

    static var hasAudioCapturePermission: Bool {
        usesSystemAudioRecording
            ? SystemAudioRecordingPermission.status == .authorized
            : CGPreflightScreenCaptureAccess()
    }

    /// Only for explicit user actions: this is the one place the app asks macOS to prompt. A denied
    /// System Audio Recording permission can only be changed in System Settings, so that opens
    /// instead. `completion` runs on the main actor once the user has answered (or at once).
    @MainActor
    static func grantAudioCaptureAccess(completion: @escaping @MainActor () -> Void) {
        guard usesSystemAudioRecording else {
            if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
            return completion()
        }
        switch SystemAudioRecordingPermission.status {
        case .authorized:
            completion()
        case .denied:
            openAudioCaptureSettings()
            completion()
        case .notDetermined, .unknown:
            let requested = SystemAudioRecordingPermission.request { _ in
                Task { @MainActor in completion() }
            }
            guard !requested else { return }
            openAudioCaptureSettings()
            completion()
        }
    }

    /// System Settings › Privacy & Security, on the pane that lists the permission.
    static func openAudioCaptureSettings() {
        let anchor = usesSystemAudioRecording ? "Privacy_AudioCapture" : "Privacy_ScreenCapture"
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?\(anchor)",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security"
        ]
        for value in candidates {
            guard let url = URL(string: value), NSWorkspace.shared.open(url) else { continue }
            return
        }
    }
}
