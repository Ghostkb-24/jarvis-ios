import CryptoKit
import Foundation
import Security
import XCTest
@testable import JarvisCore
@testable import JarvisProtocol

@MainActor
final class BridgeClientTests: XCTestCase {
    func testKeychainAddReadUsesGenericPasswordThisDeviceOnlyAccessibility() throws {
        let security = FakeSecurityItemAccess()
        let store = KeychainDeviceStore(service: "test.jarvis", security: security)
        let credentials = try DeviceCredentials(
            deviceID: "iphone-1",
            secret: Data("0123456789abcdef0123456789abcdef".utf8),
            certificateFingerprint: String(repeating: "ab", count: 32)
        )

        try store.save(credentials)

        XCTAssertEqual(try store.load(), credentials)
        XCTAssertEqual(security.addedItems.count, 3)
        XCTAssertTrue(security.addedItems.allSatisfy { item in
            item.itemClass == .genericPassword
                && item.accessibility == .afterFirstUnlockThisDeviceOnly
        })
    }

    func testKeychainDuplicateSaveUpdatesAllCredentialItemsAndAccessibility() throws {
        let security = FakeSecurityItemAccess()
        let store = KeychainDeviceStore(service: "test.jarvis", security: security)
        let first = try DeviceCredentials(
            deviceID: "iphone-1",
            secret: Data(repeating: 1, count: 32),
            certificateFingerprint: String(repeating: "ab", count: 32)
        )
        let second = try DeviceCredentials(
            deviceID: "iphone-2",
            secret: Data(repeating: 2, count: 32),
            certificateFingerprint: String(repeating: "cd", count: 32)
        )

        try store.save(first)
        try store.save(second)

        XCTAssertEqual(try store.load(), second)
        XCTAssertEqual(security.updatedItems.count, 3)
        XCTAssertTrue(security.updatedItems.allSatisfy {
            $0.accessibility == .afterFirstUnlockThisDeviceOnly
        })
    }

    func testKeychainDeleteRemovesAllCredentialItems() throws {
        let security = FakeSecurityItemAccess()
        let store = KeychainDeviceStore(service: "test.jarvis", security: security)
        let credentials = try DeviceCredentials(
            deviceID: "iphone-1",
            secret: Data(repeating: 3, count: 32),
            certificateFingerprint: String(repeating: "ef", count: 32)
        )
        try store.save(credentials)

        try store.delete()

        XCTAssertNil(try store.load())
        XCTAssertEqual(Set(security.deletedAccounts), Set(KeychainDeviceStore.credentialAccounts))
    }

    func testKeychainRejectsInvalidSecretAndFingerprintBeforeWriting() throws {
        let security = FakeSecurityItemAccess()
        let store = KeychainDeviceStore(service: "test.jarvis", security: security)

        XCTAssertThrowsError(
            try DeviceCredentials(
                deviceID: "iphone-1",
                secret: Data(repeating: 0, count: 31),
                certificateFingerprint: String(repeating: "ab", count: 32)
            )
        )
        XCTAssertThrowsError(
            try DeviceCredentials(
                deviceID: "iphone-1",
                secret: Data(repeating: 0, count: 32),
                certificateFingerprint: String(repeating: "A", count: 64)
            )
        )
        XCTAssertTrue(security.addedItems.isEmpty)
        XCTAssertNil(try store.load())
    }

    func testCertificatePinAcceptsMatchingLeafDER() throws {
        let delegate = try PinnedCertificateDelegate(
            fingerprint: "c1a0ceabf6abc32b0a0f84665601befdeff92a19b348ea91a246a01c4d97dc1d"
        )

        XCTAssertEqual(
            delegate.disposition(
                authenticationMethod: NSURLAuthenticationMethodServerTrust,
                leafCertificateDER: Data("leaf-der".utf8)
            ),
            .useCredential
        )
    }

    func testCertificatePinRejectsMismatchNoTrustAndUnexpectedAuthentication() throws {
        let delegate = try PinnedCertificateDelegate(
            fingerprint: String(repeating: "00", count: 32)
        )

        XCTAssertEqual(
            delegate.disposition(
                authenticationMethod: NSURLAuthenticationMethodServerTrust,
                leafCertificateDER: Data("leaf-der".utf8)
            ),
            .cancelAuthenticationChallenge
        )
        XCTAssertEqual(
            delegate.disposition(
                authenticationMethod: NSURLAuthenticationMethodServerTrust,
                leafCertificateDER: nil
            ),
            .cancelAuthenticationChallenge
        )
        XCTAssertEqual(
            delegate.disposition(
                authenticationMethod: NSURLAuthenticationMethodHTTPBasic,
                leafCertificateDER: Data("leaf-der".utf8)
            ),
            .cancelAuthenticationChallenge
        )
    }

