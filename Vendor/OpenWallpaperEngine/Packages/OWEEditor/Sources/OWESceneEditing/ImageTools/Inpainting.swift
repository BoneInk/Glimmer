import Foundation

/// `cv::inpaint(…, INPAINT_TELEA)`: the pixels of a mask filled from the known ones around them,
/// nearest first (a fast-marching front), each a weighted mean of the known pixels within
/// `radius` (weighted by closeness, by facing the front and by having been reached at the same
/// time). WE fills what a cut-out leaves (the background behind a separated character, the
/// transparent part of a picture whose details make a normal map) this way. Telea's gradient
/// term is left out, so a fill is the smooth "blurred colour" WE's docs describe.
public enum Inpainting {
    /// Fills the pixels of `planes` (one or more channels, the same size) where `unknown` holds.
    /// `limit`: pixels further than this from the known ones get the fill's mean instead (for a
    /// fill only the pixels near the known area matter in).
    public static func telea(_ planes: [ImagePlane], unknown: [Bool], radius: Int, limit: Float = .infinity) -> [ImagePlane] {
        guard let first = planes.first, !first.isEmpty else { return planes }
        let width = first.width, height = first.height, count = width * height
        precondition(unknown.count == count, "the mask is the planes' size")
        var result = planes
        // Arrival time of the front (distance from the known pixels), known pixels 0.
        var time = [Float](repeating: .infinity, count: count)
        var state = [UInt8](repeating: 2, count: count) // 0 known, 1 in the band, 2 unknown
        var heap = MinHeap()
        for index in 0..<count where !unknown[index] {
            state[index] = 0
            time[index] = 0
        }
        let neighbours4 = [(1, 0), (-1, 0), (0, 1), (0, -1)]
        // The band: unknown pixels next to a known one.
        for index in 0..<count where state[index] == 2 {
            let x = index % width, y = index / width
            for (dx, dy) in neighbours4 {
                let nx = x + dx, ny = y + dy
                if nx >= 0, ny >= 0, nx < width, ny < height, state[ny * width + nx] == 0 {
                    state[index] = 1
                    time[index] = 1
                    heap.push(1, index)
                    break
                }
            }
        }
        let reach = max(radius, 1)
        var filledSums = [Double](repeating: 0, count: result.count)
        var filledCount = 0
        while let (arrival, index) = heap.pop() {
            guard state[index] == 1 else { continue }
            // The heap gives the front in arrival order: everything left is further than `limit`.
            if arrival > limit { break }
            state[index] = 0
            let x = index % width, y = index / width
            fill(&result, at: x, y, width: width, height: height, radius: reach, time: time, state: state)
            for channel in result.indices { filledSums[channel] += Double(result[channel].pixels[index]) }
            filledCount += 1
            for (dx, dy) in neighbours4 {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                let neighbour = ny * width + nx
                guard state[neighbour] != 0 else { continue }
                let next = solve(nx, ny, width: width, height: height, time: time, state: state)
                if next < time[neighbour] {
                    time[neighbour] = next
                    state[neighbour] = 1
                    heap.push(next, neighbour)
                }
            }
        }
        // Beyond the limit: the mean of the fill, which nothing reads closely.
        if filledCount > 0 {
            for index in 0..<count where state[index] != 0 {
                for channel in result.indices { result[channel].pixels[index] = Float(filledSums[channel] / Double(filledCount)) }
            }
        }
        return result
    }

    /// The eikonal update of a pixel from its known neighbours (first-order, as Telea's).
    private static func solve(_ x: Int, _ y: Int, width: Int, height: Int, time: [Float], state: [UInt8]) -> Float {
        func known(_ nx: Int, _ ny: Int) -> Float {
            guard nx >= 0, ny >= 0, nx < width, ny < height, state[ny * width + nx] == 0 else { return .infinity }
            return time[ny * width + nx]
        }
        let a = min(known(x - 1, y), known(x + 1, y)), b = min(known(x, y - 1), known(x, y + 1))
        if a.isInfinite && b.isInfinite { return .infinity }
        if abs(a - b) >= 1 || a.isInfinite || b.isInfinite { return min(a, b) + 1 }
        return (a + b + (2 - (a - b) * (a - b)).squareRoot()) / 2
    }

    private static func fill(_ planes: inout [ImagePlane], at x: Int, _ y: Int, width: Int, height: Int, radius: Int,
                             time: [Float], state: [UInt8]) {
        let index = y * width + x
        // The front's normal: the gradient of the arrival time.
        func t(_ nx: Int, _ ny: Int) -> Float? {
            guard nx >= 0, ny >= 0, nx < width, ny < height, time[ny * width + nx].isFinite else { return nil }
            return time[ny * width + nx]
        }
        let gx = ((t(x + 1, y) ?? time[index]) - (t(x - 1, y) ?? time[index])) / 2
        let gy = ((t(x, y + 1) ?? time[index]) - (t(x, y - 1) ?? time[index])) / 2
        var sums = [Float](repeating: 0, count: planes.count)
        var total: Float = 0
        for ny in max(y - radius, 0)...min(y + radius, height - 1) {
            for nx in max(x - radius, 0)...min(x + radius, width - 1) {
                let neighbour = ny * width + nx
                guard neighbour != index, state[neighbour] == 0 else { continue }
                let rx = Float(x - nx), ry = Float(y - ny)
                let lengthSquared = rx * rx + ry * ry
                guard lengthSquared <= Float(radius * radius) + 0.5 else { continue }
                let length = lengthSquared.squareRoot()
                let direction = max(abs(rx * gx + ry * gy) / length, 1e-6)
                let level = 1 / (1 + abs(time[neighbour] - time[index]))
                let weight = direction * level / lengthSquared
                for channel in planes.indices { sums[channel] += planes[channel].pixels[neighbour] * weight }
                total += weight
            }
        }
        guard total > 0 else { return }
        for channel in planes.indices { planes[channel].pixels[index] = sums[channel] / total }
    }

    /// A binary min-heap of (key, index).
    private struct MinHeap {
        private var keys: [Float] = []
        private var values: [Int] = []

        mutating func push(_ key: Float, _ value: Int) {
            keys.append(key)
            values.append(value)
            var child = keys.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard keys[child] < keys[parent] else { break }
                keys.swapAt(child, parent)
                values.swapAt(child, parent)
                child = parent
            }
        }

        mutating func pop() -> (Float, Int)? {
            guard let topKey = keys.first, let topValue = values.first else { return nil }
            let lastKey = keys.removeLast(), lastValue = values.removeLast()
            if !keys.isEmpty {
                keys[0] = lastKey
                values[0] = lastValue
                var parent = 0
                while true {
                    let left = 2 * parent + 1, right = left + 1
                    var smallest = parent
                    if left < keys.count && keys[left] < keys[smallest] { smallest = left }
                    if right < keys.count && keys[right] < keys[smallest] { smallest = right }
                    guard smallest != parent else { break }
                    keys.swapAt(parent, smallest)
                    values.swapAt(parent, smallest)
                    parent = smallest
                }
            }
            return (topKey, topValue)
        }
    }
}
