import Foundation

/// Public state only: no cached identity, credentials or console diagnostics.
struct WorkshopAccountPresentation: Equatable {
    enum Tone: Equatable { case neutral, attention, positive, error }
    let title: String
    let message: String
    let actionTitle: String
    let symbol: String
    let tone: Tone

    @MainActor init(account: SteamAccountManager) {
        if account.nativeSavedSessionRetryAvailable, case .failed = account.loginState {
            self.init("Steam 暂未连接", "未能恢复保存的登录，请检查网络或钥匙串访问后重试。",
                      "重试连接", "arrow.clockwise", .attention)
            return
        }
        if account.isSignedIn, account.nativeContentAvailable, !account.isNativeContentReady {
            self.init("Steam 已连接", "账号已连接，可继续准备实时下载会话。",
                      "查看连接", "checkmark.seal.fill", .positive)
            return
        }
        self.init(state:account.loginState,hasCachedSession:account.hasCachedSession,
                  isReady:account.isReady,isProbing:account.isProbing,
                  nativeAvailable:account.nativeContentAvailable,nativeReady:account.isNativeContentReady,
                  nativeSignInActive:account.isUsingNativeSignIn)
    }
    init(state: SteamLoginState, hasCachedSession: Bool, isReady: Bool, isProbing: Bool,
         nativeAvailable: Bool = false, nativeReady: Bool = false, nativeSignInActive: Bool = false) {
        switch state {
        case .loggedIn:
            self.init("Steam 已连接",nativeReady ? "实时下载进度已启用；登录缓存状态可在账号弹窗查看。" : "登录已确认，下载权限仍由 Steam 校验。","管理 Steam 账号","checkmark.seal.fill",.positive)
        case .awaitingUsername:
            self.init("需要账号名","请在 Steam 账号弹窗输入账号名以继续连接。","输入账号名","person.badge.key",.attention)
        case .awaitingPassword:
            self.init("需要 Steam 密码","请在 Steam 账号弹窗输入密码以继续连接。","输入密码","lock",.attention)
        case .awaitingGuardCode:
            self.init("需要 Steam Guard","请在 Steam 账号弹窗输入验证码以继续连接。","输入验证码","key",.attention)
        case .awaitingMobileConfirmation:
            self.init("等待手机确认","请在手机 Steam App 批准登录，然后等待连接完成。","查看账号登录","iphone.gen3",.attention)
        case .preparing, .loggingIn:
            self.init(hasCachedSession && !nativeSignInActive ? "正在验证 Steam 会话":"正在连接 Steam",
                      "正在连接；需要密码或 Steam Guard 时可在账号弹窗继续。","查看连接进度","hourglass",.attention)
        case .finalizing:
            self.init("正在完成 Steam 登录","Steam 已接受登录，正在等待会话正常保存。","查看连接进度","hourglass",.attention)
        case .failed:
            self.init("Steam 需要重新登录","连接未完成，请前往 Steam 账号弹窗重新登录。","重新登录","exclamationmark.circle",.error)
        case .cancelled:
            self.init("Steam 未连接","登录已取消，可在账号弹窗重新连接。","连接 Steam","person.badge.key",.neutral)
        case .idle:
            if nativeAvailable {
                self.init("连接 Steam","连接账号后可显示真实下载进度。","连接 Steam","person.badge.key",.neutral)
            } else if isProbing {
                self.init("正在准备登录","正在检查兼容登录组件。","查看连接进度","hourglass",.attention)
            } else if !isReady {
                self.init("准备连接 Steam","连接前需要准备兼容登录组件。","准备登录","person.badge.key",.neutral)
            } else if hasCachedSession {
                self.init("Steam 会话待验证","发现会话缓存，尚未确认登录。","连接 Steam","questionmark.circle",.attention)
            } else {
                self.init("连接 Steam","连接账号后即可下载拥有的创意工坊内容。","连接 Steam","person.badge.key",.neutral)
            }
        }
    }
    private init(_ title:String,_ message:String,_ actionTitle:String,_ symbol:String,_ tone:Tone) {
        self.title=title;self.message=message;self.actionTitle=actionTitle;self.symbol=symbol;self.tone=tone
    }
}
