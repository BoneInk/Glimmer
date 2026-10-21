import Foundation

/// `cv::grabCut` with a mask, which WE's Foreground Separation and Character Sheet Creation run on
/// the author's strokes (`performGrabCut` in `wallpaperui.exe`): a Gaussian mixture of five
/// components for each of the foreground's and the background's colours, a graph of the pixels
/// with the colours' likelihoods as terminal capacities and contrast-sensitive links between
/// neighbours (OpenCV's gamma 50, lambda 450, beta from the mean squared contrast), and the min
/// cut, repeated `iterations` times. Pixels marked as sure keep their side.
public enum GrabCut {
    /// A pixel's label (OpenCV's `GC_BGD`, `GC_FGD`, `GC_PR_BGD`, `GC_PR_FGD`).
    public enum Label: UInt8, Sendable {
        case background = 0, foreground = 1, probableBackground = 2, probableForeground = 3

        public var isForeground: Bool { self == .foreground || self == .probableForeground }
    }

    static let gamma: Double = 50
    static let lambda: Double = 9 * 50

    /// Refines `labels` (one per pixel of `rgb`, three bytes a pixel, top row first) in place.
    public static func segment(rgb: [UInt8], width: Int, height: Int, labels: inout [Label], iterations: Int = 3) {
        let count = width * height
        guard count > 0, labels.count == count, rgb.count >= count * 3 else { return }
        let hasForeground = labels.contains { $0.isForeground }
        let hasBackground = labels.contains { !$0.isForeground }
        // Without samples of both there is nothing to tell apart.
        guard hasForeground, hasBackground else { return }
        let colours: [SIMD3<Double>] = (0..<count).map { (index: Int) -> SIMD3<Double> in
            SIMD3(Double(rgb[index * 3]), Double(rgb[index * 3 + 1]), Double(rgb[index * 3 + 2]))
        }
        let links = NeighbourLinks(colours: colours, width: width, height: height)
        var foreground = GaussianMixture.initial(samples: (0..<count).filter { labels[$0].isForeground }.map { colours[$0] })
        var background = GaussianMixture.initial(samples: (0..<count).filter { !labels[$0].isForeground }.map { colours[$0] })
        for _ in 0..<max(iterations, 1) {
            // Assign each pixel its most likely component, then learn the mixtures from that.
            var foregroundSamples: [[SIMD3<Double>]] = Array(repeating: [], count: GaussianMixture.components)
            var backgroundSamples: [[SIMD3<Double>]] = Array(repeating: [], count: GaussianMixture.components)
            for index in 0..<count {
                let colour = colours[index]
                if labels[index].isForeground {
                    foregroundSamples[foreground.likeliestComponent(colour)].append(colour)
                } else {
                    backgroundSamples[background.likeliestComponent(colour)].append(colour)
                }
            }
            foreground = GaussianMixture(learning: foregroundSamples)
            background = GaussianMixture(learning: backgroundSamples)
            var graph = MaxFlowGraph(vertices: count, edgesHint: count * 4)
            for index in 0..<count {
                let source: Double, sink: Double
                switch labels[index] {
                case .probableBackground, .probableForeground:
                    source = -log(max(background.probability(colours[index]), 1e-300))
                    sink = -log(max(foreground.probability(colours[index]), 1e-300))
                case .background:
                    source = 0
                    sink = lambda
                case .foreground:
                    source = lambda
                    sink = 0
                }
                graph.addTerminalWeights(index, source: Float(source), sink: Float(sink))
                links.addEdges(of: index, to: &graph)
            }
            graph.maxFlow()
            for index in 0..<count where labels[index] == .probableBackground || labels[index] == .probableForeground {
                labels[index] = graph.isOnSourceSide(index) ? .probableForeground : .probableBackground
            }
        }
    }

    /// The links between neighbours (left, up-left, up, up-right), `gamma / distance ×
    /// exp(−beta × |Δcolour|²)`, as OpenCV's `calcNWeights`.
    struct NeighbourLinks {
        let width: Int
        let height: Int
        var left: [Float]
        var upLeft: [Float]
        var up: [Float]
        var upRight: [Float]

