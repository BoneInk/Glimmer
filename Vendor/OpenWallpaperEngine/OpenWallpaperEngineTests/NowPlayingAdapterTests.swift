import XCTest
@testable import OpenWallpaperEngine

/// The adapter process as the test drives it. `lock` owns every var.
private final class FakeAdapterProcess: NowPlayingAdapterProcess {
    private let lock = NSLock()
    private var output: ((Data) -> Void)?
    private var exit: ((Int32) -> Void)?
    private var _starts = 0
    private var _stops = 0
    var failsToStart = false

    var starts: Int { lock.lock(); defer { lock.unlock() }; return _starts }
    var stops: Int { lock.lock(); defer { lock.unlock() }; return _stops }

    struct StartFailure: Error {}

    func start(output: @escaping (Data) -> Void, exit: @escaping (Int32) -> Void) throws {
        if failsToStart { throw StartFailure() }
        lock.lock()
        _starts += 1
        self.output = output
        self.exit = exit
        lock.unlock()
    }

    func stop() { lock.lock(); _stops += 1; lock.unlock() }

    func send(_ text: String) {
        lock.lock()
        let output = self.output
        lock.unlock()
        output?(Data(text.utf8))
    }

    func end(_ status: Int32) {
        lock.lock()
        let exit = self.exit
        lock.unlock()
        exit?(status)
    }
}

/// The macOS 15.4+ Now Playing adapter: its output, its lifecycle and which macOS uses it.
final class NowPlayingAdapterTests: XCTestCase {
    private func recordedLines() throws -> [String] {
        let text = try String(contentsOf: Fixtures.url("NowPlaying/adapter-stream.txt"), encoding: .utf8)
        return text.split(separator: "\n").map(String.init)
    }

    private func sessionLine(title: String, playing: Bool) throws -> String {
        let info: [String: Any] = [MediaRemote.Key.title: title, MediaRemote.Key.artist: "Artist", "isPlaying": playing]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
        return "S " + data.base64EncodedString() + "\n"
    }

    // MARK: - Parsing the recorded stream

    func testRecordedStreamParsesAcrossChunkBoundaries() throws {
        let stream = Data(try String(contentsOf: Fixtures.url("NowPlaying/adapter-stream.txt"), encoding: .utf8).utf8)
        var buffer = Data()
        var lines: [String] = []
        var offset = 0
        // Chunks of 7 bytes: every line arrives in pieces.
        while offset < stream.count {
            buffer.append(stream[offset..<min(offset + 7, stream.count)])
            lines += NowPlayingAdapter.takeLines(from: &buffer)
            offset += 7
        }
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(lines, try recordedLines())
    }

    func testRecordedSessionsMapToMediaRemotesKeys() throws {
        let lines = try recordedLines()
        guard case .session(let info, let isPlaying)? = NowPlayingAdapter.parse(lines[0]) else {
            return XCTFail("the first line is a session")
        }
        XCTAssertTrue(isPlaying)
        let dictionary = try XCTUnwrap(info as? [String: Any])
        XCTAssertNil(dictionary["isPlaying"], "the playing flag is taken out of the info")
        XCTAssertEqual(dictionary[MediaRemote.Key.title] as? String, "Test Song")
        XCTAssertEqual(dictionary[MediaRemote.Key.artist] as? String, "Test Artist")
        XCTAssertEqual(dictionary[MediaRemote.Key.duration] as? Double, 296.981)
        let timestamp = try XCTUnwrap(dictionary[MediaRemote.Key.timestamp] as? Date)
        XCTAssertEqual(timestamp.timeIntervalSince1970, 1_790_508_575.340151, accuracy: 1e-5, "sub-second dates survive")
        let artwork = try XCTUnwrap(dictionary[MediaRemote.Key.artworkData] as? Data)
        XCTAssertEqual(Array(artwork.prefix(4)), [0x89, 0x50, 0x4E, 0x47])

        // Through the source's mapping, as MediaRemote's own dictionary would go.
        let now = timestamp.addingTimeInterval(2)
        let state = MacMediaSessionSource.state(from: dictionary, isPlaying: isPlaying, enabled: true, now: now, artwork: nil)
        XCTAssertEqual(state.playback, .playing)
        XCTAssertEqual(state.properties.title, "Test Song")
        XCTAssertEqual(state.properties.albumTitle, "Test Album")
        XCTAssertEqual(state.timeline, .init(position: 14, duration: 296.981))

        XCTAssertNil(NowPlayingAdapter.parse(lines[1]), "a malformed line is skipped")
        guard case .session(let pausedInfo, false)? = NowPlayingAdapter.parse(lines[2]) else {
            return XCTFail("the third line is a paused session")
        }
        XCTAssertEqual((pausedInfo as? [String: Any])?[MediaRemote.Key.elapsedTime] as? Double, 40.25)
        XCTAssertEqual(NowPlayingAdapter.parse(lines[3]), .session(info: NSDictionary(), isPlaying: false), "nothing playing")
        XCTAssertEqual(NowPlayingAdapter.parse(lines[4]), .failure("MediaRemote has no MRNowPlayingRequest"))
        XCTAssertNil(NowPlayingAdapter.parse("S not-base64!"))
    }

