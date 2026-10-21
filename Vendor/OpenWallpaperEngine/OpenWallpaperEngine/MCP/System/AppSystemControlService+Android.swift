import Foundation
import OWEControlProtocol

/// Android export for the control channel: the same plan, queue and exporter as the
/// library's sheet, with the wallpapers' own values (what the sheet's preview starts from).
extension AppSystemControlService {
    func exportAndroid(_ request: SystemAndroidRequest) async throws -> AndroidExportBatch {
        guard !isExporting else {
            throw ControlError(.unavailable, "Another export from an MCP client is running. Wait for it to finish, then try again.")
        }
        isExporting = true
        defer { isExporting = false }
        let wallpapers = try request.wallpapers.map(found)
        let options = request.options
        let plan = AndroidExportPlan.make(wallpapers, options: { _ in options }, properties: wallpaperValues)
        let folder = request.outputFolder ?? AndroidExporter.cacheDirectory.appending(path: "Packages", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw ControlError(.failed, "The folder \(folder.path(percentEncoded: false)) can't be made: \(error.localizedDescription)")
        }
        OWELog.info(.app, "MCP: exporting \(plan.items.count) wallpapers for Android")
        let queue = AndroidExportQueue(items: plan.items, skipped: plan.skipped, folder: folder, worker: AndroidExporter())
        return await withTaskCancellationHandler {
            await queue.run()
        } onCancel: {
            Task { @MainActor in queue.cancel() }
        }
    }

    /// As the sheet's "Send over Wi-Fi", without the sheet: it serves until it expires or another
    /// call replaces it.
    func sendAndroidOverWiFi(_ request: SystemAndroidSendRequest) async throws -> SystemAndroidSendResult {
        var batch: AndroidExportBatch?
        let files: [AndroidWiFiFile]
        if let export = request.export {
            let exported = try await exportAndroid(export)
            batch = exported
            files = AndroidWiFiFile.files(of: exported)
        } else {
            files = try await Task.detached(priority: .userInitiated) { [packages = request.packages] in
                try Self.wifiFiles(packages: packages)
            }.value
        }
        guard !files.isEmpty else { throw ControlError(.failed, "There is nothing to send: no package was exported.") }
        wifiSession?.stop()
        let session = AndroidWiFiSession(files: files)
        wifiSession = session
        await session.start(preferred: request.address)
        let addresses = session.addresses.map(\.host)
        if let address = request.address, !addresses.contains(address) {
            session.stop()
            throw ControlError(.invalidParams, "address must be one of the Mac's local-network addresses: \(addresses.joined(separator: ", ")).")
        }
        switch session.state {
        case .noNetwork:
            throw ControlError(.unavailable, "This Mac has no Wi-Fi or local-network address. Connect it to the Android device's network, or copy the packages another way.")
        case .failed(let reason):
            throw ControlError(.failed, "The server couldn't start: \(reason)")
        default:
            break
        }
        guard let url = session.url else { throw ControlError(.failed, "The server stopped before it started serving.") }
        return SystemAndroidSendResult(url: url, expiry: session.expiry, files: files, addresses: addresses, batch: batch)
    }

    /// Packages an export already wrote, read from their own project.json: only `.mpkg` files that
    /// are WE mobile packages (`PKGM`), so nothing else on the Mac can be served.
    nonisolated static func wifiFiles(packages: [URL]) throws -> [AndroidWiFiFile] {
        let titles: [AndroidExportOutbox.Package]
        do {
            titles = try packages.map(AndroidExportOutbox.describe(package:))
        } catch {
            throw ControlError(.invalidParams, error.localizedDescription)
        }
        let names = AndroidExportNaming.uniqueNames(titles.map(\.title), taken: [])
        return packages.indices.map { index in
            AndroidWiFiFile(index: index, title: titles[index].title, kind: titles[index].kind, url: packages[index],
                            size: titles[index].size, previewURL: nil, downloadName: names[index])
        }
    }
}
