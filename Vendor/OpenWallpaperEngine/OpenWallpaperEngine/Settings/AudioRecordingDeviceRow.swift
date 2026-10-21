import AVFoundation
import SwiftUI

/// Settings › Optimizations › Audio › Audio recording device: WE's `audioinputdevice`. Default
/// records the system output; any recording device (a microphone, or a loopback driver such as
/// BlackHole) can be chosen instead. Choosing one asks for the Microphone permission when it was
/// never asked; a device that is disconnected stays chosen and is recorded again when it returns.
struct AudioRecordingDeviceRow: View {
    @Binding var selection: AudioInputDevice?
    @State private var devices: [AudioInputDevice] = []
    @State private var monitor: AudioDeviceListMonitor?
    @State private var microphone = AVCaptureDevice.authorizationStatus(for: .audio)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Audio recording device", selection: $selection) {
                Text("Default (system audio)").tag(AudioInputDevice?.none)
                ForEach(listedDevices) { device in
                    Text(isConnected(device) ? device.name : String(localized: "\(device.name) (disconnected)"))
                        .tag(AudioInputDevice?.some(device))
                }
            }
            if selection != nil, microphone == .denied || microphone == .restricted {
                HStack(spacing: 6) {
                    Text("Recording a device needs the Microphone permission; until it's granted, the system audio is recorded.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open Privacy Settings") { Self.openMicrophoneSettings() }
                        .controlSize(.small)
                }
            }
        }
        .onAppear {
            refresh()
            monitor = AudioDeviceListMonitor { refresh() }
        }
        .onDisappear { monitor = nil }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        }
        .onChange(of: selection) { _, device in
            guard device != nil else { return }
            requestMicrophoneIfNeeded()
        }
    }

    /// The connected devices, and the chosen one while it is disconnected.
    private var listedDevices: [AudioInputDevice] {
        guard let selection, !devices.contains(where: { $0.uid == selection.uid }) else { return devices }
        return devices + [selection]
    }

    private func isConnected(_ device: AudioInputDevice) -> Bool {
        devices.contains { $0.uid == device.uid }
    }

    private func refresh() {
        devices = AudioInputDevices.list()
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// The one place the app asks for the Microphone permission: the user just chose a device.
    private func requestMicrophoneIfNeeded() {
        guard microphone == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            Task { @MainActor in
                microphone = AVCaptureDevice.authorizationStatus(for: .audio)
                WallpaperServices.shared.audioCapture.followRecordingDevicePermission()
            }
        }
    }

    private static func openMicrophoneSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else { return }
        NSWorkspace.shared.open(url)
    }
}
