import Security
import XCTest
@testable import OpenWallpaperEngine

/// Keychain storage of Steam secrets, and keeping them out of URLs, logs and argv. The test host's
/// `KeychainStore` keeps its items in memory (`AppStorageIsolationTests`), so these never call the keychain.
final class SteamCredentialsTests: XCTestCase {
    private var keychain: KeychainStore!

    override func setUpWithError() throws {
        keychain = KeychainStore(service: "app.openwallpaperengine.tests.keychain.\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        for account in ["token", "SteamWebAPIKey"] {
            try keychain.removeValue(forAccount: account)
        }
        StubURLProtocol.handler = nil
    }

    // MARK: Keychain store

    func testKeychainStoreRoundTripsReplacesAndRemoves() throws {
        try requireKeychain()
        XCTAssertNil(try keychain.string(forAccount: "token"))

        try keychain.set("first", forAccount: "token")
        XCTAssertEqual(try keychain.string(forAccount: "token"), "first")

        try keychain.set("second", forAccount: "token")
        XCTAssertEqual(try keychain.string(forAccount: "token"), "second")

        try keychain.removeValue(forAccount: "token")
        XCTAssertNil(try keychain.string(forAccount: "token"))
        XCTAssertNoThrow(try keychain.removeValue(forAccount: "token"), "removing a missing value succeeds")
    }

    func testKeychainAccountsAreIndependent() throws {
        try requireKeychain()
        try keychain.set("a", forAccount: "token")
        XCTAssertNil(try keychain.string(forAccount: "SteamWebAPIKey"))
        XCTAssertNil(try KeychainStore(service: keychain.service + ".other").string(forAccount: "token"))
    }

    func testSaveAndRemove() throws {
        try requireKeychain()
        try secret.save("NEW")
        XCTAssertEqual(secret.load(), "NEW")

        try secret.remove()
        XCTAssertNil(secret.load())
    }

    func testCredentialServicesLiveUnderTheIsolatedPrefix() {
        // Under XCTest the prefix is the isolated suite, so no test can touch the real items.
        let bundleId = AppStorageLocation.current.keychainServicePrefix
        XCTAssertTrue(bundleId.contains(".isolated."), bundleId)
        XCTAssertEqual(SteamCredentials.webAPIKey().keychain.service, "\(bundleId).steam-web-api-key")
        XCTAssertEqual(SteamCredentials.steamCmdAccount().keychain.service, "\(bundleId).steamcmd-account")
    }

    // MARK: Redaction

