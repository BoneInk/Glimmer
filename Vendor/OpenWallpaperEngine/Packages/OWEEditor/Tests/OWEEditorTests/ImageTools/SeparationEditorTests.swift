import XCTest
@testable import OWEEditor
@testable import OWESceneEditing

/// The separation window's editing: the polygon tool's clicks, the brush, Undo and Redo.
@MainActor
final class SeparationEditorTests: XCTestCase {
    private func editor() -> SeparationEditor {
        var settings = ForegroundSeparator.Settings()
        settings.autoRecalculate = false
        return SeparationEditor(picture: RGBAImage(width: 100, height: 80), settings: settings)
    }

    func testClickingOutlinesAPolygonAndClosesItOnItsFirstPoint() {
        let editor = editor()
        editor.polygonClick(at: SIMD2(10, 10), reach: 4)
        editor.polygonClick(at: SIMD2(60, 10), reach: 4)
        editor.polygonClick(at: SIMD2(60, 50), reach: 4)
        XCTAssertEqual(editor.openPolygon, 0)
        editor.polygonClick(at: SIMD2(11, 11), reach: 4)
        XCTAssertNil(editor.openPolygon)
        XCTAssertEqual(editor.marks.polygons, [[SIMD2(10, 10), SIMD2(60, 10), SIMD2(60, 50), SIMD2(10, 10)]])
        XCTAssertTrue(editor.needsRecalculate, "Auto Recalculate off: the change waits")
        // A click on a side inserts a point; ⌥-click (deletePoint) removes it again.
        editor.polygonClick(at: SIMD2(35, 11), reach: 4)
        XCTAssertEqual(editor.marks.polygons[0].count, 5)
        XCTAssertEqual(editor.marks.polygons[0][1], SIMD2(35, 10))
        editor.deletePoint(SeparationEditor.PolygonPoint(polygon: 0, point: 1))
        XCTAssertEqual(editor.marks.polygons[0].count, 4)
        editor.undo()
        XCTAssertEqual(editor.marks.polygons[0].count, 5)
        editor.redo()
        XCTAssertEqual(editor.marks.polygons[0].count, 4)
    }

    func testBrushStrokesJoinTheMarksWhenTheyEnd() {
        let editor = editor()
        editor.setMode(.brush)
        editor.brushSize = 1
        editor.beginStroke(at: SIMD2(5.5, 5.5), erasing: false)
        editor.continueStroke(to: SIMD2(20.5, 5.5), erasing: false)
        XCTAssertFalse(editor.marks.hasMarks, "drawn over the marks until the stroke ends")
        editor.endStroke()
        XCTAssertEqual(editor.marks.marks[5 * 100 + 12], .foreground)
        XCTAssertNotNil(editor.marksImage)
        editor.undo()
        XCTAssertFalse(editor.marks.hasMarks)
    }

    func testUndoKeepsThirtySteps() {
        let editor = editor()
        for index in 0..<40 { editor.polygonClick(at: SIMD2(Double(index * 2), 40), reach: 0.5) }
        var steps = 0
        while editor.canUndo { editor.undo(); steps += 1 }
        XCTAssertEqual(steps, 30)
    }
}
