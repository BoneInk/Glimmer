import Foundation

/// Why a `.mdl` didn't load. WE's reader never fails on a short file (it reads zeros) and
/// fast-fails the process on a few impossible counts; ours rejects both, for that model only
/// (docs/models-plan.md §1.1).
public enum MDLError: Error, Equatable, CustomStringConvertible {
    /// A read past the end of the file: a truncated download or a misread count.
    case truncated(reading: String, offset: Int)
    /// The file doesn't start with an `MDLVnnnn` tag.
    case notAModel(tag: String)
    /// More than 128 bones: WE fast-fails (`int 0x29` at 0x140262501).
    case tooManyBones(Int)
    /// A size, index or offset WE's reader checks (or its data implies) is wrong.
    case malformed(String)
    /// The model file isn't in the package or the folder.
    case missing(path: String)

    public var description: String {
        switch self {
        case .truncated(let what, let offset): return "truncated: reading \(what) at 0x\(String(offset, radix: 16))"
        case .notAModel(let tag): return "not an MDLV model (tag \(tag.debugDescription))"
        case .tooManyBones(let count): return "\(count) bones, WE's limit is 128"
        case .malformed(let reason): return "malformed: \(reason)"
        case .missing(let path): return "no model file \(path)"
        }
    }
}
