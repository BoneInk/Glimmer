import XCTest
@testable import OpenWallpaperEngine

final class ProcessPriorityTests: XCTestCase {
    func testNormalKeepsFramesAtUserInteractive() {
        let normal = ProcessPriority(.normal)
        XCTAssertEqual(normal.nice, 0)
        XCTAssertEqual(normal.renderQoS, .userInteractive)
        XCTAssertEqual(normal.renderThreadQoS, .userInteractive)
        XCTAssertEqual(normal.preparationQoS(.settingWallpaper), .userInitiated)
        XCTAssertEqual(normal.preparationQoS(.currentWallpaper), .utility)
        XCTAssertEqual(normal.preparationQoS(.library), .background)
    }

    func testBelowNormalLowersNiceRenderAndPreparation() {
        let normal = ProcessPriority(.normal)
        let below = ProcessPriority(.belowNormal)
        XCTAssertGreaterThan(below.nice, normal.nice)
        XCTAssertLessThan(below.renderQoS.rawValue.rawValue, normal.renderQoS.rawValue.rawValue)
        XCTAssertLessThan(below.settingWallpaperQoS.rawValue.rawValue, normal.settingWallpaperQoS.rawValue.rawValue)
        XCTAssertEqual(below.preparationQoS(.library), .background)
    }

    func testRenderThreadsStayAboveBackground() {
        for setting in GSProcessPiority.allCases {
            let priority = ProcessPriority(setting)
            XCTAssertGreaterThan(priority.renderQoS.rawValue.rawValue, DispatchQoS.QoSClass.utility.rawValue.rawValue,
                                 "\(setting) must not starve frames")
        }
    }
}
