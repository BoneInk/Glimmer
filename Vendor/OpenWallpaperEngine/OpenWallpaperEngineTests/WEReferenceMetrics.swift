import Foundation
import simd

/// Which capture pixels are compared: all but the taskbar strip and the item's masks.
struct WEReferenceMask {
    let width: Int
    let height: Int
    var valid: [Bool]

    init(width: Int, height: Int, masks: [WEReferenceConfig.Mask], taskbar: Int) {
        self.width = width
        self.height = height
        valid = [Bool](repeating: true, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let masked = y >= height - taskbar || masks.contains { $0.rect.contains(x: x, y: y) }
                if masked { valid[y * width + x] = false }
            }
        }
    }

    private init(width: Int, height: Int, valid: [Bool]) {
        self.width = width
        self.height = height
        self.valid = valid
    }

    /// Down by `factor`: a pixel is valid when every pixel it covers is.
    func reduced(by factor: Int) -> WEReferenceMask {
        let w = width / factor, h = height / factor
        var result = [Bool](repeating: true, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var all = true
                for dy in 0..<factor where all {
                    for dx in 0..<factor where !valid[(y * factor + dy) * width + x * factor + dx] { all = false }
                }
                result[y * w + x] = all
            }
        }
        return WEReferenceMask(width: w, height: h, valid: result)
    }
}

/// One grid cell of a comparison.
struct WEReferenceCell {
    var column: Int
    var row: Int
    /// x, y, width, height in capture pixels.
    var rect: SIMD4<Int>
    /// The share of the cell compared.
    var coverage: Double
    var we = SIMD3<Double>.zero
    var ours = SIMD3<Double>.zero
    /// Mean absolute difference over R, G and B, 0…255.
    var meanAbs = 0.0
    /// Our mean luma minus WE's.
    var lumaDelta = 0.0
    var ssim = 1.0
    /// Where our edges sit relative to WE's (capture pixels), nil for a cell without edges.
    var edgeShift: SIMD2<Int>?
    /// Normalised correlation of the edge maps unshifted.
    var edgeCorrelation = 1.0

    /// Ranks cells: the colour difference plus a scaled structural one.
    var score: Double { meanAbs + 50 * (1 - ssim) }
}

/// A frame of ours against a WE still: per-cell and whole-frame colour, brightness, SSIM and edge
/// alignment, over the mask.
struct WEReferenceMetrics {
    var meanAbs = 0.0
    var weLuma = 0.0
    var oursLuma = 0.0
    var ssim = 1.0
    /// Edge-map correlation unshifted, and at the whole frame's best shift.
    var edgeCorrelation = 0.0
    var edgeBestCorrelation = 0.0
    var edgeShift = SIMD2<Int>.zero
    var cells: [WEReferenceCell] = []

    static let ssimFactor = 2
    static let edgeFactor = 4
    private static let block = 8

    /// `edges` false skips the edge alignment (most of the cost in a Debug build) for callers that
    /// read only the colour and SSIM.
    static func compare(we: WEReferenceImage, ours: WEReferenceImage, mask: WEReferenceMask,
                        grid: WEReferenceConfig.Grid, taskbar: Int, edges: Bool = true) -> WEReferenceMetrics {
        var result = WEReferenceMetrics()
        let usedHeight = we.height - taskbar
        let cellWidth = we.width / grid.columns
        let cellHeight = usedHeight / grid.rows
        for row in 0..<grid.rows {
            for column in 0..<grid.columns {
                let rect = SIMD4(column * cellWidth, row * cellHeight, cellWidth, cellHeight)
                result.cells.append(colourCell(we: we, ours: ours, mask: mask, rect: rect, column: column, row: row))
            }
        }
        var totals = SIMD3<Double>.zero
        var weights = 0.0
        for cell in result.cells {
            let weight = cell.coverage
            totals += SIMD3(cell.meanAbs, luma(cell.we), luma(cell.ours)) * weight
            weights += weight
        }
        if weights > 0 {
            result.meanAbs = totals.x / weights
            result.weLuma = totals.y / weights
            result.oursLuma = totals.z / weights
        }
        result.addSSIM(we: we, ours: ours, mask: mask, cellSize: SIMD2(cellWidth, cellHeight))
        if edges { result.addEdges(we: we, ours: ours, mask: mask) }
        return result
    }

