import AppKit
import SwiftUI
import XCTest
@testable import OWEInspectorKit

/// The number field and its unit ("×", "%", "°") sit on one line at the inspector's narrowest
/// width (260 pt), beside a long localized label: squeezed, the unit label used to wrap and the
/// number was drawn above it.
///
/// The row is hosted in an `NSHostingView` and drawn: the number field is the AppKit text field
/// SwiftUI puts in the host, and the unit is the only ink to the field's right, so the unit's
/// frame is measured from the drawn pixels.
@MainActor
final class NumericSliderInputLayoutTests: XCTestCase {
    private static let inspectorWidth: CGFloat = 260
    private static let rowHeight: CGFloat = 80
    /// Long German and Russian labels, the widest the editor's inspector shows beside a slider.
    private static let longLabels = ["Maximales Drehmoment", "Максимальное расстояние"]

    func testScaleValueAndUnitShareALine() throws {
        try assertOneLine(suffix: "×", initial: 1) { binding in
            NumericSliderInput<Double>(value: binding, range: 0.05...5, defaultValue: 1, step: 0.01,
                                       suffix: "×", fractionDigits: 2, fieldWidth: 52, clampsTypedValue: false)
        }
    }

    func testPercentValueAndUnitShareALine() throws {
        try assertOneLine(suffix: "%", initial: 1) { binding in
            NumericSliderInput<Double>(value: binding, range: 0...1, defaultValue: 1, displayScale: 100,
                                       suffix: "%", fractionDigits: 0, fieldWidth: 44)
        }
    }

    func testDegreesValueAndUnitShareALine() throws {
        try assertOneLine(suffix: "°", initial: -180) { binding in
            NumericSliderInput<Double>(value: binding, range: -180...180, defaultValue: 0, step: 1,
                                       suffix: "°", fractionDigits: 1, fieldWidth: 56, clampsTypedValue: false)
        }
    }

    // MARK: Helpers

    private func assertOneLine<Control: View>(suffix: String, initial: Double,
                                              file: StaticString = #filePath, line: UInt = #line,
                                              @ViewBuilder control: (Binding<Double>) -> Control) throws {
        var value = initial
        let binding = Binding<Double>(get: { value }, set: { value = $0 })

        // Squeezed to what a long label leaves it, the control stays one line high: a wrapped
        // unit, or a number stacked over it, makes it two lines tall.
        let squeezed = NSHostingView(rootView: control(binding).frame(width: 110))
        XCTAssertLessThan(squeezed.fittingSize.height, 32,
                          "“\(suffix)” control is taller than one line when squeezed", file: file, line: line)

        for label in Self.longLabels {
            let row = LabeledContent { control(binding) } label: { Text(verbatim: label) }
                .padding(.horizontal, 10)
                .frame(width: Self.inspectorWidth, height: Self.rowHeight)
                .background(Color.white)
                .environment(\.colorScheme, .light)
            let host = NSHostingView(rootView: row)
            let bounds = NSRect(x: 0, y: 0, width: Self.inspectorWidth, height: Self.rowHeight)
            let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = host
            host.frame = bounds
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            host.layoutSubtreeIfNeeded()
            defer { window.contentView = nil }

            let textField = try XCTUnwrap(Self.textFields(in: host).first,
                                          "no number field beside “\(label)”", file: file, line: line)
            let fieldFrame = textField.convert(textField.bounds, to: host)
            XCTAssertLessThanOrEqual(fieldFrame.maxX, bounds.maxX, "the number field is pushed out of the row",
                                     file: file, line: line)

            let ink = try XCTUnwrap(Self.ink(in: host, rightOf: fieldFrame.maxX + 1),
                                    "“\(suffix)” isn't drawn after the number beside “\(label)”", file: file, line: line)
            XCTAssertTrue(fieldFrame.minY <= ink.midY && ink.midY <= fieldFrame.maxY,
                          "“\(suffix)” \(ink) is off the number's line \(fieldFrame) beside “\(label)”",
                          file: file, line: line)
            XCTAssertLessThan(ink.height, fieldFrame.height,
                              "“\(suffix)” wrapped onto two lines beside “\(label)”", file: file, line: line)
            XCTAssertLessThan(ink.minX - fieldFrame.maxX, 12, "“\(suffix)” drifted away from the number",
                              file: file, line: line)
        }
    }

    private static func textFields(in view: NSView) -> [NSTextField] {
        view.subviews.flatMap { subview -> [NSTextField] in
            if let field = subview as? NSTextField, field.isEditable { return [field] }
            return textFields(in: subview)
        }
    }

    /// The bounds, in the host's (flipped) points, of what's drawn right of `minX`, on the white
    /// row background; nil when nothing is.
    private static func ink(in host: NSView, rightOf minX: CGFloat) -> CGRect? {
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / host.bounds.width
        var box: CGRect?
        for y in 0..<rep.pixelsHigh {
            for x in Int((minX * scale).rounded(.up))..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let darkest = min(color.redComponent, color.greenComponent, color.blueComponent)
                guard darkest < 0.85, color.alphaComponent > 0.2 else { continue }
                let pixel = CGRect(x: CGFloat(x) / scale, y: CGFloat(y) / scale, width: 1 / scale, height: 1 / scale)
                box = box.map { $0.union(pixel) } ?? pixel
            }
        }
        return box
    }
}
