import Foundation
import Observation

#if canImport(ServiceManagement)
import ServiceManagement
#endif

// F17 登录项（仅在独立应用包构建且用户显式操作时注册）。
//
// 约束：
// - 只有用户主动打开开关才会调用注册/注销 API；打开设置页只读取状态。
// - 需要系统允许时如实显示「等待系统批准」，并提供打开系统设置的入口。
// - 注册失败时展示系统返回的真实错误，不伪造成功。
@MainActor
@Observable
final class GWLoginItemService {
    enum Status: Equatable {
        /// 当前构建不支持（例如未从 .app 运行）。
        case unsupported(reason: String)
        case notRegistered
        case enabled
        /// 已提交注册，但需要在系统设置中批准。
        case requiresApproval
        case failed(String)
    }

    private(set) var status: Status

    private let bundleURL: URL
    private let bundleIdentifier: String?

    /// 是否具备注册条件（独立应用包 + 有效标识符）。
    var isSupported: Bool {
        Self.supportsRegistration(bundleURL: bundleURL, bundleIdentifier: bundleIdentifier)
    }

    /// 静态门槛（便于独立验证）。
    static func supportsRegistration(bundleURL: URL, bundleIdentifier: String?) -> Bool {
        bundleURL.pathExtension.lowercased() == "app" && !(bundleIdentifier ?? "").isEmpty
    }

    init(
        bundleURL: URL = Bundle.main.bundleURL,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) {
        self.bundleURL = bundleURL
        self.bundleIdentifier = bundleIdentifier
        self.status = .notRegistered
        refreshStatus()
    }

    /// 读取当前状态（只读，无副作用）。
    func refreshStatus() {
        guard isSupported else {
            status = .unsupported(reason: "当前运行的不是独立应用包，无法注册为登录项。")
            return
        }
        #if canImport(ServiceManagement)
        switch SMAppService.mainApp.status {
        case .notRegistered:
            status = .notRegistered
        case .enabled:
            status = .enabled
        case .requiresApproval:
            status = .requiresApproval
        case .notFound:
            status = .unsupported(reason: "系统未找到此应用包；请将应用移动到「应用程序」文件夹后再试。")
        @unknown default:
            status = .failed("系统返回了未知的登录项状态。")
        }
        #else
        status = .unsupported(reason: "当前系统不支持登录项注册。")
        #endif
    }

    /// 用户显式切换开关后才调用（注册/注销）。
    func setEnabled(_ enabled: Bool) async {
        guard isSupported else { return }
        #if canImport(ServiceManagement)
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try await SMAppService.mainApp.unregister()
            }
        } catch {
            status = .failed("登录项操作失败：\(error.localizedDescription)")
            return
        }
        refreshStatus()
        #endif
    }

    /// 打开「系统设置 → 通用 → 登录项」，供用户批准或检查。
    func openSystemSettingsLoginItems() {
        #if canImport(ServiceManagement)
        SMAppService.openSystemSettingsLoginItems()
        #endif
    }

    /// 开关显示的当前值。
    var isToggleOn: Bool {
        switch status {
        case .enabled, .requiresApproval: return true
        default: return false
        }
    }

    /// 状态说明（中文，直观可理解）。
    var statusText: String {
        switch status {
        case .unsupported(let reason):
            return reason
        case .notRegistered:
            return "未注册为登录项。开启后，登录 Mac 时会自动启动Glimmer并恢复桌面播放。"
        case .enabled:
            return "已注册为登录项，登录时会自动启动。"
        case .requiresApproval:
            return "已提交注册，但需要你在「系统设置 → 通用 → 登录项」中允许后才会生效。"
        case .failed(let message):
            return message
        }
    }

    /// 是否需要展示「打开系统设置」入口。
    var showsSystemSettingsButton: Bool {
        switch status {
        case .requiresApproval, .failed, .notRegistered, .enabled: return true
        case .unsupported: return false
        }
    }
}
