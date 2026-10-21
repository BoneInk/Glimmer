import Foundation

private struct DefaultsTestFailure: Error, CustomStringConvertible {
    let description: String
}

private final class FakeDefaults: GlimmerDefaultsStoring, @unchecked Sendable {
    var values: [String: Any]
    var synchronizeResults: [Bool]
    private(set) var synchronizeCalls = 0

    init(values: [String: Any] = [:], synchronizeResults: [Bool] = []) {
        self.values = values
        self.synchronizeResults = synchronizeResults
    }

    func bool(forKey: String) -> Bool {
        values[forKey] as? Bool ?? false
    }

    func object(forKey: String) -> Any? {
        values[forKey]
    }

    func set(_ value: Any?, forKey: String) {
        if let value {
            values[forKey] = value
        } else {
            values.removeValue(forKey: forKey)
        }
    }

    func synchronize() -> Bool {
        synchronizeCalls += 1
        guard !synchronizeResults.isEmpty else { return true }
        return synchronizeResults.removeFirst()
    }

    func persistentDomain(forName: String) -> [String: Any]? {
        values
    }
}

@main
@MainActor
struct GlimmerDefaultsMigrationTests {
    private static var checks = 0
    private static let marker = GlimmerIdentity.defaultsMigrationMarker
    private static let oldFrameKey = "NSWindow Frame \(GlimmerIdentity.legacyLibraryWindowAutosaveName)"
    private static let newFrameKey = "NSWindow Frame \(GlimmerIdentity.libraryWindowAutosaveName)"

    static func main() throws {
        try testSuccessfulIdempotentMigration()
        try testValueCommitFailureIsRetryable()
        try testMarkerCommitFailureIsReported()
        try testExistingMarkerShortCircuits()
        print("GlimmerDefaultsMigrationTests: \(checks) checks passed; in-memory defaults only")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
        guard condition() else { throw DefaultsTestFailure(description: label) }
        checks += 1
        print("PASS \(label)")
    }

    private static func testSuccessfulIdempotentMigration() throws {
        let current = FakeDefaults(values: ["existing": "new-value"])
        let legacy = FakeDefaults(values: [
            oldFrameKey: "fixture-frame",
            "existing": "legacy-value",
            "legacy-only": "imported",
            marker: true
        ])
        let result = GlimmerUserDefaultsMigration.migrateIfNeeded(
            to: current, legacy: legacy, legacySuiteName: "fixture.legacy")
        try check(result.committed && result.failureReason == nil,
                  "successful migration reports a verified commit")
        try check(result.importedKeys == 1 && result.importedWindowFrame,
                  "only missing legacy keys and the window frame are imported")
        try check(current.values["existing"] as? String == "new-value",
                  "existing Glimmer preferences win over legacy values")
        try check(current.values["legacy-only"] as? String == "imported",
                  "missing legacy preference is imported")
        try check(current.values[newFrameKey] as? String == "fixture-frame",
                  "legacy window frame is renamed into the new autosave key")
        try check(current.bool(forKey: marker),
                  "successful migration commits the completion marker")
        try check(current.synchronizeCalls == 2,
                  "successful migration flushes values and marker separately")

        let repeated = GlimmerUserDefaultsMigration.migrateIfNeeded(
            to: current, legacy: legacy, legacySuiteName: "fixture.legacy")
        try check(repeated.markerAlreadyPresent && repeated.committed &&
                  repeated.importedKeys == 0 && !repeated.importedWindowFrame,
                  "repeated migration is an idempotent no-op")
    }

    private static func testValueCommitFailureIsRetryable() throws {
        let current = FakeDefaults(synchronizeResults: [false])
        let legacy = FakeDefaults(values: ["legacy-only": "retry-me"])
        let failed = GlimmerUserDefaultsMigration.migrateIfNeeded(
            to: current, legacy: legacy, legacySuiteName: "fixture.legacy")
        try check(!failed.committed && failed.failureReason != nil,
                  "failed values flush is not reported as a completed migration")
        try check(!current.bool(forKey: marker),
                  "failed values flush leaves the marker false")
        try check(current.values["legacy-only"] as? String == "retry-me",
                  "failed flush retains the imported in-memory value for an idempotent retry")

        let retried = GlimmerUserDefaultsMigration.migrateIfNeeded(
            to: current, legacy: legacy, legacySuiteName: "fixture.legacy")
        try check(retried.committed && current.bool(forKey: marker),
                  "a later retry commits the marker after persistence recovers")
    }

    private static func testMarkerCommitFailureIsReported() throws {
        let current = FakeDefaults(synchronizeResults: [true, false])
        let legacy = FakeDefaults(values: ["legacy-only": "value"])
        let result = GlimmerUserDefaultsMigration.migrateIfNeeded(
            to: current, legacy: legacy, legacySuiteName: "fixture.legacy")
        try check(!result.committed && result.failureReason != nil,
                  "failed marker flush is not reported as success")
        try check(!current.bool(forKey: marker),
                  "failed marker flush removes the unverified marker")

        let retried = GlimmerUserDefaultsMigration.migrateIfNeeded(
            to: current, legacy: legacy, legacySuiteName: "fixture.legacy")
        try check(retried.committed && current.bool(forKey: marker),
                  "marker commit failure remains retryable")
    }

    private static func testExistingMarkerShortCircuits() throws {
        let current = FakeDefaults(values: [marker: true])
        let legacy = FakeDefaults(values: ["legacy-only": "must-not-import"])
        let result = GlimmerUserDefaultsMigration.migrateIfNeeded(
            to: current, legacy: legacy, legacySuiteName: "fixture.legacy")
        try check(result.markerAlreadyPresent && result.committed &&
                  result.importedKeys == 0 && result.importedWindowFrame == false &&
                  current.values["legacy-only"] == nil && current.synchronizeCalls == 0,
                  "existing marker short-circuits without touching either domain")
    }
}