        init(colours: [SIMD3<Double>], width: Int, height: Int) {
            self.width = width
            self.height = height
            func squared(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { let d = a - b; return (d * d).sum() }
            // beta = 1 / (2 × the mean squared difference), as `calcBeta`.
            var total: Double = 0
            for y in 0..<height {
                for x in 0..<width {
                    let colour = colours[y * width + x]
                    if x > 0 { total += squared(colour, colours[y * width + x - 1]) }
                    if y > 0 && x > 0 { total += squared(colour, colours[(y - 1) * width + x - 1]) }
                    if y > 0 { total += squared(colour, colours[(y - 1) * width + x]) }
                    if y > 0 && x < width - 1 { total += squared(colour, colours[(y - 1) * width + x + 1]) }
                }
            }
            let pairs = Double(4 * width * height - 3 * width - 3 * height + 2)
            let beta = total <= Double.ulpOfOne || pairs <= 0 ? 0 : 1 / (2 * total / pairs)
            let diagonal = GrabCut.gamma / 2.0.squareRoot()
            let count = width * height
            left = [Float](repeating: 0, count: count)
            upLeft = left
            up = left
            upRight = left
            for y in 0..<height {
                for x in 0..<width {
                    let index = y * width + x, colour = colours[index]
                    if x > 0 { left[index] = Float(GrabCut.gamma * exp(-beta * squared(colour, colours[index - 1]))) }
                    if x > 0 && y > 0 { upLeft[index] = Float(diagonal * exp(-beta * squared(colour, colours[index - width - 1]))) }
                    if y > 0 { up[index] = Float(GrabCut.gamma * exp(-beta * squared(colour, colours[index - width]))) }
                    if x < width - 1 && y > 0 {
                        upRight[index] = Float(diagonal * exp(-beta * squared(colour, colours[index - width + 1])))
                    }
                }
            }
        }

        func addEdges(of index: Int, to graph: inout MaxFlowGraph) {
            let x = index % width, y = index / width
            if x > 0 { graph.addEdges(index, index - 1, weight: left[index], reverse: left[index]) }
            if x > 0 && y > 0 { graph.addEdges(index, index - width - 1, weight: upLeft[index], reverse: upLeft[index]) }
            if y > 0 { graph.addEdges(index, index - width, weight: up[index], reverse: up[index]) }
            if x < width - 1 && y > 0 { graph.addEdges(index, index - width + 1, weight: upRight[index], reverse: upRight[index]) }
        }
    }
}

/// OpenCV's GrabCut colour model: five Gaussians with full covariances, their weights the share
/// of samples each holds; a singular covariance gets 0.01 added to its diagonal.
struct GaussianMixture {
    static let components = 5

    struct Component {
        var weight: Double = 0
        var mean = SIMD3<Double>.zero
        var inverse = [Double](repeating: 0, count: 9)
        var determinant: Double = 0
    }

    var parts: [Component]

    /// Seeds the components by k-means (OpenCV: 10 iterations, k-means++ centres).
    static func initial(samples: [SIMD3<Double>]) -> GaussianMixture {
        let labels = KMeans.cluster(samples, k: components, iterations: 10)
        var grouped: [[SIMD3<Double>]] = Array(repeating: [], count: components)
        for (sample, label) in zip(samples, labels) { grouped[label].append(sample) }
        return GaussianMixture(learning: grouped)
    }