    func testPinnedDelegateRejectsAll307And308RedirectDestinationsForPOSTBodies() throws {
        let delegate = try PinnedCertificateDelegate(
            fingerprint: String(repeating: "00", count: 32)
        )
        var original = URLRequest(
            url: try XCTUnwrap(URL(string: "https://192.168.1.20:8443/v1/requests"))
        )
        original.httpMethod = "POST"
        original.httpBody = Data("state-changing-body".utf8)
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: original)
        defer {
            task.cancel()
            session.invalidateAndCancel()
        }
        let cases = [
            (307, "http://192.168.1.20:8443/v1/requests"),
            (307, "https://8.8.8.8:8443/v1/requests"),
            (307, "https://192.168.1.21:8443/v1/requests"),
            (308, "http://192.168.1.20:8443/v1/requests"),
            (308, "https://8.8.8.8:8443/v1/requests"),
            (308, "https://192.168.1.21:8443/v1/requests"),
        ]

        for (status, destination) in cases {
            var proposed = URLRequest(url: try XCTUnwrap(URL(string: destination)))
            proposed.httpMethod = "POST"
            proposed.httpBody = Data("state-changing-body".utf8)
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(original.url),
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Location": destination]
                )
            )
            let capture = RedirectCapture()

            delegate.urlSession(
                session,
                task: task,
                willPerformHTTPRedirection: response,
                newRequest: proposed
            ) { redirectedRequest in
                capture.record(redirectedRequest)
            }

            let result = capture.snapshot()
            XCTAssertEqual(result.callCount, 1, "status=\(status), destination=\(destination)")
            XCTAssertNil(result.request, "status=\(status), destination=\(destination)")
            XCTAssertEqual(proposed.httpMethod, "POST")
            XCTAssertEqual(proposed.httpBody, Data("state-changing-body".utf8))
        }
    }

    func testPinnedDelegateTaskConformanceStopsRegisteredSessionFromFollowing307And308POSTRedirects() async throws {
        let delegate = try PinnedCertificateDelegate(
            fingerprint: String(repeating: "00", count: 32)
        )
        let taskDelegate: any URLSessionTaskDelegate = delegate
        XCTAssertTrue(taskDelegate is PinnedCertificateDelegate)

        let originalURL = try XCTUnwrap(
            URL(string: "https://192.168.1.20:8443/v1/requests")
        )
        let cases = [
            (307, "http://192.168.1.20:8443/v1/requests"),
            (307, "https://8.8.8.8:8443/v1/requests"),
            (307, "https://192.168.1.21:8443/v1/requests"),
            (308, "http://192.168.1.20:8443/v1/requests"),
            (308, "https://8.8.8.8:8443/v1/requests"),
            (308, "https://192.168.1.21:8443/v1/requests"),
        ]

        for (status, destination) in cases {
            RedirectingURLProtocol.reset(
                statusCode: status,
                redirectURL: try XCTUnwrap(URL(string: destination))
            )
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [RedirectingURLProtocol.self]
            let session = URLSession(
                configuration: configuration,
                delegate: delegate,
                delegateQueue: nil
            )
            defer { session.invalidateAndCancel() }
            var request = URLRequest(url: originalURL)
            request.httpMethod = "POST"
            request.httpBody = Data("state-changing-body".utf8)

            _ = try? await session.data(for: request)

            let requests = RedirectingURLProtocol.recordedRequests()
            XCTAssertEqual(requests.count, 1, "status=\(status), destination=\(destination)")
            XCTAssertEqual(requests.first?.url, originalURL)
            XCTAssertEqual(requests.first?.httpMethod, "POST")
            XCTAssertEqual(requests.first?.httpBody, Data("state-changing-body".utf8))
        }
    }

    func testClientRejectsHTTPAndPublicBridgeURLsBeforeTransport() throws {
        let transport = RecordingTransport(results: [])
        let credentials = try makeCredentials()

        XCTAssertThrowsError(
            try BridgeClient(
                baseURL: XCTUnwrap(URL(string: "http://192.168.1.20:8443")),
                credentials: credentials,
                transport: transport
            )
        )
        XCTAssertThrowsError(
            try BridgeClient(
                baseURL: XCTUnwrap(URL(string: "https://8.8.8.8:8443")),
                credentials: credentials,
                transport: transport
            )
        )
        XCTAssertThrowsError(
            try BridgeClient(
                baseURL: XCTUnwrap(URL(string: "https://2130706433:8443")),
                credentials: credentials,
                transport: transport
            )
        )
        XCTAssertThrowsError(
            try BridgeClient(
                baseURL: XCTUnwrap(URL(string: "https://0x7f000001:8443")),
                credentials: credentials,
                transport: transport
            )
        )
        XCTAssertThrowsError(
            try BridgeClient(
                baseURL: XCTUnwrap(URL(string: "https://[2001:4860:4860::8888]:8443")),
                credentials: credentials,
                transport: transport
            )
        )
    }

    func testProductionClientTransportFactoryReceivesStoredCertificatePin() throws {
        let transport = RecordingTransport(results: [])
        let factory = RecordingPinnedTransportFactory(transport: transport)
        let credentials = try makeCredentials()

        _ = try BridgeClient(
            baseURL: XCTUnwrap(URL(string: "https://192.168.1.20:8443")),
            credentials: credentials,
            transportFactory: factory
        )

        XCTAssertEqual(factory.fingerprints, [credentials.certificateFingerprint])
    }

    func testSubmitConstructsRequestsEndpointAndSignedEnvelope() async throws {
        let request = try makeRequest(kind: .tool, payload: ["tool": .string("set_volume")])
        let transport = RecordingTransport(results: [
            .success(try responseResult(for: request.requestID)),
        ])
        let client = try BridgeClient(
            baseURL: XCTUnwrap(URL(string: "https://192.168.1.20:8443")),
            credentials: makeCredentials(),
            transport: transport
        )

        _ = try await client.submit(request)

        let recordedRequests = await transport.recordedRequests()
        let sent = try XCTUnwrap(recordedRequests.first)
        XCTAssertEqual(sent.url?.absoluteString, "https://192.168.1.20:8443/v1/requests")
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(sent.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["request", "signature"]))
        let signature = try XCTUnwrap(object["signature"] as? String)
        XCTAssertNoThrow(try RequestSigner.validate(signature: signature))
    }

    func testSubmitEnvelopeEmbedsTheExactCanonicalBytesUsedByTheSignature() async throws {
        let request = try BridgeRequest(
            version: 1,
            requestID: "req-numbers",
            deviceID: "iphone-1",
            issuedAt: "2026-08-28T00:00:00Z",
            idempotencyKey: "idem-numbers",
            kind: .chat,
            payload: [
                "numbers": .object([
                    "one": .double(1.0),
                    "decimal": .double(12.5),
                    "large": .double(1e20),
                    "small": .double(1e-7),
                    "negative_zero": .double(-0.0),
                ]),
            ]
        )
        let transport = RecordingTransport(results: [
            .success(try responseResult(for: request.requestID)),
        ])
        let client = try BridgeClient(
            baseURL: XCTUnwrap(URL(string: "https://192.168.1.20:8443")),
            credentials: makeCredentials(),
            transport: transport
        )
        let canonical = try request.canonicalData()
        let signature = try RequestSigner.signature(
            for: request,
            secret: Data("0123456789abcdef0123456789abcdef".utf8)
        )
        _ = try await client.submit(request)
        let body = try XCTUnwrap((await transport.recordedRequests()).first?.httpBody)
        let requestPrefix = Data(#"{"request":"#.utf8)
        let signaturePrefix = Data(",\"signature\":\"".utf8)
        let signatureSuffix = Data(#""}"#.utf8)
        let signatureStart = try XCTUnwrap(body.range(of: signaturePrefix))
        let requestBytes = Data(body[requestPrefix.count ..< signatureStart.lowerBound])
        let signatureBytes = Data(
            body[signatureStart.upperBound ..< body.index(body.endIndex, offsetBy: -signatureSuffix.count)]
        )

        XCTAssertEqual(requestBytes, canonical)
        XCTAssertEqual(String(decoding: signatureBytes, as: UTF8.self), signature)
        XCTAssertEqual(canonical, Data(Fixtures.numberCanonicalJSON.utf8))
    }

    func testStateChangingTimeoutSendsExactlyOnceAndReturnsResultUnknown() async throws {
        let request = try makeRequest(kind: .tool, payload: ["tool": .string("set_volume")])
        let transport = RecordingTransport(results: [
            .failure(URLError(.timedOut)),
            .success(try responseResult(for: request.requestID)),
        ])
        let client = try BridgeClient(
            baseURL: XCTUnwrap(URL(string: "https://192.168.1.20:8443")),
            credentials: makeCredentials(),
            transport: transport,
            retryPolicy: .safeReadsOnly(maxAttempts: 2)
        )

        do {
            _ = try await client.submit(request)
            XCTFail("A timed-out state-changing request must be resultUnknown")
        } catch {
            XCTAssertEqual(error as? BridgeError, .resultUnknown)
        }
        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testReadOnlyStatusRetriesAReplaySafeTimeout() async throws {
        let authentication = try makeRequest(
            requestID: "status-1",
            idempotencyKey: "status-idem-1",
            kind: .chat,
            payload: ["target_request_id": .string("req-1")]
        )
        let transport = RecordingTransport(results: [
            .failure(URLError(.timedOut)),
            .success(try responseResult(for: "req-1")),
        ])
        let client = try BridgeClient(
            baseURL: XCTUnwrap(URL(string: "https://192.168.1.20:8443")),
            credentials: makeCredentials(),
            transport: transport,
            retryPolicy: .safeReadsOnly(maxAttempts: 2)
        )

        let response = try await client.status(for: "req-1", authentication: authentication)

        XCTAssertEqual(response.requestID, "req-1")
        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 2)
        let sent = await transport.recordedRequests()
        XCTAssertTrue(sent.allSatisfy { $0.httpMethod == "GET" })
    }

    func testPairingUsesQRPinAndPersistsOnlyAfterValidResponse() async throws {
        let security = FakeSecurityItemAccess()
        let store = KeychainDeviceStore(service: "test.jarvis", security: security)
        let body = Data(#"{"version":1,"device_id":"paired-iphone","device_secret":"MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY="}"#.utf8)
        let transport = RecordingTransport(results: [
            .success((body, try httpResponse(status: 201))),
        ])
        let factory = RecordingPinnedTransportFactory(transport: transport)
        let payload = try makePairingPayload()

        let credentials = try await BridgeClient.claimPairing(
            payload,
            deviceName: "Alice's iPhone",
            store: store,
            transportFactory: factory
        )

        XCTAssertEqual(factory.fingerprints, [String(repeating: "ab", count: 32)])
        XCTAssertEqual(credentials, try store.load())
        XCTAssertEqual(credentials.secret.count, 32)
        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testPairingDoesNotPersistMalformedCredentialResponse() async throws {
        let security = FakeSecurityItemAccess()
        let store = KeychainDeviceStore(service: "test.jarvis", security: security)
        let body = Data(#"{"version":1,"device_id":"paired-iphone","device_secret":"dG9vLXNob3J0"}"#.utf8)
        let transport = RecordingTransport(results: [
            .success((body, try httpResponse(status: 201))),
        ])
        let factory = RecordingPinnedTransportFactory(transport: transport)

        do {
            _ = try await BridgeClient.claimPairing(
                makePairingPayload(),
                deviceName: "Alice's iPhone",
                store: store,
                transportFactory: factory
            )
            XCTFail("Malformed pairing credentials must be rejected")
        } catch {
            XCTAssertEqual(error as? BridgeError, .invalidPairingResponse)
        }
        XCTAssertNil(try store.load())
        XCTAssertTrue(security.addedItems.isEmpty)
    }

    func testPairingRejectsUnknownTopLevelPairClaimResponseField() async throws {
        let security = FakeSecurityItemAccess()
        let store = KeychainDeviceStore(service: "test.jarvis", security: security)
        let body = Data(#"{"version":1,"device_id":"paired-iphone","device_secret":"MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=","unexpected":true}"#.utf8)
        let transport = RecordingTransport(results: [
            .success((body, try httpResponse(status: 201))),
        ])
        let factory = RecordingPinnedTransportFactory(transport: transport)

        do {
            _ = try await BridgeClient.claimPairing(
                makePairingPayload(),
                deviceName: "Alice's iPhone",
                store: store,
                transportFactory: factory
            )
            XCTFail("Pair claim responses with unknown top-level fields must be rejected")
        } catch {
            XCTAssertEqual(error as? BridgeError, .invalidPairingResponse)
        }
        XCTAssertNil(try store.load())
        XCTAssertTrue(security.addedItems.isEmpty)
    }

    func testConfirmationAndCancellationBindOwnerTargetAndServerPath() async throws {
        let transport = RecordingTransport(results: [
            .success(try responseResult(for: "req-1", state: "completed")),
            .success(try responseResult(for: "req-1", state: "cancelled")),
        ])
        let client = try BridgeClient(
            baseURL: XCTUnwrap(URL(string: "https://192.168.1.20:8443")),
            credentials: makeCredentials(),
            transport: transport
        )
        let confirmation = try makeRequest(
            requestID: "confirm-1",
            idempotencyKey: "confirm-idem-1",
            kind: .confirm,
            payload: ["target_request_id": .string("req-1")]
        )
        let cancellation = try makeRequest(
            requestID: "cancel-1",
            idempotencyKey: "cancel-idem-1",
            kind: .cancel,
            payload: ["target_request_id": .string("req-1")]
        )

        _ = try await client.confirm("req-1", confirmation: confirmation)
        _ = try await client.cancel("req-1", cancellation: cancellation)

        let sent = await transport.recordedRequests()
        XCTAssertEqual(sent.count, 2)
        XCTAssertTrue(sent.allSatisfy {
            $0.url?.absoluteString == "https://192.168.1.20:8443/v1/tasks/req-1/confirm"
                && $0.httpMethod == "POST"
        })

        let wrongOwner = try BridgeRequest(
            version: 1,
            requestID: "confirm-2",
            deviceID: "other-device",
            issuedAt: "2026-08-28T00:00:00Z",
            idempotencyKey: "confirm-idem-2",
            kind: .confirm,
            payload: ["target_request_id": .string("req-1")]
        )
        do {
            _ = try await client.confirm("req-1", confirmation: wrongOwner)
            XCTFail("Only the paired device may confirm its task")
        } catch {
            XCTAssertEqual(error as? BridgeError, .requestOwnershipMismatch)
        }

        let wrongTarget = try makeRequest(
            requestID: "confirm-3",
            idempotencyKey: "confirm-idem-3",
            kind: .confirm,
            payload: ["target_request_id": .string("req-2")]
        )
        do {
            _ = try await client.confirm("req-1", confirmation: wrongTarget)
            XCTFail("The signed target must match the task path")
        } catch {
            XCTAssertEqual(error as? BridgeError, .requestTargetMismatch)
        }

        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 2)
    }
}

private extension BridgeClientTests {
    func makeCredentials() throws -> DeviceCredentials {
        try DeviceCredentials(
            deviceID: "iphone-1",
            secret: Data("0123456789abcdef0123456789abcdef".utf8),
            certificateFingerprint: String(repeating: "ab", count: 32)
        )
    }

    func makeRequest(
        requestID: String = "req-1",
        idempotencyKey: String = "idem-1",
        kind: RequestKind,
        payload: [String: JSONValue]
    ) throws -> BridgeRequest {
        try BridgeRequest(
            version: 1,
            requestID: requestID,
            deviceID: "iphone-1",
            issuedAt: "2026-08-28T00:00:00Z",
            idempotencyKey: idempotencyKey,
            kind: kind,
            payload: payload
        )
    }

    func makePairingPayload() throws -> PairingPayload {
        try PairingPayload(
            version: 1,
            bridgeID: "bridge-1",
            bridgeURL: "https://192.168.1.20:8443",
            certificateFingerprint: String(repeating: "ab", count: 32),
            sessionID: "session-1",
            expiresAt: "2026-08-28T00:02:00+00:00",
            proof: "one-time-proof"
        )
    }

    func responseResult(
        for requestID: String,
        state: String = "completed"
    ) throws -> (Data, HTTPURLResponse) {
        let data = Data(
            "{\"version\":1,\"request_id\":\"\(requestID)\",\"state\":\"\(state)\",\"risk\":\"low\",\"payload\":{}}".utf8
        )
        return (data, try httpResponse(status: 200))
    }

    func httpResponse(status: Int) throws -> HTTPURLResponse {
        try XCTUnwrap(
            HTTPURLResponse(
                url: XCTUnwrap(URL(string: "https://192.168.1.20:8443")),
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )
        )
    }
}

private final class FakeSecurityItemAccess: SecurityItemAccess, @unchecked Sendable {
    private var values: [String: Data] = [:]
    private(set) var addedItems: [KeychainItem] = []
    private(set) var updatedItems: [KeychainItem] = []
    private(set) var deletedAccounts: [String] = []

    func add(_ item: KeychainItem) -> OSStatus {
        guard values[item.account] == nil else { return errSecDuplicateItem }
        values[item.account] = item.value
        addedItems.append(item)
        return errSecSuccess
    }

    func copy(service: String, account: String) -> (OSStatus, Data?) {
        guard let value = values[account] else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, value)
    }

    func update(_ item: KeychainItem) -> OSStatus {
        guard values[item.account] != nil else { return errSecItemNotFound }
        values[item.account] = item.value
        updatedItems.append(item)
        return errSecSuccess
    }

    func delete(service: String, account: String) -> OSStatus {
        deletedAccounts.append(account)
        guard values.removeValue(forKey: account) != nil else { return errSecItemNotFound }
        return errSecSuccess
    }
}

private actor RecordingTransport: BridgeTransport {
    private var results: [Result<(Data, HTTPURLResponse), Error>]
    private var requests: [URLRequest] = []

    init(results: [Result<(Data, HTTPURLResponse), Error>]) {
        self.results = results
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !results.isEmpty else { throw URLError(.badServerResponse) }
        return try results.removeFirst().get()
    }

    func requestCount() -> Int { requests.count }
    func recordedRequests() -> [URLRequest] { requests }
}

private final class RecordingPinnedTransportFactory: PinnedTransportFactory, @unchecked Sendable {
    private let transport: any BridgeTransport
    private(set) var fingerprints: [String] = []

    init(transport: any BridgeTransport) {
        self.transport = transport
    }

    func makeTransport(certificateFingerprint: String) throws -> any BridgeTransport {
        fingerprints.append(certificateFingerprint)
        return transport
    }
}

private final class RedirectCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0
    private var request: URLRequest?

    func record(_ request: URLRequest?) {
        lock.lock()
        defer { lock.unlock() }
        callCount += 1
        self.request = request
    }

    func snapshot() -> (callCount: Int, request: URLRequest?) {
        lock.lock()
        defer { lock.unlock() }
        return (callCount, request)
    }
}

private final class RedirectingURLProtocol: URLProtocol, @unchecked Sendable {
    private static let capture = RedirectRequestCapture()

    override class func canInit(with request: URLRequest) -> Bool {
        guard let scheme = request.url?.scheme?.lowercased() else { return false }
        return scheme == "https" || scheme == "http"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.capture.record(request)
        guard
            let sourceURL = request.url,
            let configuration = Self.capture.configuration()
        else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        var redirectedRequest = URLRequest(url: configuration.redirectURL)
        redirectedRequest.httpMethod = request.httpMethod
        redirectedRequest.httpBody = request.httpBody
        let response = HTTPURLResponse(
            url: sourceURL,
            statusCode: configuration.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": configuration.redirectURL.absoluteString]
        )
        if let response {
            client?.urlProtocol(
                self,
                wasRedirectedTo: redirectedRequest,
                redirectResponse: response
            )
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func reset(statusCode: Int, redirectURL: URL) {
        capture.reset(statusCode: statusCode, redirectURL: redirectURL)
    }

    static func recordedRequests() -> [URLRequest] {
        capture.requests()
    }
}

private final class RedirectRequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var statusCode: Int?
    private var redirectURL: URL?
    private var requests: [URLRequest] = []

    func reset(statusCode: Int, redirectURL: URL) {
        lock.lock()
        defer { lock.unlock() }
        self.statusCode = statusCode
        self.redirectURL = redirectURL
        requests = []
    }

    func record(_ request: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
    }

    func configuration() -> (statusCode: Int, redirectURL: URL)? {
        lock.lock()
        defer { lock.unlock() }
        guard let statusCode, let redirectURL else { return nil }
        return (statusCode, redirectURL)
    }

    func requests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}
