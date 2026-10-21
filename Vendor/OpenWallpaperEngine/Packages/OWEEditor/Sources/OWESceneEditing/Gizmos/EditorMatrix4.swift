import Foundation

/// A 4 × 4 matrix in the column-vector convention (`m · p`), column-major, as the renderer's
/// `simd_float4x4` keeps WE's matrices: column i is WE's row i. Foundation only, for the editor's
/// 3D gizmo math.
public struct EditorMatrix4: Hashable, Sendable {
    /// Column-major: element (row r, column c) at `c * 4 + r`.
    public var elements: [Double]

    public init(elements: [Double]) {
        precondition(elements.count == 16, "a 4 × 4 matrix has 16 elements")
        self.elements = elements
    }

    /// From four columns.
    public init(columns: (SIMD4<Double>, SIMD4<Double>, SIMD4<Double>, SIMD4<Double>)) {
        let list = [columns.0, columns.1, columns.2, columns.3]
        elements = list.flatMap { [$0.x, $0.y, $0.z, $0.w] }
    }

    public static let identity = EditorMatrix4(elements: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1])

    public subscript(row: Int, column: Int) -> Double {
        get { elements[column * 4 + row] }
        set { elements[column * 4 + row] = newValue }
    }

    public func column(_ index: Int) -> SIMD4<Double> {
        SIMD4(elements[index * 4], elements[index * 4 + 1], elements[index * 4 + 2], elements[index * 4 + 3])
    }

    public static func * (lhs: EditorMatrix4, rhs: EditorMatrix4) -> EditorMatrix4 {
        var result = [Double](repeating: 0, count: 16)
        for column in 0..<4 {
            for row in 0..<4 {
                var sum: Double = 0
                for k in 0..<4 { sum += lhs[row, k] * rhs[k, column] }
                result[column * 4 + row] = sum
            }
        }
        return EditorMatrix4(elements: result)
    }

    public func apply(_ vector: SIMD4<Double>) -> SIMD4<Double> {
        var result = SIMD4<Double>.zero
        for row in 0..<4 {
            result[row] = self[row, 0] * vector.x + self[row, 1] * vector.y + self[row, 2] * vector.z + self[row, 3] * vector.w
        }
        return result
    }

    /// A point (w = 1), divided by its w.
    public func applyPoint(_ point: SIMD3<Double>) -> SIMD3<Double> {
        let result = apply(SIMD4(point.x, point.y, point.z, 1))
        let w = abs(result.w) > 1e-12 ? result.w : 1
        return SIMD3(result.x, result.y, result.z) / w
    }

    /// A direction (w = 0): the linear part only.
    public func applyVector(_ vector: SIMD3<Double>) -> SIMD3<Double> {
        let result = apply(SIMD4(vector.x, vector.y, vector.z, 0))
        return SIMD3(result.x, result.y, result.z)
    }

    /// The translation (column 3).
    public var translation: SIMD3<Double> {
        let column = column(3)
        return SIMD3(column.x, column.y, column.z)
    }

    /// Column `index` of the linear part: where local axis `index` points.
    public func axis(_ index: Int) -> SIMD3<Double> {
        let column = column(index)
        return SIMD3(column.x, column.y, column.z)
    }

    /// The inverse; nil for a matrix that flattens space.
    public var inverted: EditorMatrix4? {
        let m = elements
        var inv = [Double](repeating: 0, count: 16)
        inv[0] = m[5] * m[10] * m[15] - m[5] * m[11] * m[14] - m[9] * m[6] * m[15] + m[9] * m[7] * m[14] + m[13] * m[6] * m[11] - m[13] * m[7] * m[10]
        inv[4] = -m[4] * m[10] * m[15] + m[4] * m[11] * m[14] + m[8] * m[6] * m[15] - m[8] * m[7] * m[14] - m[12] * m[6] * m[11] + m[12] * m[7] * m[10]
        inv[8] = m[4] * m[9] * m[15] - m[4] * m[11] * m[13] - m[8] * m[5] * m[15] + m[8] * m[7] * m[13] + m[12] * m[5] * m[11] - m[12] * m[7] * m[9]
        inv[12] = -m[4] * m[9] * m[14] + m[4] * m[10] * m[13] + m[8] * m[5] * m[14] - m[8] * m[6] * m[13] - m[12] * m[5] * m[10] + m[12] * m[6] * m[9]
        inv[1] = -m[1] * m[10] * m[15] + m[1] * m[11] * m[14] + m[9] * m[2] * m[15] - m[9] * m[3] * m[14] - m[13] * m[2] * m[11] + m[13] * m[3] * m[10]
        inv[5] = m[0] * m[10] * m[15] - m[0] * m[11] * m[14] - m[8] * m[2] * m[15] + m[8] * m[3] * m[14] + m[12] * m[2] * m[11] - m[12] * m[3] * m[10]
        inv[9] = -m[0] * m[9] * m[15] + m[0] * m[11] * m[13] + m[8] * m[1] * m[15] - m[8] * m[3] * m[13] - m[12] * m[1] * m[11] + m[12] * m[3] * m[9]
        inv[13] = m[0] * m[9] * m[14] - m[0] * m[10] * m[13] - m[8] * m[1] * m[14] + m[8] * m[2] * m[13] + m[12] * m[1] * m[10] - m[12] * m[2] * m[9]
        inv[2] = m[1] * m[6] * m[15] - m[1] * m[7] * m[14] - m[5] * m[2] * m[15] + m[5] * m[3] * m[14] + m[13] * m[2] * m[7] - m[13] * m[3] * m[6]
        inv[6] = -m[0] * m[6] * m[15] + m[0] * m[7] * m[14] + m[4] * m[2] * m[15] - m[4] * m[3] * m[14] - m[12] * m[2] * m[7] + m[12] * m[3] * m[6]
        inv[10] = m[0] * m[5] * m[15] - m[0] * m[7] * m[13] - m[4] * m[1] * m[15] + m[4] * m[3] * m[13] + m[12] * m[1] * m[7] - m[12] * m[3] * m[5]
        inv[14] = -m[0] * m[5] * m[14] + m[0] * m[6] * m[13] + m[4] * m[1] * m[14] - m[4] * m[2] * m[13] - m[12] * m[1] * m[6] + m[12] * m[2] * m[5]
        inv[3] = -m[1] * m[6] * m[11] + m[1] * m[7] * m[10] + m[5] * m[2] * m[11] - m[5] * m[3] * m[10] - m[9] * m[2] * m[7] + m[9] * m[3] * m[6]
        inv[7] = m[0] * m[6] * m[11] - m[0] * m[7] * m[10] - m[4] * m[2] * m[11] + m[4] * m[3] * m[10] + m[8] * m[2] * m[7] - m[8] * m[3] * m[6]
        inv[11] = -m[0] * m[5] * m[11] + m[0] * m[7] * m[9] + m[4] * m[1] * m[11] - m[4] * m[3] * m[9] - m[8] * m[1] * m[7] + m[8] * m[3] * m[5]
        inv[15] = m[0] * m[5] * m[10] - m[0] * m[6] * m[9] - m[4] * m[1] * m[10] + m[4] * m[2] * m[9] + m[8] * m[1] * m[6] - m[8] * m[2] * m[5]
        let determinant: Double = m[0] * inv[0] + m[1] * inv[4] + m[2] * inv[8] + m[3] * inv[12]
        guard abs(determinant) > 1e-12 else { return nil }
        return EditorMatrix4(elements: inv.map { $0 / determinant })
    }

    // MARK: WE's object matrices

    /// WE's rotation of `angles` (radians, `R = Rz·Ry·Rx`, wallpaper64.exe 0x1401dd630) as the
    /// three directions its local axes point in their parent's space (WE's basis rows), as the
    /// renderer's `SceneWorldMatrix.rows` builds them.
    public static func rotationRows(_ angles: SIMD3<Double>) -> (SIMD3<Double>, SIMD3<Double>, SIMD3<Double>) {
        let cx = cos(angles.x), sx = sin(angles.x)
        let cy = cos(angles.y), sy = sin(angles.y)
        let cz = cos(angles.z), sz = sin(angles.z)
        return (SIMD3(cy * cz, cy * sz, -sy),
                SIMD3(sx * sy * cz - cx * sz, sx * sy * sz + cx * cz, sx * cy),
                SIMD3(cx * sy * cz + sx * sz, cx * sy * sz - sx * cz, cx * cy))
    }

    /// The angles whose rotation rows are `row0`…`row2`, as WE extracts them (0x1401f31f7):
    /// the inverse of `rotationRows` for |y| < π/2.
    public static func angles(row0: SIMD3<Double>, row1: SIMD3<Double>, row2: SIMD3<Double>) -> SIMD3<Double> {
        let z = atan2(row0.y, row0.x)
        let y = atan2(-row0.z, (row1.z * row1.z + row2.z * row2.z).squareRoot())
        let sz = sin(z), cz = cos(z)
        let x = atan2(row2.x * sz - row2.y * cz, row1.y * cz - row1.x * sz)
        return SIMD3(x, y, z)
    }

    /// An object's local matrix (0x1401850a0): its rotation rows scaled per axis, then its origin.
    public static func local(_ transform: LayerTransform) -> EditorMatrix4 {
        let (row0, row1, row2) = rotationRows(transform.angles)
        let x = row0 * transform.scale.x, y = row1 * transform.scale.y, z = row2 * transform.scale.z
        return EditorMatrix4(columns: (SIMD4(x.x, x.y, x.z, 0), SIMD4(y.x, y.y, y.z, 0), SIMD4(z.x, z.y, z.z, 0),
                                       SIMD4(transform.origin.x, transform.origin.y, transform.origin.z, 1)))
    }

    /// A rotation by `angle` radians about the unit `axis` (right-handed).
    public static func rotation(about axis: SIMD3<Double>, angle: Double) -> EditorMatrix4 {
        let length = (axis * axis).sum().squareRoot()
        let unit = length > 1e-12 ? axis / length : SIMD3(0, 0, 1)
        let c = cos(angle), s = sin(angle), t = 1 - c
        let (x, y, z) = (unit.x, unit.y, unit.z)
        return EditorMatrix4(columns: (SIMD4(t * x * x + c, t * x * y + s * z, t * x * z - s * y, 0),
                                       SIMD4(t * x * y - s * z, t * y * y + c, t * y * z + s * x, 0),
                                       SIMD4(t * x * z + s * y, t * y * z - s * x, t * z * z + c, 0),
                                       SIMD4(0, 0, 0, 1)))
    }

    /// The linear part with each column made unit length: the rotation of a transform without
    /// its scale.
    public var rotationOnly: EditorMatrix4 {
        func unit(_ vector: SIMD3<Double>) -> SIMD3<Double> {
            let length = (vector * vector).sum().squareRoot()
            return length > 1e-12 ? vector / length : vector
        }
        let x = unit(axis(0)), y = unit(axis(1)), z = unit(axis(2))
        return EditorMatrix4(columns: (SIMD4(x.x, x.y, x.z, 0), SIMD4(y.x, y.y, y.z, 0), SIMD4(z.x, z.y, z.z, 0),
                                       SIMD4(0, 0, 0, 1)))
    }
}