    // MARK: - The adapter's lifecycle

    func testTheAdapterIsAvailableOnlyOnceItReportedAndStopsWhenUnregistered() throws {
        var processes: [FakeAdapterProcess] = []
        let adapter = NowPlayingAdapter { let process = FakeAdapterProcess(); processes.append(process); return process }
        let queue = DispatchQueue(label: "test")
        adapter.register(on: queue)
        adapter.register(on: queue)
        XCTAssertEqual(processes.count, 1, "one process however often it is registered")
        XCTAssertFalse(adapter.isAvailable, "nothing reported yet")

        let announced = expectation(forNotification: adapter.notificationNames[0], object: nil)
        processes[0].send(try sessionLine(title: "Song", playing: true))
        wait(for: [announced], timeout: 1)
        XCTAssertTrue(adapter.isAvailable)
        let fetched = expectation(description: "info")
        adapter.nowPlayingInfo(on: queue) { info in
            XCTAssertEqual(info[MediaRemote.Key.title] as? String, "Song")
            fetched.fulfill()
        }
        let playing = expectation(description: "playing")
        adapter.isPlaying(on: queue) { XCTAssertTrue($0); playing.fulfill() }
        wait(for: [fetched, playing], timeout: 1)

        adapter.unregister()
        XCTAssertEqual(processes[0].stops, 1)
        XCTAssertFalse(adapter.isAvailable)
        processes[0].send(try sessionLine(title: "Late", playing: true))
        XCTAssertFalse(adapter.isAvailable, "output of a stopped process is ignored")

        adapter.register(on: queue)
        XCTAssertEqual(processes.count, 2, "a new listener starts it again")
        XCTAssertEqual(processes[1].starts, 1)
    }

    func testAFailureStopsTheAdapterUntilTheNextRegistration() throws {
        var processes: [FakeAdapterProcess] = []
        let adapter = NowPlayingAdapter { let process = FakeAdapterProcess(); processes.append(process); return process }
        let queue = DispatchQueue(label: "test")
        adapter.register(on: queue)
        processes[0].send(try sessionLine(title: "Song", playing: false))
        XCTAssertTrue(adapter.isAvailable)

        let announced = expectation(forNotification: adapter.notificationNames[0], object: nil)
        processes[0].send("E MediaRemote.framework is missing\n")
        wait(for: [announced], timeout: 1)
        XCTAssertFalse(adapter.isAvailable, "a failure after a session announces the loss")
        XCTAssertEqual(processes[0].stops, 1)
        processes[0].end(1)
        adapter.register(on: queue)
        XCTAssertEqual(processes.count, 2)

        // A process that ends before reporting leaves it unavailable, silently for the source.
        processes[1].end(1)
        XCTAssertFalse(adapter.isAvailable)
        let failing = FakeAdapterProcess()
        failing.failsToStart = true
        let unstartable = NowPlayingAdapter { failing }
        unstartable.register(on: queue)
        XCTAssertFalse(unstartable.isAvailable)
    }

    // MARK: - Through the media source

    private func waitForSource(_ source: MacMediaSessionSource) {
        for _ in 0..<4 { source.flush() }
    }

    func testTheSourceRunsTheAdapterOnlyWhileSomeoneListens() throws {
        var processes: [FakeAdapterProcess] = []
        let adapter = NowPlayingAdapter { let process = FakeAdapterProcess(); processes.append(process); return process }
        let source = MacMediaSessionSource(framework: adapter)
        let lock = NSLock()
        var states: [MediaSessionState] = []
        let first = source.subscribe { state in lock.lock(); states.append(state); lock.unlock() }
        let second = source.subscribe { _ in }
        waitForSource(source)
        XCTAssertEqual(processes.count, 1, "started with the first listener, once")
        lock.lock()
        XCTAssertFalse(states.contains { $0.enabled }, "disabled until the adapter reports")
        lock.unlock()

        processes[0].send(try sessionLine(title: "Song", playing: true))
        waitForSource(source)
        lock.lock()
        let latest = states.last
        lock.unlock()
        XCTAssertEqual(latest?.enabled, true)
        XCTAssertEqual(latest?.properties.title, "Song")
        XCTAssertEqual(latest?.playback, .playing)

        source.unsubscribe(first)
        waitForSource(source)
        XCTAssertEqual(processes[0].stops, 0, "another listener remains")
        source.unsubscribe(second)
        waitForSource(source)
        XCTAssertEqual(processes[0].stops, 1, "stopped when no listener is left")
    }