    static func luma(_ rgb: SIMD3<Double>) -> Double {
        0.2126 * rgb.x + 0.7152 * rgb.y + 0.0722 * rgb.z
    }

    private static func colourCell(we: WEReferenceImage, ours: WEReferenceImage, mask: WEReferenceMask,
                                   rect: SIMD4<Int>, column: Int, row: Int) -> WEReferenceCell {
        var cell = WEReferenceCell(column: column, row: row, rect: rect, coverage: 0)
        var weSum = SIMD3<Double>.zero, oursSum = SIMD3<Double>.zero
        var absolute = 0.0, count = 0
        we.pixels.withUnsafeBufferPointer { a in
            ours.pixels.withUnsafeBufferPointer { b in
                for y in rect.y..<(rect.y + rect.w) {
                    for x in rect.x..<(rect.x + rect.z) where mask.valid[y * we.width + x] {
                        let i = (y * we.width + x) * 4
                        let first = SIMD3(Double(a[i]), Double(a[i + 1]), Double(a[i + 2]))
                        let second = SIMD3(Double(b[i]), Double(b[i + 1]), Double(b[i + 2]))
                        weSum += first
                        oursSum += second
                        let difference = abs(first - second)
                        absolute += (difference.x + difference.y + difference.z) / 3
                        count += 1
                    }
                }
            }
        }
        guard count > 0 else { return cell }
        cell.coverage = Double(count) / Double(rect.z * rect.w)
        cell.we = weSum / Double(count)
        cell.ours = oursSum / Double(count)
        cell.meanAbs = absolute / Double(count)
        cell.lumaDelta = luma(cell.ours) - luma(cell.we)
        return cell
    }

    /// SSIM of 8×8 blocks of the half-size luma; a cell's is its blocks' mean.
    private mutating func addSSIM(we: WEReferenceImage, ours: WEReferenceImage, mask: WEReferenceMask,
                                  cellSize: SIMD2<Int>) {
        let factor = Self.ssimFactor, block = Self.block
        let a = we.luma(reducedBy: factor), b = ours.luma(reducedBy: factor)
        let valid = mask.reduced(by: factor)
        var perCell = [Double](repeating: 0, count: cells.count)
        var perCellCount = [Int](repeating: 0, count: cells.count)
        var total = 0.0, totalCount = 0
        let columns = cells.map(\.column).max().map { $0 + 1 } ?? 1
        for by in 0..<(a.height / block) {
            for bx in 0..<(a.width / block) {
                guard let value = Self.blockSSIM(a, b, valid, x: bx * block, y: by * block, size: block) else { continue }
                let column = bx * block * factor / cellSize.x
                let row = by * block * factor / cellSize.y
                total += value
                totalCount += 1
                guard column < columns, row * columns + column < cells.count else { continue }
                perCell[row * columns + column] += value
                perCellCount[row * columns + column] += 1
            }
        }
        ssim = totalCount > 0 ? total / Double(totalCount) : 1
        for index in cells.indices where perCellCount[index] > 0 {
            cells[index].ssim = perCell[index] / Double(perCellCount[index])
        }
    }

    private static func blockSSIM(_ a: WEReferenceLuma, _ b: WEReferenceLuma, _ mask: WEReferenceMask,
                                  x: Int, y: Int, size: Int) -> Double? {
        var sumA = 0.0, sumB = 0.0, sumAA = 0.0, sumBB = 0.0, sumAB = 0.0
        for row in y..<(y + size) {
            for column in x..<(x + size) {
                let i = row * a.width + column
                guard mask.valid[i] else { return nil }
                let first = Double(a.values[i]), second = Double(b.values[i])
                sumA += first
                sumB += second
                sumAA += first * first
                sumBB += second * second
                sumAB += first * second
            }
        }
        let n = Double(size * size)
        let meanA = sumA / n, meanB = sumB / n
        let varianceA = sumAA / n - meanA * meanA
        let varianceB = sumBB / n - meanB * meanB
        let covariance = sumAB / n - meanA * meanB
        let c1 = 6.5025, c2 = 58.5225  // (0.01·255)², (0.03·255)²
        let numerator = (2 * meanA * meanB + c1) * (2 * covariance + c2)
        let denominator = (meanA * meanA + meanB * meanB + c1) * (varianceA + varianceB + c2)
        return numerator / denominator
    }

