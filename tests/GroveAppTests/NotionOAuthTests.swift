import CryptoKit
import Foundation
import Testing
@testable import GroveApp

private final class OAuthFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var invalidRefresh = false
    nonisolated(unsafe) static var workspace = "workspace-one"
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var tools: [(Int, [String: Any])] = []
    static var metadata: [String: Any] { ["issuer": "https://mcp.notion.com", "authorization_endpoint": "https://mcp.notion.com/authorize",
        "token_endpoint": "https://mcp.notion.com/token", "registration_endpoint": "https://mcp.notion.com/register",
        "code_challenge_methods_supported": ["S256"], "token_endpoint_auth_methods_supported": ["none"]] }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var recorded = request
        if recorded.httpBody == nil, let stream = recorded.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            recorded.httpBody = data
        }
        let result: (Int, [String: Any]) = Self.lock.withLock {
            Self.requests.append(recorded)
            switch recorded.url!.path {
            case "/.well-known/oauth-protected-resource/mcp": return (200, ["resource": NotionOAuthConfiguration.server.absoluteString, "authorization_servers": ["https://mcp.notion.com"]])
            case "/.well-known/oauth-authorization-server": return (200, Self.metadata)
            case "/register": return (201, ["client_id": "registered-client", "token_endpoint_auth_method": "none"])
            case "/token":
                let refresh = String(data: recorded.httpBody ?? Data(), encoding: .utf8)?.contains("grant_type=refresh_token") == true
                if refresh && Self.invalidRefresh { return (400, ["error": "invalid_grant"]) }
                var result: [String: Any] = ["access_token": refresh ? "rotated-access" : "access", "refresh_token": refresh ? "rotated-refresh" : "refresh", "token_type": "bearer", "expires_in": 3600]
                if !refresh { result["workspace_id"] = Self.workspace; result["user_id"] = "authorized-user" }
                return (200, result)
            case "/mcp":
                let body = (try? JSONSerialization.jsonObject(with: recorded.httpBody ?? Data()) as? [String: Any]) ?? [:]
                guard let method = body["method"] as? String else { return (400, [:]) }
                if method == "initialize" { return (200, ["jsonrpc": "2.0", "id": body["id"]!, "result": ["protocolVersion": "2025-11-25", "capabilities": ["tools": [:]]]]) }
                if method == "notifications/initialized" { return (202, [:]) }
                let next = Self.tools.isEmpty ? (500, [:]) : Self.tools.removeFirst()
                return (next.0, next.0 == 200 ? ["jsonrpc": "2.0", "id": body["id"]!, "result": ["structuredContent": next.1]] : next.1)
            default: return (404, [:])
            }
        }
        let http = HTTPURLResponse(url: request.url!, statusCode: result.0, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json", "Mcp-Session-Id": "fixture-session"])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: result.1))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func reset() { lock.withLock { requests = []; invalidRefresh = false; workspace = "workspace-one"; tools = [] } }
}

@MainActor
private final class OAuthFixtureBrowser: NotionBrowserAuthorizing {
    var cancels = false
    var invalidState = false
    func authorize(url: URL) async throws -> URL {
        if cancels { throw NotionConnectionError.cancelled }
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "state" }!.value!
        var callback = URLComponents(url: NotionOAuthConfiguration.redirect, resolvingAgainstBaseURL: false)!
        callback.queryItems = [.init(name: "state", value: invalidState ? "wrong-state" : state), .init(name: "code", value: "code"), .init(name: "iss", value: "https://mcp.notion.com")]
        return callback.url!
    }
    func cancel() {}
}

@MainActor
private final class FailingOAuthStore: NotionConnectionStoring {
    var value: NotionStoredConnection?
    func read() throws -> NotionStoredConnection? { value }
    func save(_ connection: NotionStoredConnection) throws { throw NotionExportError.keychain }
    func clientID() throws -> String? { "registered-client" }
    func saveClientID(_ id: String) throws {}
}

