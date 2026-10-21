import AppKit
import XCTest
@testable import OpenWallpaperEngine

/// The `--control` command line: WE's spellings and this app's, the `RAW~(…)~END` properties,
/// usage errors, display locations, `-file` paths, and a command's round trip to the app.
@MainActor
final class CommandLineControlTests: XCTestCase {
    private typealias Request = CommandLineControlRequest

    private func parse(_ arguments: [String]) throws -> Request {
        let result = try XCTUnwrap(Request.parse(["/Applications/Open Wallpaper Engine.app/Contents/MacOS/Open Wallpaper Engine"] + arguments))
        return try result.get()
    }

    private func error(_ arguments: [String]) -> Request.ParseError? {
        guard case let .failure(error) = Request.parse(["owe"] + arguments) else { return nil }
        return error
    }

    func testNoControlArgumentIsAnOrdinaryLaunch() {
        XCTAssertNil(Request.parse(["owe"]))
        XCTAssertNil(Request.parse(["owe", "--wallpaper-editor", "/tmp/x"]))
    }

    func testWEsSpellingAndTheAppsAreTheSame() throws {
        let we = try parse(["-control", "openWallpaper", "-file", "/w/project.json", "-playInWindow", "Left",
                            "-width", "800", "-height", "600", "-x", "10", "-y", "20", "-borderless"])
        let mac = try parse(["--control", "open-wallpaper", "--file", "/w/project.json", "--play-in-window", "Left",
                             "--width", "800", "--height", "600", "--x", "10", "--y", "20", "--borderless"])
        XCTAssertEqual(we, mac)
        XCTAssertEqual(we.verb, .openWallpaper)
        XCTAssertEqual(we.options, ["file": "/w/project.json", "playinwindow": "Left", "width": "800",
                                    "height": "600", "x": "10", "y": "20"])
        XCTAssertEqual(we.flags, ["borderless"])
        XCTAssertEqual(try parse(["-control", "HIDEICONS"]).verb, .hideIcons)
        XCTAssertEqual(try parse(["--control", "show_icons"]).verb, .showIcons)
    }

    func testEveryWEVerbParses() throws {
        for verb in Request.Verb.allCases {
            var arguments = ["-control", verb.rawValue]
            if let required = verb.required { arguments += ["-\(required)", required == "properties" ? "{}" : "x"] }
            XCTAssertEqual(try parse(arguments).verb, verb)
        }
    }

    func testPropertiesTakeWEsRawWrapper() throws {
        let request = try parse(["-control", "applyProperties", "-properties", "RAW~({\"schemecolor\":\"1 0 0\"})~END", "-monitor", "1"])
        XCTAssertEqual(request.option("properties"), "{\"schemecolor\":\"1 0 0\"}")
        XCTAssertEqual(request.int("monitor"), 1)
        XCTAssertEqual(Request.unwrapRaw("{\"rate\":10}"), "{\"rate\":10}")
    }

    func testUsageErrors() {
        XCTAssertEqual(error(["--control"]), .missingVerb)
        XCTAssertEqual(error(["--control", "explode"]), .unknownVerb("explode"))
        XCTAssertEqual(error(["--control", "pause", "--file", "x"]), .unknownOption("--file", .pause))
        XCTAssertEqual(error(["--control", "open-wallpaper"]), .missingOption("file", .openWallpaper))
        XCTAssertEqual(error(["--control", "open-wallpaper", "--file"]), .missingValue("--file"))
        XCTAssertEqual(error(["--control", "next-wallpaper", "--monitor", "left"]), .notANumber("monitor"))
        XCTAssertNotNil(Request.ParseError.unknownVerb("x").errorDescription)
    }

    func testTheIsolationArgumentIsNotAnOption() throws {
        let request = try parse(["-control", "pause", "-OWEIsolatedState", "shots"])
        XCTAssertEqual(request, Request(verb: .pause))
    }

    func testLocationsAreDisplayIdentitiesOrIds() {
        let connected = [DisplayIdentity(screenId: "1", identity: "AAAA-1111"), DisplayIdentity(screenId: "2", identity: "BBBB-2222")]
        XCTAssertEqual(CommandLineControlPerformer.screenId(ofLocation: "bbbb-2222", connected: connected), "2")
        XCTAssertEqual(CommandLineControlPerformer.screenId(ofLocation: "BBBB-2222/L", connected: connected), "2/L")
        XCTAssertEqual(CommandLineControlPerformer.screenId(ofLocation: "1", connected: connected), "1")
        XCTAssertNil(CommandLineControlPerformer.screenId(ofLocation: "Wallpaper Pop-out", connected: connected))
    }

    func testPropertyValuesAsStored() {
        XCTAssertEqual(CommandLineControlPerformer.propertyValue("1 0 0"), "1 0 0")
        XCTAssertEqual(CommandLineControlPerformer.propertyValue(NSNumber(value: 10)), "10")
        XCTAssertEqual(CommandLineControlPerformer.propertyValue(NSNumber(value: 0.5)), "0.5")
        XCTAssertEqual(CommandLineControlPerformer.propertyValue(NSNumber(value: true)), "true")
    }

    func testFileIsAProjectJSONAFolderOrAFileInIt() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "owe-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) } // Only the test's own folder.
        let project = #"{"file":"clip.mp4","title":"Clip","type":"video"}"#
        try Data(project.utf8).write(to: folder.appending(path: "project.json"))
        try Data().write(to: folder.appending(path: "clip.mp4"))
        for path in ["project.json", "", "clip.mp4"] {
            let wallpaper = try CommandLineControlPerformer.wallpaper(atPath: folder.appending(path: path).path, library: [])
            XCTAssertEqual(wallpaper.project.title, "Clip")
            XCTAssertEqual(wallpaper.wallpaperDirectory.standardizedFileURL.path, folder.standardizedFileURL.path)
        }
        XCTAssertThrowsError(try CommandLineControlPerformer.wallpaper(atPath: "relative/project.json", library: []))
        XCTAssertThrowsError(try CommandLineControlPerformer.wallpaper(atPath: folder.appending(path: "missing").path, library: []))
    }

    func testACommandAndItsAnswerTravelBetweenTheProcesses() {
        let channel = CommandLineControlChannel(prefix: "app.openwallpaperengine.isolated.cli-test-\(UUID().uuidString)")
        var received: [Request] = []
        let listener = CommandLineControlListener(channel: channel) { request in
            received.append(request)
            return CommandLineControlReply(succeeded: true, output: "/w/project.json")
        }
        listener.start()
        defer { listener.stop() }
        let reply = channel.send(Request(verb: .getWallpaper, options: ["monitor": "0"]), timeout: 5)
        XCTAssertEqual(reply, CommandLineControlReply(succeeded: true, output: "/w/project.json"))
        XCTAssertEqual(received, [Request(verb: .getWallpaper, options: ["monitor": "0"])])
    }
}