    init(learning grouped: [[SIMD3<Double>]]) {
        let total = Double(grouped.reduce(0) { $0 + $1.count })
        parts = grouped.map { (samples: [SIMD3<Double>]) -> Component in
            var component = Component()
            guard !samples.isEmpty, total > 0 else { return component }
            component.weight = Double(samples.count) / total
            let mean = samples.reduce(SIMD3<Double>.zero, +) / Double(samples.count)
            component.mean = mean
            var c = [Double](repeating: 0, count: 9)
            for sample in samples {
                let d = sample - mean
                c[0] += d.x * d.x; c[1] += d.x * d.y; c[2] += d.x * d.z
                c[4] += d.y * d.y; c[5] += d.y * d.z; c[8] += d.z * d.z
            }
            let n = Double(samples.count)
            c[0] /= n; c[1] /= n; c[2] /= n; c[4] /= n; c[5] /= n; c[8] /= n
            c[3] = c[1]; c[6] = c[2]; c[7] = c[5]
            var determinant = Self.determinant(c)
            if determinant <= Double.ulpOfOne {
                c[0] += 0.01; c[4] += 0.01; c[8] += 0.01
                determinant = Self.determinant(c)
            }
            component.determinant = determinant
            component.inverse = [
                (c[4] * c[8] - c[5] * c[7]) / determinant, -(c[1] * c[8] - c[2] * c[7]) / determinant,
                (c[1] * c[5] - c[2] * c[4]) / determinant,
                -(c[3] * c[8] - c[5] * c[6]) / determinant, (c[0] * c[8] - c[2] * c[6]) / determinant,
                -(c[0] * c[5] - c[2] * c[3]) / determinant,
                (c[3] * c[7] - c[4] * c[6]) / determinant, -(c[0] * c[7] - c[1] * c[6]) / determinant,
                (c[0] * c[4] - c[1] * c[3]) / determinant,
            ]
            return component
        }
    }

    static func determinant(_ c: [Double]) -> Double {
        c[0] * (c[4] * c[8] - c[5] * c[7]) - c[1] * (c[3] * c[8] - c[5] * c[6]) + c[2] * (c[3] * c[7] - c[4] * c[6])
    }

    func density(_ component: Component, _ colour: SIMD3<Double>) -> Double {
        guard component.weight > 0, component.determinant > 0 else { return 0 }
        let d = colour - component.mean, m = component.inverse
        let x = d.x * (m[0] * d.x + m[3] * d.y + m[6] * d.z)
        let y = d.y * (m[1] * d.x + m[4] * d.y + m[7] * d.z)
        let z = d.z * (m[2] * d.x + m[5] * d.y + m[8] * d.z)
        return 1 / component.determinant.squareRoot() * exp(-0.5 * (x + y + z))
    }

    func probability(_ colour: SIMD3<Double>) -> Double {
        parts.reduce(0) { $0 + $1.weight * density($1, colour) }
    }

    func likeliestComponent(_ colour: SIMD3<Double>) -> Int {
        var best = 0, bestValue = -1.0
        for (index, part) in parts.enumerated() {
            let value = density(part, colour)
            if value > bestValue { bestValue = value; best = index }
        }
        return best
    }
}

/// k-means with k-means++ seeding from a fixed seed, so a separation is the same every time.
enum KMeans {
    static func cluster(_ samples: [SIMD3<Double>], k: Int, iterations: Int) -> [Int] {
        guard !samples.isEmpty else { return [] }
        var generator = SplitMix64(seed: 0x9E37_79B9_7F4A_7C15)
        func squared(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { let d = a - b; return (d * d).sum() }
        var centres = [samples[Int(generator.next() % UInt64(samples.count))]]
        var nearest = samples.map { squared($0, centres[0]) }
        while centres.count < k {
            let total = nearest.reduce(0, +)
            guard total > 0 else { break }
            var target = Double(generator.next() % 1_000_000) / 1_000_000 * total
            var chosen = samples.count - 1
            for (index, distance) in nearest.enumerated() {
                target -= distance
                if target <= 0 { chosen = index; break }
            }
            centres.append(samples[chosen])
            for index in samples.indices { nearest[index] = min(nearest[index], squared(samples[index], samples[chosen])) }
        }
        var labels = [Int](repeating: 0, count: samples.count)
        for _ in 0..<iterations {
            for (index, sample) in samples.enumerated() {
                var best = 0, bestDistance = Double.infinity
                for (c, centre) in centres.enumerated() {
                    let distance = squared(sample, centre)
                    if distance < bestDistance { bestDistance = distance; best = c }
                }
                labels[index] = best
            }
            var sums = [SIMD3<Double>](repeating: .zero, count: centres.count)
            var counts = [Int](repeating: 0, count: centres.count)
            for (sample, label) in zip(samples, labels) { sums[label] += sample; counts[label] += 1 }
            for c in centres.indices where counts[c] > 0 { centres[c] = sums[c] / Double(counts[c]) }
        }
        return labels
    }
}

/// A small deterministic random generator.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
