import AppKit
import Foundation
import Darwin

/// Explicit inspection or dependency preparation through the normal account/broker.
/// Never inspects credential caches or changes wallpaper/library configuration.
@MainActor
enum SceneEngineAssetDiagnostic {
    private struct Report: Encodable {
        let status: String
        let errorCode: String?
        let inspection: SteamEngineAssetInspection?
        var inventory: SteamEngineAssetInventory? = nil
        var bundle: BundleReport? = nil
        var runtimeBundle: RuntimeBundleReport? = nil
    }
    private struct RuntimeBundleReport: Encodable {
        let rootURL: String; let manifestIdentity: SteamEngineAssetManifestIdentity
        let fileCount: Int; let totalBytes: UInt64; let files: [SteamEngineAssetFile]
    }

    private struct BundleReport: Encodable {
        let rootURL: String
        let manifestIdentity: String
        let verifiedFiles: [String: String]
        let archivePaths: [String]
    }

    static func run(arguments: [String]) async -> Int32 {
        guard let index = arguments.firstIndex(of: "--evidence"), index + 1 < arguments.count,
              arguments[index + 1].hasPrefix("/"), arguments[index + 1].count <= 4096 else {
            print("请提供绝对路径：--evidence <目录>")
            return 2
        }
        let output = URL(fileURLWithPath: arguments[index + 1], isDirectory: true).standardizedFileURL
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let values = try output.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true,
                  output.resolvingSymlinksInPath().path == output.path else { return 2 }
        } catch { print("无法创建检查报告目录。" ); return 2 }

        let isInventory = arguments.contains("--inventory-scene-engine-assets")
        let isRuntimeDownload = arguments.contains("--download-scene-runtime-assets")
        func write(_ report: Report) {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(report) {
                let name = isInventory ? "engine-assets-inventory.json" : isRuntimeDownload ? "scene-runtime-assets.json" : "engine-assets-inspection.json"
                let file = output.appendingPathComponent(name)
                let temporary = output.appendingPathComponent(".engine-assets-\(UUID().uuidString).tmp")
                let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard fd >= 0 else { return }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                do {
                    try handle.write(contentsOf: data); try handle.synchronize(); try handle.close()
                    guard rename(temporary.path, file.path) == 0 else { try? FileManager.default.removeItem(at: temporary); return }
                } catch { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
            }
        }
        guard Bundle.main.bundleIdentifier == AppConstants.bundleIdentifier else {
            write(.init(status: "blocked", errorCode: "application_identity_required", inspection: nil))
            return 2
        }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: AppConstants.bundleIdentifier)
            .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }) else {
            write(.init(status: "blocked", errorCode: "existing_application_session", inspection: nil))
            return 2
        }
        let account = SteamAccountManager(sessionStore: SteamContentKeychainSessionStore())
        await account.prepareForDownloads()
        guard account.isNativeContentReady, let broker = account.nativeContentBroker else {
            await account.shutdownNativeContent()
            write(.init(status: "blocked", errorCode: "steam_session_not_ready", inspection: nil))
            print("Steam 会话尚未就绪，未查询资源清单。")
            return 1
        }
        do {
            if isInventory {
                let inventory = try await broker.inspectEngineAssetInventory()
                await account.shutdownNativeContent()
                write(.init(status: "complete", errorCode: nil, inspection: nil, inventory: inventory))
                print("Scene 官方资源清单统计完成；未下载资源文件。")
                return 0
            }
            if isRuntimeDownload {
                let downloaded = try await broker.sceneRuntimeAssets()
                try SceneRuntimeAssetRegistry.registerVerifiedSteamBundle(downloaded)
                await account.shutdownNativeContent()
                write(.init(status: "complete", errorCode: nil, inspection: nil,
                    runtimeBundle: .init(rootURL: downloaded.cacheRoot.path, manifestIdentity: downloaded.manifestIdentity,
                        fileCount: downloaded.files.count, totalBytes: downloaded.files.reduce(0) { $0 + $1.sizeBytes }, files: downloaded.files)))
                print("Scene 通用运行资源已下载并校验。")
                return 0
            }
            if arguments.contains("--download-scene-engine-assets") {
                let downloaded = try await broker.engineAssets(desiredResources: SteamContentBroker.requiredEngineAssetResources)
                try SceneEngineAssetResolver.registerVerifiedSteamBundle(downloaded)
                guard let registered = try SceneEngineAssetResolver.loadRegisteredBundle() else {
                    throw SteamContentBrokerError.helperRejected("engine_asset_registration_failed")
                }
                await account.shutdownNativeContent()
                write(.init(status: "complete", errorCode: nil, inspection: nil,
                    bundle: .init(rootURL: registered.rootURL.path, manifestIdentity: registered.manifestIdentity,
                                  verifiedFiles: registered.verifiedFiles, archivePaths: registered.archivePaths)))
                print("Scene 官方内置资源已下载、校验并登记。")
                return 0
            }
            let result = try await broker.inspectEngineAssets()
            await account.shutdownNativeContent()
            write(.init(status: "complete", errorCode: nil, inspection: result))
            print("Scene 资源清单检查完成；未下载资源文件。")
            return 0
        } catch {
            let code: String
            if let registryError = error as? SceneRuntimeAssetRegistryError {
                code = registryError.rawValue
            } else if case SteamContentBrokerError.helperRejected(let value) = error {
                code = value
            } else if let brokerError = error as? SteamContentBrokerError {
                let phase = broker.lastRuntimeDiagnosticPhase ?? "unknown"
                switch brokerError {
                case .protocolViolation: code = "scene_runtime_protocol_\(phase)"
                case .processExited: code = "scene_runtime_process_exited_\(phase)"
                case .timeout: code = "scene_runtime_timeout_\(phase)"
                case .cancelled: code = "cancelled"
                case .busy: code = "scene_runtime_busy"
                case .unavailable: code = "scene_runtime_unavailable"
                default: code = "scene_runtime_broker_failed_\(phase)"
                }
            } else if error is CancellationError { code = "cancelled" }
            else { code = "engine_assets_inspection_failed" }
            await account.shutdownNativeContent()
            write(.init(status: "failed", errorCode: code, inspection: nil))
            print("Scene 资源清单检查未完成（\(code)）。")
            return 1
        }
    }
}