    /// Sobel edges of the quarter-size luma: the whole frame's best shift within ±32 px and each
    /// cell's within ±24 px, by normalised correlation.
    private mutating func addEdges(we: WEReferenceImage, ours: WEReferenceImage, mask: WEReferenceMask) {
        let factor = Self.edgeFactor
        let a = we.luma(reducedBy: factor).edges(), b = ours.luma(reducedBy: factor).edges()
        let valid = mask.reduced(by: factor)
        let whole = SIMD4(1, 1, a.width - 2, a.height - 2)
        edgeCorrelation = Self.correlation(a, b, valid, region: whole, shift: .zero)
        let best = Self.bestShift(a, b, valid, region: whole, range: 8)
        edgeShift = best.shift &* factor
        edgeBestCorrelation = best.value
        for index in cells.indices {
            let rect = cells[index].rect / factor
            let region = SIMD4(max(rect.x, 1), max(rect.y, 1), min(rect.z, a.width - 2 - max(rect.x, 1)), rect.w)
            guard Self.meanEdge(a, valid, region: region) > 6 else { continue }
            cells[index].edgeCorrelation = Self.correlation(a, b, valid, region: region, shift: .zero)
            cells[index].edgeShift = Self.bestShift(a, b, valid, region: region, range: 6).shift &* factor
        }
    }

    private static func meanEdge(_ a: WEReferenceLuma, _ mask: WEReferenceMask, region: SIMD4<Int>) -> Double {
        var sum = 0.0, count = 0
        for y in region.y..<(region.y + region.w) {
            for x in region.x..<(region.x + region.z) where mask.valid[y * a.width + x] {
                sum += Double(a.values[y * a.width + x])
                count += 1
            }
        }
        return count > 0 ? sum / Double(count) : 0
    }

    private static func bestShift(_ a: WEReferenceLuma, _ b: WEReferenceLuma, _ mask: WEReferenceMask,
                                  region: SIMD4<Int>, range: Int) -> (shift: SIMD2<Int>, value: Double) {
        var best = (shift: SIMD2<Int>.zero, value: correlation(a, b, mask, region: region, shift: .zero))
        for dy in -range...range {
            for dx in -range...range {
                let value = correlation(a, b, mask, region: region, shift: SIMD2(dx, dy))
                if value > best.value + 1e-9 { best = (SIMD2(dx, dy), value) }
            }
        }
        return best
    }

    /// Σ a(p)·b(p + shift) / √(Σa² Σb²) over the region's valid pixels.
    private static func correlation(_ a: WEReferenceLuma, _ b: WEReferenceLuma, _ mask: WEReferenceMask,
                                    region: SIMD4<Int>, shift: SIMD2<Int>) -> Double {
        var cross: Float = 0, first: Float = 0, second: Float = 0
        a.values.withUnsafeBufferPointer { av in
            b.values.withUnsafeBufferPointer { bv in
                mask.valid.withUnsafeBufferPointer { valid in
                    for y in region.y..<(region.y + region.w) {
                        let sy = y + shift.y
                        guard sy >= 0, sy < b.height else { continue }
                        for x in region.x..<(region.x + region.z) {
                            let sx = x + shift.x
                            guard sx >= 0, sx < b.width, valid[y * a.width + x] else { continue }
                            let p = av[y * a.width + x], q = bv[sy * b.width + sx]
                            cross += p * q
                            first += p * p
                            second += q * q
                        }
                    }
                }
            }
        }
        let norm = (Double(first) * Double(second)).squareRoot()
        return norm > 0 ? Double(cross) / norm : 0
    }

    // MARK: - Pictures and item checks

    /// Half size: WE's luma dimmed, with the absolute difference (×4) in red; masked pixels blue.
    static func differenceImage(we: WEReferenceImage, ours: WEReferenceImage, mask: WEReferenceMask) -> WEReferenceImage {
        let a = we.reduced(by: 2), b = ours.reduced(by: 2)
        let valid = mask.reduced(by: 2)
        var result = WEReferenceImage(width: a.width, height: a.height)
        for i in 0..<(a.width * a.height) {
            let p = i * 4
            let base = UInt8(Double(a.pixels[p]) * 0.07 + Double(a.pixels[p + 1]) * 0.21 + Double(a.pixels[p + 2]) * 0.02)
            guard valid.valid[i] else {
                result.pixels[p] = base
                result.pixels[p + 1] = base
                result.pixels[p + 2] = 120
                continue
            }
            var difference = 0
            for c in 0..<3 { difference += abs(Int(a.pixels[p + c]) - Int(b.pixels[p + c])) }
            result.pixels[p] = UInt8(min(255, Int(base) + difference * 4 / 3))
            result.pixels[p + 1] = base
            result.pixels[p + 2] = base
        }
        return result
    }

