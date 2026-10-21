import SwiftUI
import OWEInspectorKit

/// Settings › Optimizations: the optional ways the app saves space and work, or changes how it
/// renders. New optional optimizations are listed here.
struct OptimizationsPage: SettingsPage {
    @ObservedObject var viewModel: GlobalSettingsViewModel
    @AppStorage("ReclaimOriginalPackages", store: .app) private var reclaimOriginalPackages = false
    @State private var reclaimableBytes: Int64 = 0
    @State private var reclaimedCount: Int?
    @State private var isReclaiming = false

    init(globalSettings viewModel: GlobalSettingsViewModel) {
        self.viewModel = viewModel
    }

    private var reclaimableDescription: String {
        guard reclaimableBytes > 0 else { return String(localized: "No originals ready to remove") }
        let formatted = ByteCountFormatter.string(fromByteCount: reclaimableBytes, countStyle: .file)
        return String(localized: "\(formatted) of originals can be removed", comment: "%@ is a file size, e.g. 1.2 GB")
    }

    var body: some View {
        SettingsForm {
            Section {
                Text("Optional optimizations. Any added later are listed here too.")
                    .foregroundStyle(.secondary)
            }
            // MARK: Converted Wallpapers
            Section {
                Toggle("Remove original packages after conversion", isOn: $reclaimOriginalPackages)
                    .changedFromDefault(reclaimOriginalPackages)
                    .help("Deletes a wallpaper's original package once it has converted and rendered cleanly, to save disk space. If a later converter update changes a Workshop wallpaper, it's downloaded again; a local import isn't updated.")
                HStack {
                    Text(reclaimableDescription)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reclaim Now") {
                        isReclaiming = true
                        DispatchQueue.global(qos: .utility).async {
                            let removed = WallpaperPackageConverter.reclaimEligibleSources()
                            let remaining = WallpaperPackageConverter.reclaimableBytes()
                            DispatchQueue.main.async {
                                reclaimedCount = removed
                                reclaimableBytes = remaining
                                isReclaiming = false
                            }
                        }
                    }
                    .disabled(isReclaiming || reclaimableBytes == 0)
                    .help("Deletes the originals that are ready now, without waiting for the next launch.")
                }
                if let reclaimedCount {
                    Text("Removed \(reclaimedCount) original packages.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Label("Converted Wallpapers", systemImage: "arrow.triangle.2.circlepath")
            } footer: {
                Text("Wallpapers are unpacked into plain files when imported. The original package is kept until the wallpaper has rendered from those files, reported no conversion warnings, and no other wallpaper depends on it.")
            }
            .settingsAnchor(SettingsAnchor.converted)
            // MARK: Displays
            Section {
                Toggle("Sync properties across displays", isOn: $viewModel.settings.syncPropertiesAcrossDisplays)
                    .changedFromDefault(viewModel.isChanged(\.syncPropertiesAcrossDisplays))
                    .help("On, one set of user properties applies to a wallpaper on every display. Off, each display keeps its own, as in Wallpaper Engine.")
            } header: {
                Label("Displays", systemImage: "display.2")
            } footer: {
                Text("Off, a wallpaper shown on several displays keeps each display's properties, as Wallpaper Engine does. On, one set of properties applies to every display.")
            }
            .settingsAnchor(SettingsAnchor.displays)
            // MARK: Video Framework
            Section {
                Picker("Video Framework", selection: $viewModel.settings.videoFramework) {
                    Text("Apple AVKit").tag(GSVideoFramework.avkit)
                    Text("Metal (effects apply to video)").tag(GSVideoFramework.metal)
                }
                .changedFromDefault(viewModel.isChanged(\.videoFramework))
                .help("AVKit plays videos with Apple's player. Metal draws them through the scene renderer so their effects apply; it needs the Wallpaper Engine assets, and without them videos play through AVKit.")
                Picker("Video loading", selection: $viewModel.settings.videoReadMode) {
                    Text("From disk").tag(GSVideoReadMode.fromDisk)
                    Text("In memory").tag(GSVideoReadMode.inMemory)
                }
                .changedFromDefault(viewModel.isChanged(\.videoReadMode))
                .help("From disk reads the video file again on every loop. In memory reads it once and plays it from memory, so the disk can rest (useful for a hard disk or a network volume), for the file's size in memory. Applies to videos opened from now on.")
            } header: {
                Label("Video", systemImage: "film")
            } footer: {
                Text("Metal draws video through the scene renderer so effects and music sync apply to it, the way Wallpaper Engine does. Experimental.")
            }
            .settingsAnchor(SettingsAnchor.video)
            // MARK: Audio
            Section {
                Toggle(isOn: $viewModel.settings.audioOutput) {
                    Text("Audio Output")
                }
                .changedFromDefault(viewModel.isChanged(\.audioOutput))
                .help("Plays the wallpapers' own sound. Off silences every wallpaper.")
                Toggle(isOn: $viewModel.settings.reloadWhenChangingOutputDevice) {
                    Text("Reload when changing output device")
                }
                .changedFromDefault(viewModel.isChanged(\.reloadWhenChangingOutputDevice))
                .help("Reloads the wallpapers and their audio when you switch the sound output, such as to headphones or another speaker.")
                AudioRecordingDeviceRow(selection: $viewModel.settings.audioRecordingDevice)
                    .changedFromDefault(viewModel.isChanged(\.audioRecordingDevice))
                    .help("Where audio-reactive wallpapers hear sound from. Default is the sound your Mac plays; a microphone or a loopback device such as BlackHole records that input instead.")
                HStack {
                    Text("Recording volume")
                    Spacer()
                    NumericSliderInput(value: $viewModel.settings.audioRecordingVolume, range: 0...200,
                                       defaultValue: 50, step: 1, fractionDigits: 0,
                                       sliderWidth: 150, fieldWidth: 44)
                }
                .changedFromDefault(viewModel.isChanged(\.audioRecordingVolume))
                .help("How strongly audio-reactive wallpapers react to the recorded sound. 50 is normal, 100 doubles it, 0 silences it.")
                HStack {
                    Text("Recording threshold")
                    Spacer()
                    NumericSliderInput(value: $viewModel.settings.audioRecordingThreshold, range: 0...10,
                                       defaultValue: 0, step: 0.1, fractionDigits: 1,
                                       sliderWidth: 150, fieldWidth: 44)
                }
                .changedFromDefault(viewModel.isChanged(\.audioRecordingThreshold))
                .help("Audio-reactive wallpapers react only to sound at least this loud; quieter sound reads as silence. 0 reacts to everything, 10 needs about −40 dB.")
                Toggle("Media integration support", isOn: $viewModel.settings.mediaIntegration)
                    .changedFromDefault(viewModel.isChanged(\.mediaIntegration))
                    .help("Lets wallpapers show the title, artist and album cover of what's playing now. Off hides it from every wallpaper.")
                MediaBlocklistRow(blocklist: $viewModel.settings.mediaBlocklist, source: AppDelegate.shared.mediaSession)
                    .disabled(!viewModel.settings.mediaIntegration)
                    .changedFromDefault(viewModel.isChanged(\.mediaBlocklist))
            } header: {
                Label("Audio", systemImage: "speaker.3.fill")
            } footer: {
                Text("Media integration lets wallpapers read the title, artist and album cover of the music playing now.")
            }
            .settingsAnchor(SettingsAnchor.audio)
            // MARK: Rendering
            Section {
                Toggle("Optimise textures", isOn: $viewModel.settings.optimiseTextures)
                    .changedFromDefault(viewModel.isChanged(\.optimiseTextures))
                    .help("Compresses wallpaper images once in the background so they use about a third of the GPU memory. Images that would lose visible detail stay as they are.")
                Toggle("Cheaper shadows", isOn: $viewModel.settings.cheaperShadows)
                    .changedFromDefault(viewModel.isChanged(\.cheaperShadows))
                    .help("Draws shadow maps at half size, a quarter of the shadow work; the edges stay soft. Off draws them as Wallpaper Engine does.")
                Toggle("Render web wallpapers at standard resolution", isOn: $viewModel.settings.webStandardResolution)
                    .changedFromDefault(viewModel.isChanged(\.webStandardResolution))
                    .help("Draws web wallpapers at standard resolution, a quarter of the pixels on Retina, for less GPU.")
                Toggle("Draw large glowing particles at half resolution", isOn: $viewModel.settings.reducedResolutionParticles)
                    .changedFromDefault(viewModel.isChanged(\.reducedResolutionParticles))
                    .help("Large additive particle effects in 2D scenes, like glows and light haze, draw a quarter of the pixels. Their edges look softer and they use less GPU.")
                Picker("Process Priority", selection: $viewModel.settings.processPiority) {
                    Text("Normal").tag(GSProcessPiority.normal)
                    Text("Below Normal").tag(GSProcessPiority.belowNormal)
                }
                .changedFromDefault(viewModel.isChanged(\.processPiority))
                .help("Below Normal lets other apps go first: Open Wallpaper Engine runs at a lower CPU priority, and wallpapers may drop frames while the Mac is busy.")
                Toggle("Pause when VRAM is exhausted", isOn: $viewModel.settings.pauseOnVRAMExhausted)
                    .changedFromDefault(viewModel.isChanged(\.pauseOnVRAMExhausted))
                    .help("Pauses every wallpaper while the GPU runs out of video memory, and resumes them when memory frees up.")
                Toggle("Restart after crashing", isOn: $viewModel.settings.restartAfterCrashing)
                    .changedFromDefault(viewModel.isChanged(\.restartAfterCrashing))
                    .help("Opens Open Wallpaper Engine again if it crashes, at most 3 times in 5 minutes. The wallpaper that was showing stays off until you retry it.")
            } header: {
                Label("Rendering", systemImage: "wrench.and.screwdriver.fill")
            }
            .settingsAnchor(SettingsAnchor.rendering)
            WebDevtoolsSection(devtools: AppDelegate.shared.webDevtools)
        }
        .onAppear {
            DispatchQueue.global(qos: .utility).async {
                let bytes = WallpaperPackageConverter.reclaimableBytes()
                DispatchQueue.main.async { reclaimableBytes = bytes }
            }
        }
    }
}
