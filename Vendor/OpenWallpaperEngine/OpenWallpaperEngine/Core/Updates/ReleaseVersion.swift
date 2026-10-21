import Foundation

/// A release version as the tags spell it: `X.Y.Z` or `X.Y.Z-(alpha|beta|rc).N`.
/// `Scripts/release-version.sh` applies the same rules to tags in the release workflow.
struct ReleaseVersion: Comparable, CustomStringConvertible {
    enum Stage: String, Comparable {
        case alpha, beta, rc

        private var order: Int { self == .alpha ? 0 : self == .beta ? 1 : 2 }
        static func < (lhs: Stage, rhs: Stage) -> Bool { lhs.order < rhs.order }
    }

    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: (stage: Stage, number: Int)?

    init?(_ text: String) {
        let trimmed: Substring = text.hasPrefix("v") ? text.dropFirst() : Substring(text)
        let parts: [Substring] = trimmed.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers: [Int] = parts[0].split(separator: ".", omittingEmptySubsequences: false).compactMap(Self.number)
        guard numbers.count == 3, parts[0].split(separator: ".", omittingEmptySubsequences: false).count == 3 else {
            return nil
        }
        (major, minor, patch) = (numbers[0], numbers[1], numbers[2])
        if parts.count == 2 {
            let suffix: [Substring] = parts[1].split(separator: ".", omittingEmptySubsequences: false)
            guard suffix.count == 2, let stage = Stage(rawValue: String(suffix[0])),
                  let number = Self.number(suffix[1]) else { return nil }
            prerelease = (stage, number)
        } else {
            prerelease = nil
        }
    }

    /// A number without leading zeros, as SemVer spells them.
    private static func number(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }),
              text.count == 1 || text.first != "0" else { return nil }
        return Int(text)
    }

    /// `X.Y.Z`, the bundle's `CFBundleShortVersionString`.
    var marketingVersion: String { "\(major).\(minor).\(patch)" }

    /// `X.Y.Z` or `X.Y.Z-stage.N`, without the tag's `v`.
    var description: String {
        guard let prerelease else { return marketingVersion }
        return "\(marketingVersion)-\(prerelease.stage.rawValue).\(prerelease.number)"
    }

    /// SemVer precedence: a pre-release comes before its final release, alpha < beta < rc.
    static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        let left: [Int] = [lhs.major, lhs.minor, lhs.patch]
        let right: [Int] = [rhs.major, rhs.minor, rhs.patch]
        if left != right { return left.lexicographicallyPrecedes(right) }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, _): return false
        case (_, nil): return true
        case let (l?, r?): return l.stage != r.stage ? l.stage < r.stage : l.number < r.number
        }
    }

    static func == (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        lhs.marketingVersion == rhs.marketingVersion
            && lhs.prerelease?.stage == rhs.prerelease?.stage
            && lhs.prerelease?.number == rhs.prerelease?.number
    }
}
