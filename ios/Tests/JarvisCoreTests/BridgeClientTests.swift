import Foundation
import Security
import XCTest
@testable import JarvisCore
@testable import JarvisProtocol

@MainActor
final class BridgeClientTests: XCTestCase {
    func testKeychainSaveAndLoadPersistOnlyIdentityAndSecret() throws {
        let security = FakeSecurityItemAccess()
        let store = KeychainDeviceStore(service: "test.jarvis", security: security)
        let credentials = try makeCredentials()

        try store.save(credentials)

        XCTAssertEqual(try store.load(), credentials)
        XCTAssertEqual(security.addedItems.count, 2)
        XCTAssertEqual(
            Set(security.addedItems.map(\.account)),
            Set(KeychainDeviceStore.credentialAccounts)
        )
        XCTAssertTrue(security.addedItems.allSatisfy { item in
            item.itemClass == .genericPassword
                && item.accessibility == .afterFirstUnlockThisDeviceOnly
        })
    }

    func testKeychainDuplicateSaveUpdatesIdentityAndSecretOnly() throws {
        let security = FakeSecurityItemAccess()
        let store = KeychainDeviceStore(service: "test.jarvis", security: security)
        let first = try makeCredentials(deviceID: "iphone-1", secretByte: 1)
        let second = try makeCredentials(deviceID: "iphone-2", secretByte: 2)

        try store.save(first)
        try store.save(second)

        XCTAssertEqual(try store.load(), second)
        XCTAssertEqual(security.updatedItems.count, 2)
        XCTAssertEqual(
            Set(security.updatedItems.map(\.account)),
            Set(KeychainDeviceStore.credentialAccounts)
        )
    }

    func testKeychainDeleteRemovesAllStoredCredentialFields() throws {
        let security = FakeSecurityItemAccess()
        let store = KeychainDeviceStore(service: "test.jarvis", security: security)

        try store.save(makeCredentials())
        try store.delete()

        XCTAssertNil(try store.load())
        XCTAssertEqual(Set(security.deletedAccounts), Set(KeychainDeviceStore.credentialAccounts))
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

    func testProductionClientUsesEndpointCertificatePinAndStartsPaired() async throws {
        let transport = RecordingTransport(results: [])
        let factory = RecordingPinnedTransportFactory(transport: transport)
        let discovery = try makeDiscoveryMessage()
        let client = try BridgeClient(
            endpoint: .discovered(discovery),
            credentials: makeCredentials(),
            transportFactory: factory
        )

        XCTAssertEqual(factory.fingerprints, [discovery.certificateFingerprint])
        let state = await client.connectionState()
        XCTAssertEqual(state, .paired(endpoint: .discovered(discovery), deviceID: "iphone-1"))
    }

    func testClientRejectsHTTPAndPublicManualEndpointsBeforeTransport() throws {
        let transport = RecordingTransport(results: [])
        let credentials = try makeCredentials()

        XCTAssertThrowsError(
            try BridgeClient(
                endpoint: .manual(
                    baseURL: XCTUnwrap(URL(string: "http://192.168.1.20:8443")),
                    certificateFingerprint: String(repeating: "ab", count: 32)
                ),
                credentials: credentials,
                transport: transport
            )
        )
        XCTAssertThrowsError(
            try BridgeClient(
                endpoint: .manual(
                    baseURL: XCTUnwrap(URL(string: "https://8.8.8.8:8443")),
                    certificateFingerprint: String(repeating: "ab", count: 32)
                ),
                credentials: credentials,
                transport: transport
            )
        )
    }

    func testSubmitConstructsRequestsEndpointAndSignedEnvelope() async throws {
        let request = try makeRequest(kind: .tool, payload: ["tool": .string("set_volume")])
        let transport = RecordingTransport(results: [
            .success(try previewResponse(for: request.requestID)),
        ])
        let endpoint = try manualEndpoint()
        let client = try BridgeClient(
            endpoint: endpoint,
            credentials: makeCredentials(),
            transport: transport
        )

        let response = try await client.submit(request)

        XCTAssertEqual(response.state, .awaitingConfirmation)
        let recordedRequests = await transport.recordedRequests()
        let sent = try XCTUnwrap(recordedRequests.first)
        XCTAssertEqual(sent.url?.absoluteString, "https://192.168.1.20:8443/v1/requests")
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(sent.httpBody)
        let envelope = try JSONDecoder().decode(SignedRequestEnvelope.self, from: body)
        XCTAssertEqual(envelope.request, request)
        XCTAssertNoThrow(try RequestSigner.validate(signature: envelope.signature))
        let state = await client.connectionState()
        XCTAssertEqual(state, .connected(endpoint: endpoint, deviceID: "iphone-1"))
    }

    func testStateChangingDisconnectDoesNotRetryAndMarksDisconnected() async throws {
        let request = try makeRequest(kind: .tool, payload: ["tool": .string("set_volume")])
        let endpoint = try manualEndpoint()
        let transport = RecordingTransport(results: [
            .failure(URLError(.networkConnectionLost)),
            .success(try terminalResponse(for: request.requestID, state: .completed)),
        ])
        let client = try BridgeClient(
            endpoint: endpoint,
            credentials: makeCredentials(),
            transport: transport
        )

        do {
            _ = try await client.submit(request)
            XCTFail("State-changing transport loss must remain unknown")
        } catch {
            XCTAssertEqual(error as? BridgeError, .resultUnknown)
        }
        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 1)
        let state = await client.connectionState()
        XCTAssertEqual(state, .disconnected(endpoint: endpoint, deviceID: "iphone-1", canRetryReads: true))
    }

