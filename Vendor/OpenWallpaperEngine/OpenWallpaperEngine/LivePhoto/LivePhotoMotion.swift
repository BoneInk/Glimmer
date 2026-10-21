import CoreGraphics
import Foundation

/// The clip with the most motion. iOS plays a Live Photo wallpaper for a moment on wake, so the
/// export picks the 1–3 s of the scene that move the most: the helper renders the scene's first
/// `analysisSeconds` small (`LivePhotoRenderer`), each frame's motion is its difference from the
/// frame before (`ScreenSaverFrameSignature.difference`, the screen saver's seam metric), and the
/// window whose frames move the most wins. Of the windows within `nearBest` of the most, the one
/// whose edges move least is taken, so the clip doesn't start or end in the middle of a burst.
enum LivePhotoMotion {
    /// How much of the scene is measured.
    static let analysisSeconds = 8.0
    /// The analysis renders the crop at about this many pixels on its longer side.
    static let analysisPixels = 256
    /// Windows within this share of the most motion count as equally good.
    static let nearBest = 0.9

    /// What the helper writes: each frame's difference from the one before (0 for the first).
    struct Analysis: Codable, Equatable {
        var frameRate: Int
        var differences: [Double]

        var seconds: Double { Double(differences.count) / Double(max(frameRate, 1)) }
    }

    /// The first frame of the best `length`-frame window of `differences` (the window's motion is
    /// the differences between its frames). 0 when the series is shorter than the window.
    static func bestWindowStart(differences: [Double], length: Int) -> Int {
        let count = differences.count
        guard length > 1, count > length else { return 0 }
        // motion(s) = differences[s + 1] + … + differences[s + length - 1]
        var sums: [Double] = []
        sums.reserveCapacity(count - length + 1)
        var running: Double = differences[1..<length].reduce(0, +)
        sums.append(running)
        for start in 1...(count - length) {
            running += differences[start + length - 1] - differences[start]
            sums.append(running)
        }
        guard let most = sums.max(), most > 0 else { return 0 }
        var best = 0
        var bestEdges = Double.infinity
        for (start, sum) in sums.enumerated() where sum >= most * nearBest {
            let edges = edgeMotion(differences: differences, start: start, length: length)
            if edges < bestEdges - 1e-12 {
                best = start
                bestEdges = edges
            }
        }
        return best
    }

    /// The motion across a window's edges: into its first frame and out of its last.
    static func edgeMotion(differences: [Double], start: Int, length: Int) -> Double {
        let into = differences.indices.contains(start) ? differences[start] : 0
        let out = differences.indices.contains(start + length) ? differences[start + length] : 0
        return into + out
    }

    /// The best clip start in seconds for a clip of `length` seconds.
    static func bestStart(in analysis: Analysis, length: Double) -> Double {
        let frames = max(1, Int((length * Double(analysis.frameRate)).rounded()))
        return Double(bestWindowStart(differences: analysis.differences, length: frames)) / Double(max(analysis.frameRate, 1))
    }

    /// Each frame's difference from the frame before, over `signatures` in order.
    static func differences(_ signatures: [ScreenSaverFrameSignature]) -> [Double] {
        guard !signatures.isEmpty else { return [] }
        return [0] + zip(signatures.dropFirst(), signatures).map { $0.difference($1) }
    }
}