    /// Mean luma of `rect` over the mask.
    static func regionLuma(_ image: WEReferenceImage, rect: WEReferenceConfig.Rect, mask: WEReferenceMask) -> Double {
        var sum = 0.0, count = 0
        for y in rect.y..<min(rect.y + rect.height, image.height) {
            for x in rect.x..<min(rect.x + rect.width, image.width) where mask.valid[y * image.width + x] {
                let i = (y * image.width + x) * 4
                sum += luma(SIMD3(Double(image.pixels[i]), Double(image.pixels[i + 1]), Double(image.pixels[i + 2])))
                count += 1
            }
        }
        return count > 0 ? sum / Double(count) : 0
    }

    /// The whole-pixel shift (capture pixels) that best maps `rect` of `a` onto `b`, by the least
    /// mean absolute luma difference: ±200 px horizontally, then ±10 px vertically around it.
    static func shift(from a: WEReferenceImage, to b: WEReferenceImage, rect: WEReferenceConfig.Rect) -> SIMD2<Int> {
        let first = a.luma(reducedBy: 2), second = b.luma(reducedBy: 2)
        let rows = Array(stride(from: rect.y / 2, to: (rect.y + rect.height) / 2, by: 4))
        let columns = Array(stride(from: rect.x / 2, to: (rect.x + rect.width) / 2, by: 2))
        func error(_ shift: SIMD2<Int>) -> Float {
            var total: Float = 0, count: Float = 0
            for row in rows {
                let target = row + shift.y
                guard target >= 0, target < second.height else { continue }
                for column in columns {
                    let x = column + shift.x
                    guard x >= 0, x < second.width else { continue }
                    total += abs(first.values[row * first.width + column] - second.values[target * second.width + x])
                    count += 1
                }
            }
            return count > 0 ? total / count : .infinity
        }
        var best = (shift: SIMD2<Int>.zero, error: error(.zero))
        for dx in -100...100 {
            let value = error(SIMD2(dx, 0))
            if value < best.error { best = (SIMD2(dx, 0), value) }
        }
        let column = best.shift.x
        for dy in -5...5 {
            for dx in (column - 2)...(column + 2) {
                let value = error(SIMD2(dx, dy))
                if value < best.error { best = (SIMD2(dx, dy), value) }
            }
        }
        return best.shift &* 2
    }

    /// What a setting's variant adds over its baseline: the brightening's mean over the compared
    /// frame, its brightness-weighted centroid (capture pixels) and the direction of its long axis
    /// (degrees from +x, clockwise, y down).
    struct Added {
        var mean = 0.0
        var centroid = SIMD2<Double>.zero
        var angle = 0.0
    }

    static func added(_ variant: WEReferenceImage, over baseline: WEReferenceImage, mask: WEReferenceMask) -> Added {
        let factor = 4
        let a = variant.luma(reducedBy: factor), b = baseline.luma(reducedBy: factor)
        let valid = mask.reduced(by: factor)
        var weights = 0.0, first = SIMD2<Double>.zero, count = 0
        var moments = SIMD3<Double>.zero
        for pass in 0..<2 {
            for y in 0..<a.height {
                for x in 0..<a.width where valid.valid[y * a.width + x] {
                    let value = max(0, Double(a.values[y * a.width + x] - b.values[y * a.width + x]))
                    let point = SIMD2(Double(x) + 0.5, Double(y) + 0.5) * Double(factor)
                    if pass == 0 {
                        weights += value
                        first += value * point
                        count += 1
                    } else if weights > 0 {
                        let d = point - first / weights
                        moments += value * SIMD3(d.x * d.x, d.y * d.y, d.x * d.y)
                    }
                }
            }
        }
        guard weights > 0, count > 0 else { return Added() }
        let angle = 0.5 * atan2(2 * moments.z, moments.x - moments.y) * 180 / .pi
        return Added(mean: weights / Double(count), centroid: first / weights, angle: angle)
    }
}