    func testRedactsKeyQueryParametersHeadersAndLiteralSecrets() {
        let url = "https://api.steampowered.com/ISteamUser/GetPlayerSummaries/v2/?key=ABCDEF0123456789&steamids=1"
        XCTAssertEqual(SteamSecretRedactor.redact(url),
                       "https://api.steampowered.com/ISteamUser/GetPlayerSummaries/v2/?key=<redacted>&steamids=1")
        XCTAssertEqual(SteamSecretRedactor.redact("failed: NSErrorFailingURLStringKey=https://x/?a=1&KEY=abc}"),
                       "failed: NSErrorFailingURLStringKey=https://x/?a=1&KEY=<redacted>}")
        XCTAssertEqual(SteamSecretRedactor.redact(#"headers: ["x-webapi-key": "ABCDEF"]"#),
                       #"headers: ["x-webapi-key": "<redacted>"]"#)
        XCTAssertEqual(SteamSecretRedactor.redact("Logging in user 'me' hunter2 / 12345", secrets: ["hunter2", "12345", ""]),
                       "Logging in user '<redacted>' <redacted> / <redacted>", "the account name too")
        XCTAssertEqual(SteamSecretRedactor.redact("monkey=banana&apikey=1"), "monkey=banana&apikey=1",
                       "only a parameter named exactly `key`")
        let once = SteamSecretRedactor.redact(url)
        XCTAssertEqual(SteamSecretRedactor.redact(once), once)
    }

    // MARK: Web API key stays out of URLs

    func testValidationSendsTheKeyInAHeaderNotTheURL() async throws {
        var seen: URLRequest?
        StubURLProtocol.handler = { request in
            seen = request
            return (200, Data(#"{"response":{"total":1}}"#.utf8))
        }
        try await service.validate(apiKey: "SECRETKEY123")

        let request = try XCTUnwrap(seen)
        XCTAssertEqual(request.value(forHTTPHeaderField: WorkshopAPIService.apiKeyHeader), "SECRETKEY123")
        let url = try XCTUnwrap(request.url?.absoluteString)
        XCTAssertFalse(url.contains("SECRETKEY123"))
        XCTAssertFalse(url.contains("key="))
        XCTAssertTrue(url.contains("IPublishedFileService/QueryFiles"))
    }

    func testRejectedKeyIsReportedAsInvalid() async {
        StubURLProtocol.handler = { _ in (403, Data()) }
        do {
            try await service.validate(apiKey: "BAD")
            XCTFail("a 403 must fail validation")
        } catch WorkshopAPIError.invalidAPIKey {
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testSearchWithoutAKeyFailsBeforeAnyRequest() async throws {
        try requireKeychain()
        StubURLProtocol.handler = { _ in
            XCTFail("no request without a key")
            return (500, Data())
        }
        do {
            _ = try await service.searchItems()
            XCTFail("search needs a key")
        } catch WorkshopAPIError.noAPIKey {
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testSearchReadsTheKeyFromTheKeychain() async throws {
        try requireKeychain()
        try secret.save("STOREDKEY")
        var seen: URLRequest?
        StubURLProtocol.handler = { request in
            seen = request
            return (200, Data(#"{"response":{}}"#.utf8))
        }
        let items = try await service.searchItems(query: "rain")
        XCTAssertTrue(items.isEmpty)
        XCTAssertEqual(seen?.value(forHTTPHeaderField: WorkshopAPIService.apiKeyHeader), "STOREDKEY")
        XCTAssertFalse(seen?.url?.absoluteString.contains("STOREDKEY") ?? true)
    }

    // MARK: Keyless author names

    func testParsesPersonaNameAndAvatarFromTheProfileXML() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?><profile>
        <steamID64>76561197960287930</steamID64>
        <steamID><![CDATA[Rabscuttle]]></steamID>
        <avatarFull><![CDATA[https://avatars.akamai.steamstatic.com/abc_full.jpg]]></avatarFull>
        <groups><group><groupID64>1</groupID64><steamID><![CDATA[Not the name]]></steamID></group></groups>
        </profile>
        """
        let player = try XCTUnwrap(SteamProfileXMLParser.player(from: Data(xml.utf8), steamId: "76561197960287930"))
        XCTAssertEqual(player.personaName, "Rabscuttle")
        XCTAssertEqual(player.steamId, "76561197960287930")
        XCTAssertEqual(player.avatarURL?.absoluteString, "https://avatars.akamai.steamstatic.com/abc_full.jpg")
    }

    func testMissingProfileParsesToNil() {
        let xml = #"<?xml version="1.0"?><response><error><![CDATA[The specified profile could not be found.]]></error></response>"#
        XCTAssertNil(SteamProfileXMLParser.player(from: Data(xml.utf8), steamId: "1"))
    }

    // MARK: steamcmd scripts

    func testSteamCmdScriptQuotesEveryArgumentAndEndsWithQuit() throws {
        var script = SteamCmdScript.withoutPasswordPrompt()
        try script.append("login", ["me", "pa ss;word", "AB12C"])
        try script.append("force_install_dir", ["/Users/me/My Folder"])
        let input = String(decoding: script.standardInput, as: UTF8.self)
        XCTAssertEqual(input, """
        @NoPromptForPassword 1
        login "me" "pa ss;word" "AB12C"
        force_install_dir "/Users/me/My Folder"
        quit

        """)
    }

    func testSteamCmdScriptRejectsArgumentsItCannotQuote() {
        var script = SteamCmdScript()
        XCTAssertThrowsError(try script.append("login", ["me", #"pa"ss"#]))
        XCTAssertThrowsError(try script.append("login", ["me", "pa\nquit"]))
        XCTAssertTrue(script.lines.isEmpty)
    }

    // MARK: Settings view model

    @MainActor
    func testViewModelMasksValidatesAndRemoves() async throws {
        try requireKeychain()
        var validated: [String] = []
        let model = SteamWebAPIKeyViewModel(store: secret) { validated.append($0) }
        XCTAssertFalse(model.isKeySet)
        XCTAssertTrue(model.isEditing)

        model.draft = "  0123456789ABCDEF  "
        let saved = await model.submit()
        XCTAssertTrue(saved)
        XCTAssertEqual(validated, ["0123456789ABCDEF"])
        XCTAssertEqual(model.maskedKey, "••••••••••••CDEF")
        XCTAssertFalse(model.isEditing)
        XCTAssertEqual(model.draft, "")

        model.remove()
        XCTAssertFalse(model.isKeySet)
        XCTAssertNil(secret.load())
    }

    @MainActor
    func testViewModelKeepsTheOldKeyWhenValidationFails() async throws {
        try requireKeychain()
        try secret.save("OLDKEY0123456789")
        let model = SteamWebAPIKeyViewModel(store: secret) { _ in throw WorkshopAPIError.invalidAPIKey }
        model.beginReplacing()
        model.draft = "NEWKEY"
        let saved = await model.submit()
        XCTAssertFalse(saved)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.errorMessage?.contains("NEWKEY") ?? true)
        XCTAssertEqual(secret.load(), "OLDKEY0123456789")
    }

    // MARK: Helpers

    private var secret: KeychainSecret {
        KeychainSecret(keychain: keychain, account: "SteamWebAPIKey")
    }

    private var service: WorkshopAPIService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return WorkshopAPIService(apiKey: secret, session: URLSession(configuration: configuration))
    }

    /// Skips on a machine without a usable keychain (a headless runner with no login keychain).
    private func requireKeychain() throws {
        do {
            try keychain.set("probe", forAccount: "token")
            try keychain.removeValue(forAccount: "token")
        } catch let failure as KeychainStore.Failure
            where [errSecNoSuchKeychain, errSecInteractionNotAllowed, errSecNotAvailable].contains(failure.status) {
            throw XCTSkip("No usable keychain: \(failure)")
        }
    }
}

private final class StubURLProtocol: URLProtocol {
    // Set by one test before it awaits its request and cleared in tearDown; tests run serially.
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, data) = handler(request)
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
