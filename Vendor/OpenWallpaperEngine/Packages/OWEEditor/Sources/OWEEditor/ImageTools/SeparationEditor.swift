import AppKit
import OWESceneEditing
import SwiftUI

/// One picture being separated (WE's Foreground Separation window, or one limb of Character
/// Sheet Creation): the author's marks with Undo and Redo (WE keeps 30 steps), the brush, the
/// Fine-tuning options, the View options, and the separation worked out from them off the main
/// thread, again after every change while Auto Recalculate is on.
@MainActor
final class SeparationEditor: ObservableObject {
    enum Brush: String, CaseIterable, Identifiable {
        case foreground, background, erase
        var id: String { rawValue }

        var mark: SeparationMarks.Mark {
            switch self {
            case .foreground: return .foreground
            case .background: return .background
            case .erase: return .none
            }
        }
    }

    /// WE's View buttons.
    enum Preview: String, CaseIterable, Identifiable {
        case original, foregroundAndOriginal, foreground, background
        var id: String { rawValue }
    }

    private(set) var picture: RGBAImage
    private(set) var original: CGImage?
    private var fadedCache: CGImage??

    /// The original at 30 %, under the foreground (WE's Improve visibility).
    var fadedOriginal: CGImage? {
        if let fadedCache { return fadedCache }
        let made = Self.faded(original)
        fadedCache = .some(made)
        return made
    }