@Suite(.serialized)
@MainActor
struct NotionOAuthTests {
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [OAuthFixtureProtocol.self]
        return URLSession(configuration: config)
    }
    private func grant() throws -> NotionOAuthGrant {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return NotionOAuthGrant(id: UUID(), clientID: "registered-client", metadata: try decoder.decode(NotionOAuthMetadata.self, from: JSONSerialization.data(withJSONObject: OAuthFixtureProtocol.metadata)),
            accessToken: "expired-access", refreshToken: "old-refresh", expiresAt: Date(timeIntervalSince1970: 0), workspaceID: "workspace-one", userID: "authorized-user")
    }
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "Grove.OAuth.Tests.\(UUID().uuidString)")! }

    @Test func pkceMatchesTheRFCVectorAndDoesNotIncludeTheVerifierInTheBrowserURL() throws {
        let attempt = try NotionOAuthAttempt(state: "state", verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(attempt.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let url = try attempt.authorizationURL(metadata: grant().metadata, clientID: "client")
        #expect(!url.absoluteString.contains(attempt.verifier))
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(.init(name: "resource", value: NotionOAuthConfiguration.server.absoluteString)) == true)
    }

    @Test func wrongStateIssuerDuplicateParametersAndExpiredCallbacksAreRejected() throws {
        let attempt = try NotionOAuthAttempt(state: "correct", verifier: "verifier", startedAt: Date(timeIntervalSince1970: 0))
        for query in ["state=wrong&code=code", "state=correct&code=code&iss=https://other.example", "state=correct&state=correct&code=code"] {
            #expect(throws: (any Error).self) { try attempt.authorizationCode(from: URL(string: NotionOAuthConfiguration.redirect.absoluteString + "?" + query)!, now: Date(timeIntervalSince1970: 1)) }
        }
        #expect(throws: (any Error).self) { try attempt.authorizationCode(from: URL(string: NotionOAuthConfiguration.redirect.absoluteString + "?state=correct&code=code")!, now: Date(timeIntervalSince1970: 601)) }
        #expect(throws: (any Error).self) { try NotionOAuthConfiguration.trustedEndpoint("https://mcp.notion.com.attacker.example/token") }
    }

    @Test func legacyCredentialsRemainReadableAndMalformedStructuredCredentialsCannotBecomeBearerTokens() throws {
        #expect(try KeychainNotionConnectionStore.decode(Data("legacy-private-token".utf8)) == .manual("legacy-private-token"))
        #expect(throws: (any Error).self) { try KeychainNotionConnectionStore.decode(Data("{invalid".utf8)) }
    }

    @Test func connectStoresIdentityAndReusesRegistrationWithoutRestrictingTheNextWorkspace() async throws {
        OAuthFixtureProtocol.reset()
        let storage = MemoryNotionConnectionStore(), browser = OAuthFixtureBrowser()
        let connection = NotionConnection(storage: storage, service: NotionOAuthService(session: session()), browser: browser, defaults: defaults())
        await connection.connect(); #expect(connection.isConnected && connection.isOAuth)
        connection.parentLink = "first-user-selected-page"
        let firstKey = connection.destinationKey
        OAuthFixtureProtocol.workspace = "workspace-two"
        await connection.connect()
        #expect(connection.isConnected && connection.destinationKey != firstKey && connection.parentLink.isEmpty)
        #expect(OAuthFixtureProtocol.requests.filter { $0.url?.path == "/register" }.count == 1)
        #expect(OAuthFixtureProtocol.requests.filter { $0.url?.path == "/token" }.allSatisfy { !(String(data: $0.httpBody ?? Data(), encoding: .utf8) ?? "").contains("client_secret") })
    }

    @Test func cancelledOrMismatchedAuthorizationPreservesThePreviousConnection() async throws {
        OAuthFixtureProtocol.reset()
        let storage = MemoryNotionConnectionStore(); storage.value = .manual("previous-token")
        let browser = OAuthFixtureBrowser(); browser.cancels = true
        let connection = NotionConnection(storage: storage, service: NotionOAuthService(session: session()), browser: browser, defaults: defaults())
        await connection.connect(); #expect(storage.value == .manual("previous-token"))
        browser.cancels = false; browser.invalidState = true
        await connection.connect(); #expect(storage.value == .manual("previous-token"))
        #expect(!OAuthFixtureProtocol.requests.contains { $0.url?.path == "/token" })
    }

    @Test func concurrentExpiryChecksRefreshOnceAndPersistTheRotatedPairBeforeReturning() async throws {
        OAuthFixtureProtocol.reset()
        let storage = MemoryNotionConnectionStore(), grant = try grant(); storage.value = .oauth(grant)
        let connection = NotionConnection(storage: storage, service: NotionOAuthService(session: session()), browser: OAuthFixtureBrowser(), defaults: defaults())
        async let first = connection.accessToken(grantID: grant.id)
        async let second = connection.accessToken(grantID: grant.id)
        #expect(try await first == "rotated-access"); #expect(try await second == "rotated-access")
        guard case .oauth(let saved) = storage.value else { Issue.record("Missing saved grant"); return }
        #expect(saved.refreshToken == "rotated-refresh" && saved.workspaceID == grant.workspaceID)
        #expect(OAuthFixtureProtocol.requests.filter { $0.url?.path == "/token" }.count == 1)
    }

    @Test func invalidGrantStopsRefreshAndClearsDeadTokens() async throws {
        OAuthFixtureProtocol.reset(); OAuthFixtureProtocol.invalidRefresh = true
        let storage = MemoryNotionConnectionStore(), grant = try grant(); storage.value = .oauth(grant)
        let connection = NotionConnection(storage: storage, service: NotionOAuthService(session: session()), browser: OAuthFixtureBrowser(), defaults: defaults())
        await #expect(throws: (any Error).self) { try await connection.accessToken(grantID: grant.id) }
        await #expect(throws: (any Error).self) { try await connection.accessToken(grantID: grant.id) }
        #expect(storage.value == .disconnected && connection.requiresReconnect)
        #expect(OAuthFixtureProtocol.requests.filter { $0.url?.path == "/token" }.count == 1)
    }

    @Test func rotatedTokensAreNotPublishedWhenTheirAtomicSaveFails() async throws {
        OAuthFixtureProtocol.reset()
        let storage = FailingOAuthStore(), grant = try grant(); storage.value = .oauth(grant)
        let connection = NotionConnection(storage: storage, service: NotionOAuthService(session: session()), browser: OAuthFixtureBrowser(), defaults: defaults())
        await #expect(throws: (any Error).self) { try await connection.accessToken(grantID: grant.id) }
        #expect(storage.value == .oauth(grant) && connection.requiresReconnect && !connection.isConnected)
    }

    @Test func streamableHTTPMatchesReplyIDsAndIgnoresNotifications() throws {
        let sse = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}\n\nevent: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":\"request\",\"result\":{\"value\":1}}\n\n"
        #expect(try NotionMCPTransport.result(data: Data(sse.utf8), contentType: "text/event-stream", id: "request")["value"] as? Int == 1)
        #expect(throws: (any Error).self) { try NotionMCPTransport.result(data: Data(sse.utf8), contentType: "text/event-stream", id: "different") }
    }

    private func page(_ id: String, parent: String? = nil, content: String = "기존 원문") -> [String: Any] {
        let ancestors = parent.map { "<ancestor-path><parent-page url=\"\(NotionPageLink.url(for: $0))\" title=\"부모\"/></ancestor-path>" } ?? "<ancestor-path></ancestor-path>"
        return ["text": "<page url=\"\(NotionPageLink.url(for: id))\">\(ancestors)<properties>{\"title\":\"검증 페이지\"}</properties><content>\n\(content)\n</content></page>"]
    }

    @Test func oauthExportAppendsADividerCreatesOneChildAndVerifiesItsParent() async throws {
        OAuthFixtureProtocol.reset()
        let parent = "01234567-89ab-cdef-0123-456789abcdef", child = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        OAuthFixtureProtocol.tools = [(200, page(parent)), (200, page(parent)), (200, ["page_id": parent]),
            (200, ["pages": [["id": child]]]), (200, page(child, parent: parent))]
        let storage = MemoryNotionConnectionStore(); storage.value = .oauth(try grant())
        let connection = NotionConnection(storage: storage, service: NotionOAuthService(session: session()), browser: OAuthFixtureBrowser(), defaults: defaults())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let exporter = NotionExporter(directory: directory)
        let meeting = MeetingRecord(title: "검증 회의", startedAt: Date(), duration: 1, status: .ready, glossaryProfile: "", transcript: [], claims: [])
        let document = try TranscriptDocument(speakers: [], utterances: [.init(id: UUID(), startTime: 0, endTime: 1, rawText: "전체 원문", sourceChannelID: "recording", engineClusterID: nil, speakerID: nil, editedText: nil)])
        let url = try await exporter.save(meeting: meeting, document: document, parentLink: parent, original: false, client: connection.client(session: session()))
        #expect(url == NotionPageLink.url(for: child))
        #expect(try exporter.receipt(meetingID: meeting.id)?.verified == true)
        let calls = OAuthFixtureProtocol.requests.filter { $0.url?.path == "/mcp" }.compactMap { try? JSONSerialization.jsonObject(with: $0.httpBody ?? Data()) as? [String: Any] }
        let tools = calls.filter { $0["method"] as? String == "tools/call" }.compactMap { $0["params"] as? [String: Any] }
        #expect(tools.compactMap { $0["name"] as? String } == ["notion-fetch", "notion-fetch", "notion-update-page", "notion-create-pages", "notion-fetch"])
        let update = tools[2]["arguments"] as? [String: Any]
        #expect(update?["command"] as? String == "insert_content")
        #expect((update?["position"] as? [String: Any])?["type"] as? String == "end")
        #expect(OAuthFixtureProtocol.requests.filter { $0.url?.path == "/mcp" }.dropFirst().allSatisfy { $0.value(forHTTPHeaderField: "Mcp-Session-Id") == "fixture-session" })
    }

    @Test func uncertainMCPPageCreationIsNotAutomaticallyRetried() async throws {
        OAuthFixtureProtocol.reset()
        OAuthFixtureProtocol.tools = [(200, ["object": "async_task", "id": "task-accepted"])]
        let storage = MemoryNotionConnectionStore(); storage.value = .oauth(try grant())
        let connection = NotionConnection(storage: storage, service: NotionOAuthService(session: session()), browser: OAuthFixtureBrowser(), defaults: defaults())
        let client = try connection.client(session: session())
        await #expect(throws: (any Error).self) { try await client.create(parent: "01234567-89ab-cdef-0123-456789abcdef", title: "회의록", markdown: "원문") }
        #expect(OAuthFixtureProtocol.requests.filter { $0.url?.path == "/mcp" && String(data: $0.httpBody ?? Data(), encoding: .utf8)?.contains("notion-create-pages") == true }.count == 1)
    }

    @Test func truncatedAndUnexpectedPageResponsesAreRejectedBeforeWriting() throws {
        let id = "01234567-89ab-cdef-0123-456789abcdef"
        var result = page(id); result["truncated"] = true
        #expect(throws: (any Error).self) { try NotionFetchedPage(response: result, expectedID: id) }
        #expect(throws: (any Error).self) { try NotionFetchedPage(response: ["text": "<database url=\"https://www.notion.so/0123456789abcdef0123456789abcdef\"></database>"], expectedID: id) }
        #expect(throws: (any Error).self) { try NotionFetchedPage(response: page(id), expectedID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee") }
    }
}