    func testReadOnlyStatusRetriesAfterDisconnectAndReconnects() async throws {
        let authentication = try makeRequest(
            requestID: "status-1",
            idempotencyKey: "status-idem-1",
            kind: .chat,
            payload: ["target_request_id": .string("req-1")]
        )
        let endpoint = try manualEndpoint()
        let transport = RecordingTransport(results: [
            .failure(URLError(.timedOut)),
            .success(try terminalResponse(for: "req-1", state: .completed)),
        ])
        let client = try BridgeClient(
            endpoint: endpoint,
            credentials: makeCredentials(),
            transport: transport,
            retryPolicy: .safeReadsOnly(maxAttempts: 2)
        )

        let response = try await client.status(for: "req-1", authentication: authentication)

        XCTAssertEqual(response.requestID, "req-1")
        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 2)
        let state = await client.connectionState()
        XCTAssertEqual(state, .connected(endpoint: endpoint, deviceID: "iphone-1"))
    }

    func testPairingChallengeExchangePersistsOnlyIdentityAndSecretAfterValidFreshResponse() async throws {
        let security = FakeSecurityItemAccess()
        let store = KeychainDeviceStore(service: "test.jarvis", security: security)
        let body = Data(#"{"version":1,"device_id":"iphone-1","device_public_key":"cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd","device_secret":"MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY="}"#.utf8)
        let transport = RecordingTransport(results: [
            .success((body, try httpResponse(status: 201))),
        ])
        let factory = RecordingPinnedTransportFactory(transport: transport)
        let challenge = try makePairingChallenge()
        let response = try makePairingChallengeResponse()
        let discovery = try makeDiscoveryMessage()

        let credentials = try await BridgeClient.completePairing(
            challenge: challenge,
            response: response,
            endpoint: .discovered(discovery),
            store: store,
            now: try freshNow(),
            transportFactory: factory
        )

        XCTAssertEqual(factory.fingerprints, [discovery.certificateFingerprint])
        XCTAssertEqual(credentials, try store.load())
        XCTAssertEqual(security.addedItems.count, 2)
        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 1)
        let recordedRequests = await transport.recordedRequests()
        let sent = try XCTUnwrap(recordedRequests.first)
        XCTAssertEqual(sent.url?.path, "/v1/pair/claim")
        let claim = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(sent.httpBody)) as? [String: String]
        )
        XCTAssertEqual(
            claim,
            [
                "session_id": "session-1",
                "device_name": "Alice's iPhone",
                "proof": "pairing-proof",
                "device_public_key": String(repeating: "cd", count: 32),
            ]
        )
    }

    func testPairingRejectsStaleChallengeBeforePersistingOrSending() async throws {
        let security = FakeSecurityItemAccess()
        let store = KeychainDeviceStore(service: "test.jarvis", security: security)
        let transport = RecordingTransport(results: [])
        let factory = RecordingPinnedTransportFactory(transport: transport)

        do {
            _ = try await BridgeClient.completePairing(
                challenge: try stalePairingChallenge(),
                response: try makePairingChallengeResponse(),
                endpoint: .discovered(try makeDiscoveryMessage()),
                store: store,
                now: try freshNow(),
                transportFactory: factory
            )
            XCTFail("Stale pairing challenges must be rejected")
        } catch {
            XCTAssertEqual(error as? BridgeProtocolError, .staleMessage(field: "expires_at"))
        }
        XCTAssertNil(try store.load())
        XCTAssertTrue(security.addedItems.isEmpty)
        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 0)
    }

    func testPairingAcceptsServerIssuedDeviceIdentity() async throws {
        let security = FakeSecurityItemAccess()
        let store = KeychainDeviceStore(service: "test.jarvis", security: security)
        let body = Data(#"{"version":1,"device_id":"other-device","device_public_key":"cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd","device_secret":"MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY="}"#.utf8)
        let transport = RecordingTransport(results: [
            .success((body, try httpResponse(status: 201))),
        ])

        let credentials = try await BridgeClient.completePairing(
            challenge: try makePairingChallenge(),
            response: try makePairingChallengeResponse(),
            endpoint: .discovered(try makeDiscoveryMessage()),
            store: store,
            now: try freshNow(),
            transportFactory: RecordingPinnedTransportFactory(transport: transport)
        )

        XCTAssertEqual(credentials.deviceID, "other-device")
        XCTAssertEqual(credentials, try store.load())
    }

    func testPairingRejectsReturnedCredentialPublicKeyMismatchBeforePersisting() async throws {
        let security = FakeSecurityItemAccess()
        let store = KeychainDeviceStore(service: "test.jarvis", security: security)
        let body = Data(#"{"version":1,"device_id":"iphone-1","device_public_key":"abababababababababababababababababababababababababababababababab","device_secret":"MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY="}"#.utf8)
        let transport = RecordingTransport(results: [
            .success((body, try httpResponse(status: 201))),
        ])

        do {
            _ = try await BridgeClient.completePairing(
                challenge: try makePairingChallenge(),
                response: try makePairingChallengeResponse(),
                endpoint: .discovered(try makeDiscoveryMessage()),
                store: store,
                now: try freshNow(),
                transportFactory: RecordingPinnedTransportFactory(transport: transport)
            )
            XCTFail("Mismatched returned public key bindings must be rejected")
        } catch {
            XCTAssertEqual(error as? BridgeError, .invalidPairingResponse)
        }
        XCTAssertNil(try store.load())
        XCTAssertTrue(security.addedItems.isEmpty)
    }

    func testSubmitDecodesInvalidSignatureRejection() async throws {
        let request = try makeRequest(kind: .tool, payload: ["tool": .string("set_volume")])
        let rejection = try rejectionData(
            for: request.requestID,
            reason: .invalidSignature,
            message: "Signature mismatch"
        )
        let client = try BridgeClient(
            endpoint: try manualEndpoint(),
            credentials: makeCredentials(),
            transport: RecordingTransport(results: [
                .success((rejection, try httpResponse(status: 401))),
            ])
        )

        do {
            _ = try await client.submit(request)
            XCTFail("Invalid signatures must surface as explicit rejections")
        } catch let BridgeError.requestRejected(details) {
            XCTAssertEqual(details.reason, .invalidSignature)
            XCTAssertEqual(details.message, "Signature mismatch")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSubmitDecodesDuplicateRequestIDRejection() async throws {
        let request = try makeRequest(kind: .chat, payload: ["text": .string("hello")])
        let rejection = try rejectionData(
            for: request.requestID,
            reason: .duplicateRequest,
            message: "Already processed"
        )
        let client = try BridgeClient(
            endpoint: try manualEndpoint(),
            credentials: makeCredentials(),
            transport: RecordingTransport(results: [
                .success((rejection, try httpResponse(status: 409))),
            ])
        )

        do {
            _ = try await client.submit(request)
            XCTFail("Duplicate request IDs must surface as explicit rejections")
        } catch let BridgeError.requestRejected(details) {
            XCTAssertEqual(details.reason, .duplicateRequest)
            XCTAssertFalse(details.retryable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDecodeEventMapsProgressTerminalAndRejectionMessages() throws {
        let progress = try BridgeClient.decodeEvent(
            Data(#"{"version":1,"request_id":"req-1","task_id":"task-1","state":"executing","progress_message":"Working","event_index":2}"#.utf8)
        )
        let terminal = try BridgeClient.decodeEvent(
            Data(#"{"version":1,"request_id":"req-1","task_id":"task-1","state":"completed","summary":"Done","output":{"ok":true}}"#.utf8)
        )
        let rejection = try BridgeClient.decodeEvent(
            Data(#"{"version":1,"request_id":"req-1","task_id":"task-1","reason":"duplicate_request","message":"Already processed","retryable":false}"#.utf8)
        )

        XCTAssertEqual(
            progress,
            .progress(
                try TaskProgress(
                    version: 1,
                    requestID: "req-1",
                    taskID: "task-1",
                    state: .executing,
                    progressMessage: "Working",
                    eventIndex: 2
                )
            )
        )
        XCTAssertEqual(
            terminal,
            .terminal(
                try TaskTerminalResult(
                    version: 1,
                    requestID: "req-1",
                    taskID: "task-1",
                    state: .completed,
                    summary: "Done",
                    output: ["ok": .bool(true)]
                )
            )
        )
        XCTAssertEqual(
            rejection,
            .rejection(
                try TaskRejection(
                    version: 1,
                    requestID: "req-1",
                    taskID: "task-1",
                    reason: .duplicateRequest,
                    message: "Already processed",
                    retryable: false
                )
            )
        )
    }

    func testReadOnlyHTTPFailureReturnsToPairedState() async throws {
        let endpoint = try manualEndpoint()
        let client = try BridgeClient(
            endpoint: endpoint,
            credentials: makeCredentials(),
            transport: RecordingTransport(results: [
                .success((Data("{}".utf8), try httpResponse(status: 503))),
            ])
        )
        let authentication = try makeRequest(
            requestID: "status-503",
            idempotencyKey: "status-idem-503",
            kind: .chat,
            payload: ["target_request_id": .string("req-503")]
        )

        do {
            _ = try await client.status(for: "req-503", authentication: authentication)
            XCTFail("HTTP read failures must be surfaced")
        } catch {
            XCTAssertEqual(error as? BridgeError, .httpStatus(503))
        }
        let state = await client.connectionState()
        XCTAssertEqual(state, .paired(endpoint: endpoint, deviceID: "iphone-1"))
    }

    func testReadOnlyProtocolFailureReturnsToPairedState() async throws {
        let endpoint = try manualEndpoint()
        let client = try BridgeClient(
            endpoint: endpoint,
            credentials: makeCredentials(),
            transport: RecordingTransport(results: [
                .success((Data(#"{"version":1}"#.utf8), try httpResponse(status: 200))),
            ])
        )
        let authentication = try makeRequest(
            requestID: "status-invalid",
            idempotencyKey: "status-idem-invalid",
            kind: .chat,
            payload: ["target_request_id": .string("req-invalid")]
        )

        do {
            _ = try await client.status(for: "req-invalid", authentication: authentication)
            XCTFail("Protocol read failures must be surfaced")
        } catch {
            XCTAssertEqual(error as? BridgeError, .invalidProtocolResponse)
        }
        let state = await client.connectionState()
        XCTAssertEqual(state, .paired(endpoint: endpoint, deviceID: "iphone-1"))
    }

    func testConfirmationAndCancellationSerializeTaskConfirmationPayload() async throws {
        let transport = RecordingTransport(results: [
            .success(try terminalResponse(for: "req-1", state: .completed)),
            .success(try terminalResponse(for: "req-1", state: .cancelled)),
        ])
        let client = try BridgeClient(
            endpoint: try manualEndpoint(),
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

        let confirmed = try await client.confirm("req-1", confirmation: confirmation)
        let cancelled = try await client.cancel("req-1", cancellation: cancellation)

        XCTAssertEqual(confirmed.state, .completed)
        XCTAssertEqual(cancelled.state, .cancelled)
        let sent = await transport.recordedRequests()
        XCTAssertEqual(sent.count, 2)
        XCTAssertTrue(sent.allSatisfy {
            $0.url?.absoluteString == "https://192.168.1.20:8443/v1/tasks/req-1/confirm"
                && $0.httpMethod == "POST"
        })
        let confirmationEnvelope = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: try XCTUnwrap(sent[0].httpBody)) as? [String: Any]
        )
        let cancellationEnvelope = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: try XCTUnwrap(sent[1].httpBody)) as? [String: Any]
        )
        let approved = try XCTUnwrap(confirmationEnvelope["confirmation"] as? [String: Any])
        let declined = try XCTUnwrap(cancellationEnvelope["confirmation"] as? [String: Any])
        let approvalSignature = try XCTUnwrap(confirmationEnvelope["signature"] as? String)
        let declineSignature = try XCTUnwrap(cancellationEnvelope["signature"] as? String)
        XCTAssertEqual(approved["decision"] as? String, "approve")
        XCTAssertEqual(declined["decision"] as? String, "decline")
        XCTAssertEqual(approved["task_id"] as? String, "req-1")
        XCTAssertEqual(declined["task_id"] as? String, "req-1")
        let approvedTimestamp = try XCTUnwrap(approved["decided_at"] as? String)
        let declinedTimestamp = try XCTUnwrap(declined["decided_at"] as? String)
        let approvedConfirmation = try TaskConfirmation(
            version: 1,
            requestID: "confirm-1",
            taskID: "req-1",
            decision: .approve,
            decidedAt: approvedTimestamp
        )
        let declinedConfirmation = try TaskConfirmation(
            version: 1,
            requestID: "cancel-1",
            taskID: "req-1",
            decision: .decline,
            decidedAt: declinedTimestamp
        )
        XCTAssertEqual(
            approvalSignature,
            try RequestSigner.signature(
                for: confirmation,
                confirmation: approvedConfirmation,
                secret: makeCredentials().secret
            )
        )
        XCTAssertEqual(
            declineSignature,
            try RequestSigner.signature(
                for: cancellation,
                confirmation: declinedConfirmation,
                secret: makeCredentials().secret
            )
        )
        XCTAssertNotEqual(
            approvalSignature,
            try RequestSigner.signature(for: confirmation, secret: makeCredentials().secret)
        )
        XCTAssertNotEqual(
            declineSignature,
            try RequestSigner.signature(for: cancellation, secret: makeCredentials().secret)
        )
    }
}

private extension BridgeClientTests {
    func makeCredentials(
        deviceID: String = "iphone-1",
        secretByte: UInt8 = 0x30
    ) throws -> DeviceCredentials {
        try DeviceCredentials(
            deviceID: deviceID,
            secret: Data(repeating: secretByte, count: 32)
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

    func makeDiscoveryMessage() throws -> DiscoveryMessage {
        try DiscoveryMessage(
            version: 1,
            bridgeID: "bridge-1",
            bridgeURL: "https://192.168.1.20:8443",
            certificateFingerprint: String(repeating: "ab", count: 32),
            displayName: "Studio PC",
            requiresPairing: true
        )
    }

    func makePairingChallenge() throws -> PairingChallenge {
        try PairingChallenge(
            version: 1,
            sessionID: "session-1",
            bridgeID: "bridge-1",
            pairingCode: "123456",
            challengeNonce: "nonce-1",
            issuedAt: "2026-09-01T00:00:00Z",
            expiresAt: "2026-09-01T00:02:00Z"
        )
    }

    func stalePairingChallenge() throws -> PairingChallenge {
        try PairingChallenge(
            version: 1,
            sessionID: "session-1",
            bridgeID: "bridge-1",
            pairingCode: "123456",
            challengeNonce: "nonce-1",
            issuedAt: "2026-08-31T00:00:00Z",
            expiresAt: "2026-08-31T00:02:00Z"
        )
    }

    func makePairingChallengeResponse() throws -> PairingChallengeResponse {
        try PairingChallengeResponse(
            version: 1,
            sessionID: "session-1",
            bridgeID: "bridge-1",
            deviceName: "Alice's iPhone",
            deviceID: "iphone-1",
            devicePublicKey: String(repeating: "cd", count: 32),
            pairingCode: "123456",
            challengeNonce: "nonce-1",
            issuedAt: "2026-09-01T00:00:10Z",
            expiresAt: "2026-09-01T00:02:00Z",
            proof: "pairing-proof"
        )
    }

    func manualEndpoint() throws -> BridgeEndpoint {
        .manual(
            baseURL: try XCTUnwrap(URL(string: "https://192.168.1.20:8443")),
            certificateFingerprint: String(repeating: "ab", count: 32)
        )
    }

    func previewResponse(for requestID: String) throws -> (Data, HTTPURLResponse) {
        let data = Data(
            #"{"version":1,"request_id":"\#(requestID)","task_id":"task-1","risk":"confirmation_required","title":"Send WeChat","summary":"Needs approval","action":"send_wechat_message","target":"WeChat","arguments":{"contact":"Alice","message":"Hello"}}"#.utf8
        )
        return (data, try httpResponse(status: 202))
    }

    func terminalResponse(
        for requestID: String,
        state: TaskState
    ) throws -> (Data, HTTPURLResponse) {
        let data = Data(
            #"{"version":1,"request_id":"\#(requestID)","task_id":"task-1","state":"\#(state.rawValue)","summary":"Done","output":{}}"#.utf8
        )
        return (data, try httpResponse(status: 200))
    }

    func rejectionData(
        for requestID: String,
        reason: RejectionReason,
        message: String
    ) throws -> Data {
        Data(
            #"{"version":1,"request_id":"\#(requestID)","task_id":"task-1","reason":"\#(reason.rawValue)","message":"\#(message)","retryable":false}"#.utf8
        )
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

    func freshNow() throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-01T00:01:00Z"))
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