    func testTurningMediaIntegrationOffStopsTheAdapterAndDisablesListeners() throws {
        var processes: [FakeAdapterProcess] = []
        let adapter = NowPlayingAdapter { let process = FakeAdapterProcess(); processes.append(process); return process }
        let source = MacMediaSessionSource(framework: adapter)
        let lock = NSLock()
        var latest: MediaSessionState?
        let id = source.subscribe { state in lock.lock(); latest = state; lock.unlock() }
        waitForSource(source)
        processes[0].send(try sessionLine(title: "Song", playing: true))
        waitForSource(source)

        source.setIntegrationEnabled(false)
        waitForSource(source)
        XCTAssertEqual(processes[0].stops, 1)
        lock.lock()
        XCTAssertEqual(latest, MediaSessionState(), "disabled, and nothing playing")
        lock.unlock()

        source.setIntegrationEnabled(true)
        waitForSource(source)
        XCTAssertEqual(processes.count, 2, "on again, the adapter restarts for the listener")
        source.unsubscribe(id)
        waitForSource(source)
    }

    // MARK: - Which macOS uses it

    func testMacOS15Point4AndLaterUseTheAdapter() {
        func backend(_ major: Int, _ minor: Int) -> NowPlayingBackend {
            NowPlayingBackend.forSystem(OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: 0))
        }
        XCTAssertEqual(backend(14, 7), .mediaRemote)
        XCTAssertEqual(backend(15, 3), .mediaRemote)
        XCTAssertEqual(backend(15, 4), .adapter)
        XCTAssertEqual(backend(15, 10), .adapter)
        XCTAssertEqual(backend(26, 0), .adapter)
    }

    /// The shipped script compiles under the system perl: a mistake in it would only show as a
    /// wallpaper that never gets a media event.
    func testTheAdapterScriptCompilesUnderTheSystemPerl() throws {
        let script = try XCTUnwrap(AppBundleLayout.framework.url(forResource: NowPlayingBackend.script.name,
                                                   withExtension: NowPlayingBackend.script.extension))
        let process = Process()
        process.executableURL = PerlNowPlayingAdapterProcess.perl
        process.arguments = ["-c", script.path]
        process.environment = ["PATH": "/usr/bin:/bin"]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        let message: String = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let status: Int32 = process.terminationStatus
        XCTAssertEqual(status, 0, message)
        XCTAssertTrue(message.contains("syntax OK"), message)
    }

    /// Live: while something plays whose artwork MediaRemote has (its metadata's
    /// `artworkAvailable`, which Music and most players set without putting the image in the
    /// item), the shipped adapter's session carries the image within a few seconds. Skipped when
    /// nothing plays or the item has no artwork (CI).
    func testTheLiveSessionCarriesItsArtwork() throws {
        let probe = #"""
            require Foundation; PerlObjCBridge::setDieOnExceptions(0);
            NSBundle->bundleWithPath_('/System/Library/PrivateFrameworks/MediaRemote.framework')->load;
            @MRNowPlayingRequest::ISA = ('PerlObjCBridge');
            my $item = MRNowPlayingRequest->localNowPlayingItem;
            my $metadata = (defined($item) && $$item) ? $item->metadata : undef;
            print((defined($metadata) && $$metadata && $metadata->artworkAvailable) ? "1" : "0");
            """#
        let available = try Self.runPerl(["-e", probe], seconds: 10)
        try XCTSkipUnless(available.hasPrefix("1"), "nothing with artwork is playing")
        let script = try XCTUnwrap(AppBundleLayout.framework.url(forResource: NowPlayingBackend.script.name,
                                                   withExtension: NowPlayingBackend.script.extension))
        let output = try Self.runPerl([script.path], seconds: 5)
        let sessions: [NSDictionary] = output.split(separator: "\n").compactMap { line in
            guard case .session(let info, _)? = NowPlayingAdapter.parse(String(line)) else { return nil }
            return info
        }
        XCTAssertFalse(sessions.isEmpty, output)
        let artwork = sessions.last.flatMap { $0[MediaRemote.Key.artworkData] as? Data }
        let bytes: Int = artwork?.count ?? 0
        XCTAssertGreaterThan(bytes, 0, "the session has the item's artwork")
    }

    /// Runs `/usr/bin/perl` with `arguments` for at most `seconds` (its input closes then, which
    /// ends the adapter) and returns its output.
    private static func runPerl(_ arguments: [String], seconds: Double) throws -> String {
        let process = Process()
        process.executableURL = PerlNowPlayingAdapterProcess.perl
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        let received = ReceivedOutput()
        output.fileHandleForReading.readabilityHandler = { handle in received.append(handle.availableData) }
        try process.run()
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        output.fileHandleForReading.readabilityHandler = nil
        let rest = output.fileHandleForReading.readDataToEndOfFile()
        received.append(rest)
        return received.text
    }

    /// A process's output as it arrives on Foundation's queue. `lock` owns `data`.
    private final class ReceivedOutput: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }

        var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }

    func testTheAppShipsTheAdapterScript() {
        let version = OperatingSystemVersion(majorVersion: 15, minorVersion: 4, patchVersion: 0)
        XCTAssertNotNil(AppBundleLayout.framework.url(forResource: NowPlayingBackend.script.name, withExtension: NowPlayingBackend.script.extension))
        XCTAssertTrue(NowPlayingBackend.load(version: version) is NowPlayingAdapter,
                      "made, not started: nothing runs until a listener registers")
        XCTAssertNil(NowPlayingBackend.load(version: version, bundle: Bundle(for: Self.self)),
                     "without the script there is no media integration")
    }
}
