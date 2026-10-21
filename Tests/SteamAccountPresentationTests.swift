import Foundation

@main @MainActor enum SteamAccountPresentationTests {
    static var checks=0
    static func check(_ condition:Bool,_ name:String)throws {guard condition else{throw Failure(message:name)};checks += 1;print("PASS \(name)")}
    struct Failure:Error {let message:String}
    static func main()throws {
        let states:[SteamLoginState]=[.idle,.preparing,.awaitingUsername,.awaitingPassword,.awaitingGuardCode,.awaitingMobileConfirmation,.loggingIn,.finalizing,.loggedIn(userID:nil),.failed(reason:"synthetic-private-diagnostic"),.cancelled]
        for state in states {for cache in [false,true] {for ready in [false,true] {for probing in [false,true] {
            let p=WorkshopAccountPresentation(state:state,hasCachedSession:cache,isReady:ready,isProbing:probing)
            if case .loggedIn=state {
                try check(p.tone == .positive && p.title == "Steam 已连接","actual loggedIn is connected across cache/dependency presentation contexts")
            } else {
                try check(p.tone != .positive && !p.title.contains("已连接"),"cache/dependency flags cannot turn nonauthenticated state into connected")
            }
            guard !p.actionTitle.isEmpty && !p.message.isEmpty && !p.symbol.isEmpty else {throw Failure(message:"Missing direct action/status")}
            guard !p.message.contains("synthetic-private-diagnostic") else {throw Failure(message:"Private failure detail leaked into mainstream notice")}
        }}}}
        func present(_ state:SteamLoginState)->WorkshopAccountPresentation {.init(state:state,hasCachedSession:true,isReady:true,isProbing:false)}
        try check(present(.awaitingGuardCode).actionTitle=="输入验证码" && present(.awaitingGuardCode).title.contains("Guard"),"Guard requires a direct account-page input action instead of generic cache-pending")
        try check(present(.awaitingPassword).actionTitle=="输入密码","password prompt has the correct direct account-page action")
        try check(present(.awaitingUsername).actionTitle=="输入账号名","expired-cache manual username path stays visible")
        try check(present(.awaitingMobileConfirmation).title=="等待手机确认" && present(.awaitingMobileConfirmation).message.contains("手机"),"mobile approval is visibly distinct from a code input")
        try check(present(.finalizing).tone == .attention && present(.finalizing).title.contains("正在完成"),"accepted but unfinalized login is not shown as connected")
        try check(present(.failed(reason:"hidden")).actionTitle=="重新登录" && present(.failed(reason:"hidden")).tone == .error,"failed cached session visibly offers manual reconnect")
        try check(present(.preparing).title.contains("正在验证") && present(.loggingIn).actionTitle=="查看连接进度","automatic cache verification and its account entry are visible")
        try check(present(.cancelled).title=="Steam 未连接" && present(.cancelled).actionTitle=="连接 Steam","cancelled validation does not look pending forever")
        try check(present(.idle).title=="Steam 会话待验证" && present(.idle).tone == .attention,"idle cache remains explicitly unverified")
        let detecting=WorkshopAccountPresentation(state:.idle,hasCachedSession:true,isReady:false,isProbing:true)
        try check(detecting.title=="正在检测 SteamCMD" && detecting.message.contains("就绪后验证"),"dependency detection accurately explains subsequent cache validation")
        let missing=WorkshopAccountPresentation(state:.idle,hasCachedSession:true,isReady:false,isProbing:false)
        try check(missing.actionTitle=="准备下载依赖","missing dependency offers preparation instead of claiming connection")
        let nativeIdle = WorkshopAccountPresentation(state:.idle,hasCachedSession:true,isReady:false,isProbing:false,nativeAvailable:true)
        try check(nativeIdle.actionTitle == "连接 Steam" && !nativeIdle.message.contains("SteamCMD"), "available native authentication is not blocked by missing legacy dependency")
        let nativeConnected = WorkshopAccountPresentation(state:.loggedIn(userID:nil),hasCachedSession:false,isReady:false,isProbing:false,nativeAvailable:true,nativeReady:true)
        try check(nativeConnected.message.contains("实时下载进度已启用") && nativeConnected.message.contains("缓存状态"), "authenticated native summary distinguishes live progress from login-cache status")
        let nativeConnecting = WorkshopAccountPresentation(state:.loggingIn,hasCachedSession:true,isReady:true,isProbing:false,nativeAvailable:true,nativeReady:false,nativeSignInActive:true)
        try check(nativeConnecting.title == "正在连接 Steam" && nativeConnecting.tone != .positive, "manual native login is not mislabelled as legacy cache restoration")
        print("RESULT \(checks) real SteamLoginState presentation checks passed; pure state only, no account/cache/process/network/GUI access")
    }
}
