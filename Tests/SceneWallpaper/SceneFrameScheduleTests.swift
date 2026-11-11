import Foundation

@main enum SceneFrameScheduleTests {
    static func main() {
        let origin = ContinuousClock.now
        var count = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            count += 1; print("PASS \(message)")
        }
        func at(_ milliseconds: Int) -> ContinuousClock.Instant {
            origin.advanced(by: .milliseconds(milliseconds))
        }

        var short = SceneFrameSchedule(framesPerSecond: 10, now: origin)
        check(short.deadline == at(100), "initial desktop frame waits one period")
        short.advance(after: at(130))
        check(short.deadline == at(200), "short frame work consumes the period without extending it")
        short.advance(after: at(230))
        check(short.deadline == at(300), "successive deadlines stay on the absolute cadence")

        var long = SceneFrameSchedule(framesPerSecond: 10, now: origin)
        long.advance(after: at(250))
        check(long.deadline == at(300), "long frame skips expired deadlines")
        long.advance(after: at(500))
        check(long.deadline == at(600), "completion at an expired deadline waits a full future slot")
        long.advance(after: at(10_050))
        check(long.deadline == at(10_100), "severe lateness skips many slots without a catch-up burst")
        check(long.deadline > at(10_050), "next frame always sleeps after over-budget work")

        let faster = SceneFrameSchedule(framesPerSecond: 20, now: at(255))
        check(faster.deadline == at(305), "FPS increase re-anchors one new period from the edit")
        let slower = SceneFrameSchedule(framesPerSecond: 1, now: at(255))
        check(slower.deadline == at(1_255), "FPS decrease drops deadlines from the old cadence")
        let resumed = SceneFrameSchedule(framesPerSecond: 10, now: at(30_000))
        check(resumed.deadline == at(30_100), "desktop resume starts a fresh cadence after paused time")
        var lockScreen = SceneFrameSchedule(framesPerSecond: 10, now: at(30_000), immediately: true)
        check(lockScreen.deadline == at(30_000), "lock-screen first frame and resume can render immediately")
        lockScreen.advance(after: at(30_030))
        check(lockScreen.deadline == at(30_100), "lock-screen frame work consumes its current period")
        print("\(count) deterministic Scene frame schedule checks passed")
    }
}
