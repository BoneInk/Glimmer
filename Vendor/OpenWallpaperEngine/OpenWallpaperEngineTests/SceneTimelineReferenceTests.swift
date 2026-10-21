import XCTest
@testable import OpenWallpaperEngine

/// `SceneTimelineAnimation` against the float32 reference model of `wallpaper64.exe`
/// (`SceneTimelineReferenceData`): library timelines and synthetic ones, stepped like WE's frame loop.
final class SceneTimelineReferenceTests: XCTestCase {
    func testMatchesTheReferenceModel() throws {
        for testCase in SceneTimelineReferenceData.cases {
            let json = try JSONDecoder().decode(SceneJSON.self, from: Data(testCase.animation.utf8))
            let staticValue = try testCase.staticValue.map {
                try JSONDecoder().decode(SceneJSON.self, from: Data($0.utf8))
            }
            var animation = try SceneTimelineAnimation(json: json, staticValue: staticValue)
            if testCase.play { animation.clock.play() }
            let delta = Float(testCase.delta) * Float(testCase.rate)
            var step = 0
            for checkpoint in testCase.checkpoints {
                while step < checkpoint.step {
                    animation.clock.advance(by: delta)
                    step += 1
                }
                XCTAssertEqual(animation.value(), checkpoint.values,
                               "\(testCase.label), step \(step), time \(animation.clock.time)")
            }
        }
    }
}
