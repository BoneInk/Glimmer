import Foundation

@main @MainActor
enum SceneDetailInteractionTests {
    @MainActor final class Gate {
        var continuation: CheckedContinuation<String?, Never>?
        var calls = 0
        var observedCancellation = false
        func operation() async -> String? {
            calls += 1
            let result = await withCheckedContinuation { continuation = $0 }
            observedCancellation = Task.isCancelled
            return result
        }
        func finish(_ error: String? = nil) { continuation?.resume(returning: error); continuation = nil }
    }
    static func main() async {
        var count = 0
        func check(_ condition: Bool, _ name: String) { precondition(condition, name); count += 1 }
        func drain() async { for _ in 0..<100 { await Task.yield() } }
        for phase in [ScenePreviewControlsState.Phase.unavailable, .idle, .loading, .failed, .disposed] {
            check(!ScenePreviewControlsState(phase: phase).canTogglePause, "unavailable/nonready preview has no usable pause action")
        }
        for phase in [ScenePreviewControlsState.Phase.ready, .paused] {
            check(ScenePreviewControlsState(phase: phase).canTogglePause, "ready/paused own preview can toggle")
            check(!ScenePreviewControlsState(phase: phase, hasError: true).canTogglePause, "visible preview failure disables stale ready controls")
        }
        let a = UUID(), b = UUID(), relay = ScenePreviewControlsRelay()
        relay.activate(itemID: a)
        relay.accept(itemID: a, state: .init(phase: .ready))
        check(relay.controls.canTogglePause, "own actual host snapshot reaches controls")
        relay.activate(itemID: b)
        relay.accept(itemID: a, state: .init(phase: .ready))
        check(!relay.controls.canTogglePause && relay.itemID == b, "old preview cannot enable new item controls")
        relay.accept(itemID: b, state: .init(phase: .paused))
        relay.accept(itemID: a, state: .init(phase: .failed, hasError: true))
        check(relay.controls.phase == .paused, "old preview cannot overwrite newer ready/paused state")

        let state = DetailWallpaperApplyState(), gate = Gate()
        check(state.begin(itemID: a, target: .display("selected")) { await gate.operation() }, "first apply starts")
        check(state.isPreparing && state.target == .display("selected"), "preparation gate is synchronous and captures selected target")
        check(!state.begin(itemID: a, target: .allDisplays) { "duplicate must not run" }, "all-display repeat cannot race selected-display apply")
        await drain()
        check(gate.calls == 1 && state.isPreparing && !state.succeeded, "enqueue is not falsely reported as success")
        gate.finish("Missing SceneScript module: motion.js")
        await drain()
        check(!state.isPreparing && state.error == "Missing SceneScript module: motion.js" && !state.succeeded, "awaited failure remains exact diagnostic")
        let retry = Gate()
        check(state.begin(itemID: a, target: .allDisplays) { await retry.operation() }, "failed operation can retry")
        check(state.error == nil && state.target == .allDisplays, "retry resets error and preserves all-screen target")
        await drain(); retry.finish(); await drain()
        check(state.succeeded && state.error == nil && !state.isPreparing, "success appears only after awaited operation completes")

        let old = Gate(), newer = Gate()
        state.begin(itemID: a, target: .display("old")) { await old.operation() }
        await drain(); state.cancel()
        check(!state.isPreparing && state.error == nil && !state.succeeded, "close/item switch clears pending presentation")
        state.begin(itemID: b, target: .allDisplays) { await newer.operation() }
        await drain(); old.finish("old item failure"); await drain()
        check(old.observedCancellation, "close/switch cancellation reaches actual awaited operation task")
        check(state.target == .allDisplays && state.error == nil && !state.succeeded, "late old result cannot overwrite new in-flight operation")
        newer.finish(); await drain()
        check(state.succeeded && !state.isPreparing, "new item result publishes normally")

        let cancelled = Gate()
        state.begin(itemID: b, target: .allDisplays) { await cancelled.operation() }
        await drain(); state.cancel(); cancelled.finish(); await drain()
        check(cancelled.observedCancellation && !state.succeeded && state.error == nil, "cancelled success cannot leak into closed detail")
        var immediateCalls = 0
        state.begin(itemID: a, target: .allDisplays) { immediateCalls += 1; return nil }
        state.cancel(); await drain()
        check(immediateCalls == 0, "cancel before scheduling never calls backend")
        print("PASS \(count) Scene detail interaction checks; controlled async operations, no GUI or fake runtime ACK")
    }
}