    private static func faded(_ original: CGImage?) -> CGImage? {
        guard let original else { return nil }
        let width = original.width, height = original.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return original }
        context.setAlpha(0.3)
        context.draw(original, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Another picture to separate with the same marks (a limb whose source changed when a limb
    /// before it was separated again): Vision looks again, and it separates again.
    func setPicture(_ picture: RGBAImage) {
        guard picture != self.picture else { return }
        self.picture = picture
        original = picture.cgImage
        fadedCache = nil
        instances = nil
        result = nil
        foregroundImage = nil
        backgroundImage = nil
        objectWillChange.send()
        start()
    }

    @Published private(set) var marks: SeparationMarks
    @Published var brush: Brush = .foreground
    /// Brush size, 1…100 % (WE's default 20).
    @Published var brushSize: Double = 20
    @Published var settings: ForegroundSeparator.Settings {
        didSet { if settings.autoRecalculate && settingsChangeRecalculates(oldValue) { recalculate() } }
    }
    @Published var preview: Preview = .original
    /// Mask (M): the marks drawn over the picture.
    @Published var showsMarks = true
    /// Mask opacity, 10…100 % (WE's 50).
    @Published var marksOpacity: Double = 50
    /// Improve visibility: the original faded under the foreground.
    @Published var fadesOriginal = true

    @Published private(set) var result: ForegroundSeparator.Result?
    @Published private(set) var foregroundImage: CGImage?
    @Published private(set) var backgroundImage: CGImage?
    @Published private(set) var marksImage: CGImage?
    @Published private(set) var isComputing = false
    /// A change waits for Recalculate (Auto Recalculate off).
    @Published private(set) var needsRecalculate = false
    /// The author changed something (OK needs a mask, as WE's `hasPaintedAnything`).
    @Published private(set) var hasEdits = false
    /// The polygon point selected, and the outline being drawn.
    @Published var selectedPoint: PolygonPoint?
    @Published private(set) var openPolygon: Int?

    struct PolygonPoint: Equatable {
        var polygon: Int
        var point: Int
    }

    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var instances: [ImagePlane]?
    private var generation = 0
    private var isFindingObjects = false

    init(picture: RGBAImage, settings: ForegroundSeparator.Settings) {
        self.picture = picture
        original = picture.cgImage
        marks = SeparationMarks(width: picture.width, height: picture.height)
        self.settings = settings
    }

    var size: SIMD2<Double> { SIMD2(Double(picture.width), Double(picture.height)) }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var mode: SeparationMarks.Mode { marks.mode }

    var brushDiameter: Double { SeparationMarks.brushDiameter(percent: brushSize, width: picture.width, height: picture.height) }

    /// Finds the picture's objects (once), then separates.
    func start() {
        guard instances == nil, !isFindingObjects, let original else { return }
        isFindingObjects = true
        isComputing = true
        Task.detached(priority: .userInitiated) { [weak self] in
            // Optional: without Vision's objects the separation starts from the strokes alone, as WE's.
            let found = (try? ForegroundPrior.instances(of: original)) ?? []
            await self?.objectsFound(found)
        }
    }

    private func objectsFound(_ found: [ImagePlane]) {
        instances = found
        isFindingObjects = false
        recalculate()
    }

    // MARK: Marks

    /// WE's editing mode buttons (Polygon, Brush).
    func setMode(_ mode: SeparationMarks.Mode) {
        guard marks.mode != mode else { return }
        record()
        marks.mode = mode
        openPolygon = nil
        selectedPoint = nil
        changed()
    }

    private struct Snapshot {
        var marks: [UInt8]
        var polygons: [[SIMD2<Double>]]
        var mode: SeparationMarks.Mode
    }

    private func snapshot() -> Snapshot {
        Snapshot(marks: marks.marks.map(\.rawValue), polygons: marks.polygons, mode: marks.mode)
    }

    private func restore(_ snapshot: Snapshot) {
        marks.marks = snapshot.marks.map { SeparationMarks.Mark(rawValue: $0) ?? .none }
        marks.polygons = snapshot.polygons
        marks.mode = snapshot.mode
        openPolygon = nil
        selectedPoint = nil
        changed()
    }

    /// Keeps the marks for Undo before a change.
    func record() {
        undoStack.append(snapshot())
        if undoStack.count > 30 { undoStack.removeFirst(undoStack.count - 30) }
        redoStack.removeAll()
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        redoStack.append(snapshot())
        restore(last)
    }

    func redo() {
        guard let last = redoStack.popLast() else { return }
        undoStack.append(snapshot())
        restore(last)
    }

    /// Reset Mask: clears the marks.
    func resetMarks() {
        record()
        marks = SeparationMarks(width: picture.width, height: picture.height)
        openPolygon = nil
        selectedPoint = nil
        hasEdits = false
        changed()
    }

    // MARK: Brush

    /// The stroke being painted, shown over the marks until it ends.
    @Published private(set) var stroke: [SIMD2<Double>] = []
    @Published private(set) var strokeErases = false

    func beginStroke(at point: SIMD2<Double>, erasing: Bool) {
        record()
        stroke = [point]
        strokeErases = erasing || brush == .erase
    }

    func continueStroke(to point: SIMD2<Double>, erasing: Bool) {
        guard !stroke.isEmpty else { return }
        stroke.append(point)
    }

    /// Paints the stroke into the marks.
    func endStroke() {
        guard let first = stroke.first else { return }
        let mark = strokeErases ? SeparationMarks.Mark.none : brush.mark
        var last = first
        marks.paint(from: first, to: first, diameter: brushDiameter, mark: mark)
        for point in stroke.dropFirst() {
            marks.paint(from: last, to: point, diameter: brushDiameter, mark: mark)
            last = point
        }
        stroke = []
        hasEdits = true
        changed()
    }

    // MARK: Polygons

    /// A point near `pixel` within `reach` pixels.
    func point(near pixel: SIMD2<Double>, reach: Double) -> PolygonPoint? {
        var best: PolygonPoint?
        var bestDistance = reach * reach
        for (polygonIndex, polygon) in marks.polygons.enumerated() {
            for (pointIndex, point) in polygon.enumerated() {
                let d = point - pixel
                let distance = (d * d).sum()
                if distance <= bestDistance {
                    bestDistance = distance
                    best = PolygonPoint(polygon: polygonIndex, point: pointIndex)
                }
            }
        }
        return best
    }

    /// The side near `pixel` within `reach` pixels: its polygon, the index its new point takes, and
    /// where on the side.
    func side(near pixel: SIMD2<Double>, reach: Double) -> (polygon: Int, insertAt: Int, point: SIMD2<Double>)? {
        var best: (Int, Int, SIMD2<Double>)?
        var bestDistance = reach * reach
        for (polygonIndex, polygon) in marks.polygons.enumerated() where polygon.count > 1 {
            for index in 1..<polygon.count {
                let a = polygon[index - 1], b = polygon[index]
                let ab = b - a
                let lengthSquared = (ab * ab).sum()
                let t = lengthSquared > 0 ? min(max(((pixel - a) * ab).sum() / lengthSquared, 0), 1) : 0
                let on = a + ab * t
                let d = pixel - on
                let distance = (d * d).sum()
                if distance <= bestDistance {
                    bestDistance = distance
                    best = (polygonIndex, index, on)
                }
            }
        }
        return best
    }

    /// A click on the canvas with the polygon tool: closes the outline being drawn on its first
    /// point, inserts a point on a side, selects a point, or adds one (starting an outline).
    func polygonClick(at pixel: SIMD2<Double>, reach: Double) {
        if let open = openPolygon, marks.polygons.indices.contains(open), marks.polygons[open].count > 2,
           let first = marks.polygons[open].first, length(first - pixel) <= reach {
            record()
            marks.polygons[open].append(first)
            openPolygon = nil
            selectedPoint = nil
            hasEdits = true
            changed()
            return
        }
        if let hit = point(near: pixel, reach: reach) {
            selectedPoint = hit
            return
        }
        if openPolygon == nil, let side = side(near: pixel, reach: reach) {
            record()
            marks.polygons[side.polygon].insert(side.point, at: side.insertAt)
            selectedPoint = PolygonPoint(polygon: side.polygon, point: side.insertAt)
            hasEdits = true
            changed()
            return
        }
        record()
        let clamped = SIMD2(min(max(pixel.x, 0), size.x), min(max(pixel.y, 0), size.y))
        if let open = openPolygon, marks.polygons.indices.contains(open) {
            marks.polygons[open].append(clamped)
            selectedPoint = PolygonPoint(polygon: open, point: marks.polygons[open].count - 1)
        } else {
            marks.polygons.append([clamped])
            openPolygon = marks.polygons.count - 1
            selectedPoint = PolygonPoint(polygon: marks.polygons.count - 1, point: 0)
        }
        hasEdits = true
        changed(recalculates: false)
    }

    private var dragStart: [[SIMD2<Double>]]?

    /// Moves the selected point (a closed outline's first and last point together).
    func dragPoint(_ point: PolygonPoint, to pixel: SIMD2<Double>) {
        guard marks.polygons.indices.contains(point.polygon), marks.polygons[point.polygon].indices.contains(point.point) else { return }
        if dragStart == nil {
            dragStart = marks.polygons
            record()
        }
        let clamped = SIMD2(min(max(pixel.x, 0), size.x), min(max(pixel.y, 0), size.y))
        var polygon = marks.polygons[point.polygon]
        let closed = polygon.count > 1 && polygon.first == polygon.last
        polygon[point.point] = clamped
        if closed && point.point == 0 { polygon[polygon.count - 1] = clamped }
        if closed && point.point == polygon.count - 1 { polygon[0] = clamped }
        marks.polygons[point.polygon] = polygon
    }

    func endDrag() {
        guard dragStart != nil else { return }
        dragStart = nil
        hasEdits = true
        changed()
    }

    /// Deletes a point (WE: the middle button on a point; here ⌥-click or Delete); an outline with
    /// fewer than three points left goes.
    func deletePoint(_ point: PolygonPoint) {
        guard marks.polygons.indices.contains(point.polygon) else { return }
        record()
        var polygon = marks.polygons[point.polygon]
        let closed = polygon.count > 1 && polygon.first == polygon.last
        if closed { polygon.removeLast() }
        guard polygon.indices.contains(point.point) else { return }
        polygon.remove(at: point.point)
        if closed && polygon.count > 2 { polygon.append(polygon[0]) }
        if polygon.isEmpty || (closed && polygon.count < 3) {
            marks.polygons.remove(at: point.polygon)
            if openPolygon == point.polygon { openPolygon = nil }
        } else {
            marks.polygons[point.polygon] = polygon
        }
        selectedPoint = nil
        changed()
    }

    private func length(_ v: SIMD2<Double>) -> Double { (v * v).sum().squareRoot() }

    // MARK: Separating

    private func settingsChangeRecalculates(_ old: ForegroundSeparator.Settings) -> Bool {
        var a = old, b = settings
        a.autoRecalculate = true
        b.autoRecalculate = true
        return a != b
    }

    private func changed(recalculates: Bool = true) {
        marksImage = Self.marksImage(marks)
        guard recalculates else { return }
        if settings.autoRecalculate { recalculate() } else { needsRecalculate = true }
    }

    /// Recalculate (R).
    func recalculate() {
        guard !isFindingObjects else { return }
        needsRecalculate = false
        generation += 1
        let current = generation, marks = marks, picture = picture, settings = settings
        let prior = marks.mode == .polygon && !marks.polygons.isEmpty ? nil : marks.prior(from: instances ?? [])
        isComputing = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let mask = ForegroundSeparator.mask(picture, marks: marks, prior: prior, settings: settings)
            let result = mask.map { ForegroundSeparator.separate(picture, mask: $0, settings: settings) }
            let images = (result?.foreground.cgImage, result?.background.cgImage)
            await self?.finish(result, images: images, generation: current)
        }
    }

    private func finish(_ result: ForegroundSeparator.Result?, images: (CGImage?, CGImage?), generation finished: Int) {
        guard finished == generation else { return }
        isComputing = false
        self.result = result
        foregroundImage = images.0
        backgroundImage = images.1
        if result != nil && preview == .original && !hasEdits { preview = .foregroundAndOriginal }
    }

    /// The marks as WE paints them: foreground white, background black, the rest clear.
    static func marksImage(_ marks: SeparationMarks) -> CGImage? {
        guard marks.mode == .brush, marks.hasMarks else { return nil }
        var image = RGBAImage(width: marks.width, height: marks.height)
        for (index, mark) in marks.marks.enumerated() where mark != .none {
            let value: UInt8 = mark == .foreground ? 255 : 0
            image.pixels[index * 4] = value
            image.pixels[index * 4 + 1] = value
            image.pixels[index * 4 + 2] = value
            image.pixels[index * 4 + 3] = 255
        }
        return image.cgImage
    }
}
