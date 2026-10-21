import Metal
import simd

/// Writes values into a std140 `WEUniforms` block as SPIRV-Cross laid it out.
enum UniformWriter {
    static func write(_ components: [Float], member: UniformMember, into bytes: inout [UInt8]) {
        let isInteger = member.type.hasPrefix("int") || member.type.hasPrefix("ivec")
            || member.type.hasPrefix("uint") || member.type.hasPrefix("uvec") || member.type == "bool"
        let perElement = componentsPerElement(member.type)
        let columns = matrixColumns(member.type)
        // One store per component into the buffer's memory: the shadow pass writes each caster's
        // view matrices through here, and per-byte copies made it most of a model scene's frame.
        let rows = columns.flatMap { member.matrixStride > 0 ? perElement / $0 : nil }
        let count = min(member.count * perElement, components.count)
        if !isInteger, member.offset >= 0 {
            copyRuns(components, count: count, member: member, perElement: perElement, run: rows ?? perElement,
                     into: &bytes)
            return
        }
        components.withUnsafeBufferPointer { values in
            bytes.withUnsafeMutableBytes { raw in
                var index = 0
                while index < count {
                    let element = index / perElement, component = index % perElement
                    let base = member.offset + element * member.arrayStride
                    let offset = rows.map { base + (component / $0) * member.matrixStride + (component % $0) * 4 }
                        ?? base + component * 4
                    if offset >= 0, offset + 4 <= raw.count {
                        let value = values[index]
                        raw.storeBytes(of: isInteger ? integerBits(value) : value.bitPattern, toByteOffset: offset, as: UInt32.self)
                    }
                    index += 1
                }
            }
        }
    }

    /// Floats as they stand, one copy per contiguous run: an element's components, or a matrix
    /// column's `run` rows (the model shaders' bones and view matrices are hundreds of floats a
    /// draw). The same bytes as a store per component, a run cut where the buffer ends.
    private static func copyRuns(_ components: [Float], count: Int, member: UniformMember, perElement: Int, run: Int,
                                 into bytes: inout [UInt8]) {
        components.withUnsafeBufferPointer { values in
            bytes.withUnsafeMutableBytes { raw in
                guard let source = values.baseAddress, let target = raw.baseAddress else { return }
                var index = 0
                while index < count {
                    let element = index / perElement, component = index % perElement
                    let offset = member.offset + element * member.arrayStride + (component / run) * member.matrixStride
                    let length = min(run, count - index)
                    let fits = min(length, max(0, (raw.count - offset) / 4))
                    if fits > 0 { (target + offset).copyMemory(from: source + index, byteCount: fits * 4) }
                    index += length
                }
            }
        }
    }

    /// Rounds to the nearest Int32, clamping out-of-range values; NaN becomes 0.
    static func integerBits(_ value: Float) -> UInt32 {
        guard !value.isNaN else { return 0 }
        let rounded = value.rounded()
        // Float(Int32.max) rounds up to 2^31, so compare against that, not the Int32.
        if rounded >= 2_147_483_648 { return UInt32(bitPattern: Int32.max) }
        if rounded <= -2_147_483_648 { return UInt32(bitPattern: Int32.min) }
        return UInt32(bitPattern: Int32(rounded))
    }

    static func componentsPerElement(_ type: String) -> Int {
        switch type {
        case "vec2", "ivec2", "uvec2": return 2
        case "vec3", "ivec3", "uvec3": return 3
        case "vec4", "ivec4", "uvec4": return 4
        case "mat2": return 4
        case "mat3": return 9
        case "mat4": return 16
        case "mat4x3": return 12
        case "mat3x4": return 12
        default: return 1
        }
    }

    static func matrixColumns(_ type: String) -> Int? {
        switch type {
        case "mat2": return 2
        case "mat3", "mat3x4": return 3
        case "mat4", "mat4x3": return 4
        default: return nil
        }
    }
}
