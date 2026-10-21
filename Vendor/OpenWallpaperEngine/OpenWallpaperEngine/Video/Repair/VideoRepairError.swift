import Foundation

/// Why a video's sample entry could not be repaired (`VideoSampleEntryRepair`). The original file
/// is played unchanged whenever one of these is thrown.
enum VideoRepairError: Error, CustomStringConvertible {
    case malformed(String)
    case missingBox(String)
    case unsupported(String)
    case noParameterSets(String)

    var description: String {
        switch self {
        case .malformed(let detail): return "malformed file: \(detail)"
        case .missingBox(let path): return "missing box \(path)"
        case .unsupported(let detail): return "unsupported: \(detail)"
        case .noParameterSets(let codec): return "no \(codec) parameter sets in the first sync sample or the decoder configuration"
        }
    }
}
