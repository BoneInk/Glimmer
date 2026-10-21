import Foundation
import CryptoKit

@MainActor final class LockScreenWorkflowGate {
    var entered=false
    private var released=false
    private var continuation:CheckedContinuation<Void,Never>?
    func hold()async {entered=true;if released{return};await withCheckedContinuation{continuation=$0}}
    func release(){released=true;continuation?.resume();continuation=nil}
}
@main @MainActor enum LockScreenActionWorkflowTests {
    static let fm=FileManager.default
    static var checks=0
    struct Failure:Error {let message:String}
    static func check(_ value:Bool,_ name:String)throws {guard value else{throw Failure(message:name)};checks += 1;print("PASS \(name)");fflush(stdout)}
    static func wait(_ name:String,_ condition:@MainActor ()->Bool)async throws {for _ in 0..<1000 {if condition(){return};try await Task.sleep(for:.milliseconds(10))};throw Failure(message:"Timeout: "+name)}
    static func index(_ storage:AppStorage)->URL {ExperimentalLockScreenEnvironment.review(storage:storage).storeDirectory.appendingPathComponent("Index.plist")}
    static func provider(_ storage:AppStorage,_ role:String)throws->String? {
        let object=try PropertyListSerialization.propertyList(from:Data(contentsOf:index(storage)),format:nil) as! [String:Any]
        return (((object["SystemDefault"] as? [String:Any])?[role] as? [String:Any])?["Content"] as? [String:Any])?["Choices"].flatMap{($0 as? [[String:Any]])?.first?["Provider"] as? String}
    }
    static func run(_ root:URL)async throws {
        let video=root.appendingPathComponent("original.mp4");try await SyntheticVideoWriter.write(to:video)
        let source=try Data(contentsOf:video),a=WallpaperItem(title:"Fixture A",filePath:video.path),b=WallpaperItem(title:"Fixture B",filePath:video.path)
        let cancelledStorage=AppStorage(root:root.appendingPathComponent("Cancelled")),preparationGate=LockScreenWorkflowGate()
        let cancelled=LockScreenActionController(coordinator:.review(storage:cancelledStorage),beforePreparation:{await preparationGate.hold()})
        try check(!cancelled.isBusy && !fm.fileExists(atPath:index(cancelledStorage).path),"construction and status do not prepare or write a wallpaper store")
        try check(cancelled.startApply(item:a)==nil && cancelled.isBusy && cancelled.canCancelPreparation,"explicit apply synchronously reserves the single operation before scheduling work")
        try check(cancelled.startApply(item:b) != nil && cancelled.itemID==a.id && cancelled.itemTitle==a.displayTitle,"second item cannot replace busy request ownership or falsely appear applied")
        try await wait("preparation barrier"){preparationGate.entered}
        try check(cancelled.cancelPreparation(),"preparation phase exposes cancellation")
        preparationGate.release();await cancelled.waitUntilIdle()
        try check(cancelled.completion == .cancelled && !cancelled.isBusy && cancelled.coordinator.preparedAsset == nil && !fm.fileExists(atPath:index(cancelledStorage).path),"cancelled preparation never falls through to apply or reuses an old asset")

        let storage=AppStorage(root:root.appendingPathComponent("Applied")),commitGate=LockScreenWorkflowGate(),coordinator=ExperimentalLockScreenCoordinator.review(storage:storage)
        let actions=LockScreenActionController(coordinator:coordinator,beforeCommit:{await commitGate.hold()})
        let originatingViewRequest=Task{@MainActor in actions.startApply(item:a)}
        try check(await originatingViewRequest.value==nil,"page request starts shared operation without awaiting or owning its lifetime")
        originatingViewRequest.cancel()
        try await wait("real prepare reaches commit"){commitGate.entered}
        try check(coordinator.state == .prepared && coordinator.preparedAsset?.itemID==a.id && coordinator.preparedAsset?.videoURL != video,"real video preparation completes in owned assets for the exact requested item")
        try check(actions.isCommitting && !actions.canCancelPreparation && !actions.cancelPreparation(),"application stage cannot be cancelled even before native transaction completes")
        try check(!fm.fileExists(atPath:index(storage).path) && actions.startApply(item:b) != nil && actions.itemID==a.id,"held commit has not touched temporary store and another page cannot replace A with B")
        commitGate.release();await actions.waitUntilIdle()
        try check(actions.completion == .submitted && coordinator.state == .applied && !actions.isBusy,"one click actually prepares then submits the real temporary review transaction")
        try check(try provider(storage,"Desktop")==LockScreenStorePatcher.provider && provider(storage,"Idle")=="review.idle.original","review transaction changes correct desktop/lock role and preserves screen-saver role")
        try check(actions.statusText.contains("已更新") && !actions.statusText.contains("已验证") && actions.itemID==a.id,"inline success names the applied item and does not claim visible lockscreen verification")
        try check(coordinator.canRestorePrevious,"native transaction retains restorable previous configuration")
        try check(actions.restorePrevious()==nil && actions.isCommitting && !actions.cancelPreparation(),"restore uses the same single noncancellable workflow")
        try check(actions.itemID == nil && actions.itemTitle == nil,"restore does not mislabel unknown previous wallpaper as last applied item")
        try check(actions.startApply(item:b) != nil,"apply cannot overlap restore")
        await actions.waitUntilIdle()
        try check(actions.completion == .restored && coordinator.state == .restored && (try provider(storage,"Desktop"))=="review.desktop.unchanged","restore actually restores the previous temporary system provider")
        let reopened=LockScreenActionController(coordinator:.review(storage:storage))
        try check(reopened.itemID == nil && reopened.itemTitle == nil,"reopening restored status never treats retained prepared asset as current wallpaper")
        try check(actions.startApply(item:b)==nil,"next explicit item is accepted after previous operation completes")
        await actions.waitUntilIdle()
        try check(actions.completion == .submitted && coordinator.preparedAsset?.itemID==b.id && actions.itemID==b.id,"later B gets newly prepared matching material rather than stale A asset")
        let beforeFailure=try Data(contentsOf:index(storage)),corrupt=root.appendingPathComponent("corrupt.mp4")
        try Data("not a video".utf8).write(to:corrupt)
        try check(actions.startApply(item:WallpaperItem(title:"Corrupt",filePath:corrupt.path))==nil,"bad existing video enters genuine preparation rather than a fake success path")
        await actions.waitUntilIdle()
        try check(actions.completion == .failed && coordinator.preparedAsset == nil && (try Data(contentsOf:index(storage)))==beforeFailure,"preparation failure does not submit previous B asset or alter prior system transaction")
        try check(!actions.statusText.isEmpty && !actions.isBusy,"failure stays visible inline after operation finishes")

        let mismatchStorage=AppStorage(root:root.appendingPathComponent("Mismatch")),mismatchCore=ExperimentalLockScreenCoordinator.review(storage:mismatchStorage),mismatchGate=LockScreenWorkflowGate()
        let mismatch=LockScreenActionController(coordinator:mismatchCore,beforeCommit:{await mismatchGate.hold()})
        _=mismatch.startApply(item:a);try await wait("mismatch gate"){mismatchGate.entered}
        await mismatchCore.prepare(item:b)
        mismatchGate.release();await mismatch.waitUntilIdle()
        try check(mismatch.completion == .failed && !fm.fileExists(atPath:index(mismatchStorage).path),"prepared asset identity is rechecked immediately before apply; replacement B cannot be committed for A")

        let warningStorage=AppStorage(root:root.appendingPathComponent("ReloadWarning"))
        var environment=ExperimentalLockScreenEnvironment.review(storage:warningStorage);environment.reviewReloadFailureMessage="controlled reload warning"
        let warningCore=ExperimentalLockScreenCoordinator(storage:warningStorage,environment:environment),warning=LockScreenActionController(coordinator:warningCore)
        _=warning.startApply(item:a);await warning.waitUntilIdle()
        try check(warning.completion == .submitted && warningCore.state == .applied && warning.statusText.contains("controlled reload warning"),"post-commit reload warning remains submitted with warning, not a false rollback/failure")
        try check(try provider(warningStorage,"Desktop")==LockScreenStorePatcher.provider,"reload warning really preserves committed temporary provider")
        _=warning.restorePrevious();await warning.waitUntilIdle()
        try check(warning.completion == .restored && warningCore.state == .restored && warning.statusText.contains("controlled reload warning"),"restore reload warning remains restored with warning")
        try check(try Data(contentsOf:video)==source,"prepare/apply/restore/failure leave original source video bytes unchanged")
        print("RESULT \(checks) real review prepare/transaction workflow checks passed; temporary stores/fake registrar only, no real system/desktop/account/GUI changes")
    }
    static func main()async throws {let root=fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("GW-LockScreen-Workflow-\(UUID())");try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)};try await run(root)}
}
