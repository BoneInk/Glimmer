import Foundation

/// What the app and its shader compile helper (`ShaderCompileHelperServer`) send each other: one
/// request per compiler step, one response to it, each a length-prefixed JSON frame
/// (`ShaderCompileHelperFrame`).
///
/// The source already holds the variant's combos as `#define`s (`ShaderPrelude`), so source and
/// stage are the whole input.
enum ShaderCompileHelperMessage {
    enum Operation: String, Codable {
        case preprocess
        case compilePairToMSL
    }

    struct Request: Codable, Equatable {
        var id: UInt64
        var operation: Operation
        var stage: ShaderStage
        /// `compilePairToMSL`: the vertex stage.
        var source: String
        /// `compilePairToMSL`: the fragment stage.
        var fragmentSource: String? = nil
    }

    struct Failure: Codable, Equatable {
        var step: String
        var output: String
        /// The shader is quarantined (`ShaderCompilerError.quarantined`).
        var quarantined: Bool
    }

    struct Response: Codable, Equatable {
        var id: UInt64
        /// `preprocess`: the preprocessed GLSL; `compilePairToMSL`: the vertex stage's MSL.
        var text: String?
        /// `compilePairToMSL`: the vertex stage's SPIRV-Cross reflection JSON.
        var reflection: Data?
        /// `compilePairToMSL`: the fragment stage's MSL and reflection (the vertex stage's are
        /// `text` and `reflection`).
        var fragmentText: String? = nil
        var fragmentReflection: Data? = nil
        var failure: Failure?
        /// Time the helper spent in the compiler, for the round-trip overhead
        /// (`HelperShaderCompiler.Statistics`).
        var computeNanoseconds: UInt64
        /// The helper's compile thread is stuck (a hang overran its watchdog); it exits after this
        /// response and the next request starts a new one.
        var exiting: Bool
    }
}

extension ShaderStage: Codable {}

/// A frame: a 4-byte big-endian length, then that many bytes of JSON.
enum ShaderCompileHelperFrame {
    /// Larger frames are a corrupt stream, not a shader (the largest WE shaders are ~200 KB).
    static let maximumLength = 64 << 20

    enum Error: Swift.Error, CustomStringConvertible {
        case tooLarge(Int)
        var description: String {
            switch self {
            case .tooLarge(let length): return "frame of \(length) bytes"
            }
        }
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let payload = try JSONEncoder().encode(value)
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(payload)
        return frame
    }

    /// Takes one whole frame's payload off the front of `buffer`, or nil while it is incomplete.
    static func take(from buffer: inout Data) throws -> Data? {
        guard buffer.count >= 4 else { return nil }
        let start = buffer.startIndex
        let length = buffer[start..<start + 4].reduce(0) { $0 << 8 | Int($1) }
        guard length <= maximumLength else { throw Error.tooLarge(length) }
        guard buffer.count >= 4 + length else { return nil }
        let payload = Data(buffer[start + 4..<start + 4 + length])
        buffer = Data(buffer[(start + 4 + length)...])
        return payload
    }
}
