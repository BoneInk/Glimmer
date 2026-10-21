import simd

/// The scene's wind as WE's physics interface computes it (`wind`, 0x140198910): a force for a
/// point of a rope chain, from 2D simplex noise over the scene time and the point's x across the
/// scene, never against the wind's direction:
///
///     n = max(0, noise(time, 10 · x / projectionWidth))
///     wind = n · windDirection · windStrength
///
/// It is nil (WE returns false and adds nothing) while `windenabled` is off. `x` is the point's
/// world x in scene units, `projectionWidth` the `general.orthogonalprojection` width WE keeps at
/// `general` + 0x354 (0x14018759e), `time` the wallpaper's running time in seconds (the renderer's
/// summed frame deltas, wrapped to 0 past 432000 s, 0x14017fcca…0x14017fcf6). A perspective scene
/// keeps the width 0, so WE divides by zero there and the force isn't a number [?: no library
/// scene with wind is perspective]; the app does the same arithmetic.
enum SceneBonePhysicsWind {
    static func force(_ settings: ScenePhysicsSettings, x: Float, time: Float, projectionWidth: Float) -> SIMD3<Float>? {
        guard settings.windEnabled else { return nil }
        // WE scales the position by 1 / width · 10 in that order (0x140198971…0x140198986).
        let n = max(0, noise(time, x / projectionWidth * 10))
        return settings.windDirection * (n * settings.windStrength)
    }

    /// WE's 2D simplex noise (0x14019896d…0x140198c95): Gustavson's algorithm with Ken Perlin's
    /// permutation as one 256-byte table indexed with byte arithmetic (0x140484f40), the 0x3F
    /// gradient hash and the 45.23065 scale (the form of Sébastien Rombauts' `SimplexNoise`).
    /// Floats throughout, in WE's order of operations.
    static func noise(_ x: Float, _ y: Float) -> Float {
        let f2: Float = 0.36602540, g2: Float = 0.21132487, g2x2: Float = 0.42264974
        let s = (x + y) * f2
        let i = fastFloor(x + s), j = fastFloor(y + s)
        let t = Float(i &+ j) * g2
        let x0 = x - (Float(i) - t), y0 = y - (Float(j) - t)
        let i1: Int32 = x0 > y0 ? 1 : 0, j1: Int32 = 1 - i1
        let x1 = x0 - Float(i1) + g2, y1 = y0 - Float(j1) + g2
        let x2 = x0 - 1 + g2x2, y2 = y0 - 1 + g2x2
        let gi0 = hash(i &+ Int32(hash(j)))
        let gi1 = hash(i &+ i1 &+ Int32(hash(j &+ j1)))
        let gi2 = hash(i &+ 1 &+ Int32(hash(j &+ 1)))
        let n0 = corner(gi0, x0, y0), n1 = corner(gi1, x1, y1), n2 = corner(gi2, x2, y2)
        return (n1 + n0 + n2) * 45.230652
    }

    /// One corner's contribution: (0.5 − x² − y²)⁴ · grad, nothing when that base is negative.
    private static func corner(_ hash: UInt8, _ x: Float, _ y: Float) -> Float {
        var t = 0.5 - x * x - y * y
        guard !(t < 0) else { return 0 }
        t *= t
        return t * t * gradient(hash, x, y)
    }

    private static func gradient(_ hash: UInt8, _ x: Float, _ y: Float) -> Float {
        let h = hash & 0x3F
        let u = h < 4 ? x : y, v = h < 4 ? y : x
        return (h & 1 != 0 ? -u : u) + (h & 2 != 0 ? -2 * v : v + v)
    }

    private static func hash(_ i: Int32) -> UInt8 { permutation[Int(UInt8(truncatingIfNeeded: i))] }

    /// `cvttss2si` and one less (wrapping) when that rounded up (0x1401989c7…0x1401989db), with
    /// x86's integer indefinite (Int32.min) for a value out of range or not a number.
    static func fastFloor(_ value: Float) -> Int32 {
        let truncated = value >= -2_147_483_648 && value < 2_147_483_648 ? Int32(value) : Int32.min
        return Float(truncated) > value ? truncated &- 1 : truncated
    }

    /// Ken Perlin's permutation, as WE stores it (0x140484f40).
    static let permutation: [UInt8] = [
        151, 160, 137, 91, 90, 15, 131, 13, 201, 95, 96, 53, 194, 233, 7, 225, 140, 36, 103, 30, 69, 142, 8, 99, 37,
        240, 21, 10, 23, 190, 6, 148, 247, 120, 234, 75, 0, 26, 197, 62, 94, 252, 219, 203, 117, 35, 11, 32, 57, 177,
        33, 88, 237, 149, 56, 87, 174, 20, 125, 136, 171, 168, 68, 175, 74, 165, 71, 134, 139, 48, 27, 166, 77, 146,
        158, 231, 83, 111, 229, 122, 60, 211, 133, 230, 220, 105, 92, 41, 55, 46, 245, 40, 244, 102, 143, 54, 65, 25,
        63, 161, 1, 216, 80, 73, 209, 76, 132, 187, 208, 89, 18, 169, 200, 196, 135, 130, 116, 188, 159, 86, 164, 100,
        109, 198, 173, 186, 3, 64, 52, 217, 226, 250, 124, 123, 5, 202, 38, 147, 118, 126, 255, 82, 85, 212, 207, 206,
        59, 227, 47, 16, 58, 17, 182, 189, 28, 42, 223, 183, 170, 213, 119, 248, 152, 2, 44, 154, 163, 70, 221, 153,
        101, 155, 167, 43, 172, 9, 129, 22, 39, 253, 19, 98, 108, 110, 79, 113, 224, 232, 178, 185, 112, 104, 218,
        246, 97, 228, 251, 34, 242, 193, 238, 210, 144, 12, 191, 179, 162, 241, 81, 51, 145, 235, 249, 14, 239, 107,
        49, 192, 214, 31, 181, 199, 106, 157, 184, 84, 204, 176, 115, 121, 50, 45, 127, 4, 150, 254, 138, 236, 205,
        93, 222, 114, 67, 29, 24, 72, 243, 141, 128, 195, 78, 66, 215, 61, 156, 180,
    ]
}
