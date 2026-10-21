import AppKit
import OWEInspectorKit
import SwiftUI
import UniformTypeIdentifiers

/// "Send over Wi-Fi": the Android exports list (`AndroidExportOutbox`) as a grid of previews to
/// pick from (everything not downloaded yet, at first), then the QR code and address of the page
/// the Android device downloads the chosen packages from, the time left, each one's downloads and
/// which device made them, and what to try when the phone can't connect. Packages can be picked,
/// added or removed while it shares; the page follows. Closing the window stops the server and
/// the link with it.
struct AndroidWiFiSendSheet: View {
    @Environment(\.appAccentColor) private var accentColor
    @ObservedObject var outbox: AndroidExportOutbox
    @ObservedObject var session: AndroidWiFiSession
    let dismiss: () -> Void
    /// The entries to share, by number.
    @State private var selection: Set<Int>
    /// The entries the grid has shown, so new ones start selected.
    @State private var known: Set<Int>
    @State private var hasStarted = false
    @State private var addError: String?
    /// For devices that can't resolve `.local` names.
    @State private var qrUsesIPAddress = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    init(outbox: AndroidExportOutbox, session: AndroidWiFiSession, dismiss: @escaping () -> Void) {
        self.outbox = outbox
        self.session = session
        self.dismiss = dismiss
        _selection = State(initialValue: Set(outbox.entries.filter { !$0.isDownloaded }.map(\.number)))
        _known = State(initialValue: Set(outbox.entries.map(\.number)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Send over Wi-Fi")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    addPackages()
                } label: {
                    Label("Add .mpkg Files…", systemImage: "plus")
                }
                .glassButtonStyle()
            }
            if hasStarted, session.state == .noNetwork {
                noNetwork
            } else {
                if hasStarted { address }
                grid
                if let addError {
                    Text(addError).font(.caption).foregroundStyle(.red)
                }
                if hasStarted { help }
            }
            footer
        }
        .padding(20)
        .frame(width: 760, height: 720)
        .onAppear { outbox.prune() }
        .onDisappear { session.stop() }
        .onChange(of: outbox.entries) { _, entries in
            let numbers = Set(entries.map(\.number))
            let added = numbers.subtracting(known).filter { number in entries.first { $0.number == number }?.isDownloaded == false }
            known = numbers
            selection = selection.intersection(numbers).union(added)
        }
        .onChange(of: selection) { _, _ in
            if hasStarted, session.isActive { session.update(files: outbox.wifiFiles(selection)) }
        }
        .onChange(of: session.progress) { _, progress in
            for (number, entry) in progress {
                for device in entry.completedBy { outbox.markDownloaded(number, by: device) }
            }
        }
    }

    private func share() {
        hasStarted = true
        session.update(files: outbox.wifiFiles(selection))
        Task { await session.start() }
    }

    private func addPackages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: AndroidExportNaming.fileExtension) ?? .data]
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        addError = nil
        Task {
            do {
                try await outbox.add(packages: urls)
            } catch {
                addError = error.localizedDescription
            }
        }
    }

    // MARK: Address

    private var address: some View {
        HStack(alignment: .top, spacing: 18) {
            qrCode
            VStack(alignment: .leading, spacing: 10) {
                Text("Scan the code with your Android device's camera, or open the address in its browser. Both devices must be on the same network.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if let url = session.url {
                    HStack(spacing: 6) {
                        Text(verbatim: url.absoluteString)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(2)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .borderlessOnGlassButtonStyle()
                        .help("Copy Address")
                    }
                }
                if let ip = session.ipURL, session.localURL != nil {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("If that doesn't open: \(Text(verbatim: ip.absoluteString).monospaced())")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Toggle("Use IP address in QR code", isOn: $qrUsesIPAddress)
                            .toggleStyle(.checkbox)
                            .controlSize(.small)
                    }
                }
                if session.addresses.count > 1 { networkPicker }
                status
            }
        }
    }

    @ViewBuilder
    private var qrCode: some View {
        let side: CGFloat = 196
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white)
            if let url = session.qrURL(usesIPAddress: qrUsesIPAddress),
               let image = AndroidWiFiQRCode.image(for: url.absoluteString, side: Int((side - 8) * displayScale),
                                                   appearance: NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)) {
                Image(decorative: image, scale: displayScale)
                    .resizable()
                    .padding(4)
                    .accessibilityLabel(Text("QR code of the address"))
            } else if session.isActive {
                ProgressView()
            } else {
                Image(systemName: "qrcode").font(.system(size: 64)).foregroundStyle(.gray.opacity(0.4))
            }
        }
        .frame(width: side, height: side)
    }

    private var networkPicker: some View {
        Picker("Network", selection: Binding(get: { session.address }, set: { address in
            guard let address else { return }
            Task { await session.choose(address) }
        })) {
            ForEach(session.addresses) { address in
                Text(verbatim: "\(address.displayName ?? address.interface) – \(address.host)").tag(Optional(address))
            }
        }
        .frame(maxWidth: 320)
    }

    @ViewBuilder
    private var status: some View {
        switch session.state {
        case .starting:
            ProgressView().controlSize(.small)
        case .serving:
            let now = Date()
            Label {
                Text("Expires in \(Text(timerInterval: now...max(now, session.expiry), countsDown: true))")
                    .monospacedDigit()
            } icon: {
                Image(systemName: "timer")
            }
            .foregroundStyle(.secondary)
        case .stopped(.expired):
            Label("The link expired. Send again to make a new one.", systemImage: "clock.badge.xmark")
                .foregroundStyle(.secondary)
        case .stopped:
            Label("Sending stopped.", systemImage: "stop.circle")
                .foregroundStyle(.secondary)
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        case .noNetwork:
            EmptyView()
        }
    }

    // MARK: Files

    private var grid: some View {
        ScrollView {
            if outbox.entries.isEmpty {
                Text("No Android exports yet. Export a wallpaper for Android, or add .mpkg files.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                    ForEach(outbox.entries) { entry in
                        tile(entry, progress: session.progress[entry.number] ?? .init())
                    }
                }
                .padding(12)
            }
        }
        .glassBackground(in: RoundedRectangle(cornerRadius: 12, style: .continuous)) {
            $0.background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func tile(_ entry: AndroidExportOutbox.Entry, progress: AndroidWiFiSession.Progress) -> some View {
        let selected = selection.contains(entry.number)
        return VStack(alignment: .leading, spacing: 4) {
            AndroidExportPreview(url: outbox.previewURL(of: entry))
                .frame(height: 100)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(alignment: .topLeading) {
                    Toggle("Share", isOn: Binding(get: { selected }, set: { on in
                        if on { selection.insert(entry.number) } else { selection.remove(entry.number) }
                    }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .padding(6)
                }
                .overlay(alignment: .topTrailing) {
                    Menu {
                        actions(entry)
                    } label: {
                        Image(systemName: "ellipsis.circle.fill")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .padding(6)
                }
            Text(entry.title).lineLimit(1)
            Text(verbatim: ([AndroidWiFiPage.label(entry.kind)] + [entry.device].compactMap { $0 }
                            + [entry.size.formatted(.byteCount(style: .file))]).joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if progress.isDownloading || (progress.position > 0 && progress.completedBy.isEmpty) {
                ProgressView(value: Double(progress.position), total: Double(max(entry.size, 1)))
                    .controlSize(.small)
            }
            if !entry.downloadedBy.isEmpty {
                Label {
                    Text("Downloaded by \(entry.downloadedBy.formatted(.list(type: .and)))")
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(selected ? accentColor : Color.secondary.opacity(0.25), lineWidth: selected ? 2 : 1))
        .contentShape(Rectangle())
        .onTapGesture {
            if selected { selection.remove(entry.number) } else { selection.insert(entry.number) }
        }
        .contextMenu { actions(entry) }
    }

    @ViewBuilder
    private func actions(_ entry: AndroidExportOutbox.Entry) -> some View {
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
        Button("Remove from List") { outbox.remove([entry.number]) }
    }

    // MARK: Help

    private var help: some View {
        DisclosureGroup("Can't connect?") {
            VStack(alignment: .leading, spacing: 6) {
                Label("The first time a device connects, macOS may ask whether Open Wallpaper Engine may accept incoming network connections. Click Allow.", systemImage: "lock.shield")
                Label("Some networks (guest and public Wi-Fi, some mesh systems) keep devices from reaching each other. Use your home network, or turn off client isolation (\"AP isolation\") in the router's settings.", systemImage: "wifi.exclamationmark")
                Label("If downloads stop, keep this window open and tap Download again: it resumes.", systemImage: "arrow.clockwise")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
        }
    }

    // MARK: No network

    private var noNetwork: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "wifi.slash").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("This Mac isn't connected to a Wi-Fi or local network.")
                .font(.headline)
            Text("Connect it to the same network as your Android device and try again, or save the files to a folder and copy them to the device another way.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            GlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    Button("Try Again") { Task { await session.start() } }
                        .glassButtonStyle()
                    Button("Save to Folder…") { session.saveToFolder() }
                        .glassButtonStyle(.prominent)
                }
            }
            if let error = session.saveError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Spacer()
            if hasStarted, session.isActive {
                Button("Stop Sending") { session.stop() }
                    .glassButtonStyle()
            } else {
                Button("Done") { dismiss() }
                    .glassButtonStyle()
                Button(hasStarted ? LocalizedStringKey("Send Again") : LocalizedStringKey("Start Sharing")) { share() }
                    .glassButtonStyle(.prominent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection.isEmpty)
            }
        }
    }
}

/// An Android exports list entry's preview picture, downsampled off the main thread; a GIF shows
/// its first frame.
private struct AndroidExportPreview: View {
    let url: URL?
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .task(id: url) {
            guard let url else { return }
            image = await Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 400,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                      ] as CFDictionary) else { return nil }
                return NSImage(cgImage: thumbnail, size: .zero)
            }.value
        }
    }
}

/// The "Send over Wi-Fi" window: one at a time, from the export sheets' "Send over Wi-Fi…", the
/// File menu and the menu bar. Closing it stops sharing.
@MainActor
enum AndroidWiFiShareWindow {
    private static var window: NSWindow?
    private static var session: AndroidWiFiSession?
    private static var observer: NSObjectProtocol?

    static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let session = AndroidWiFiSession(files: [])
        let window = NSWindow()
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.title = String(localized: "Send over Wi-Fi")
        window.contentView = NSHostingView(rootView: AndroidWiFiSendSheet(outbox: .shared, session: session) { [weak window] in
            window?.close()
        }.frostedWindowBackground().appAccentTint())
        observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { close() }
        }
        self.window = window
        self.session = session
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func close() {
        session?.stop()
        session = nil
        window?.contentView = nil
        window = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}

extension AppDelegate {
    @objc func showAndroidWiFiShare() { AndroidWiFiShareWindow.show() }
}
