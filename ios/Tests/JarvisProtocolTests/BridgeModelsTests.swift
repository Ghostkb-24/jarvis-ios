import Foundation
import XCTest
@testable import JarvisProtocol

final class BridgeModelsTests: XCTestCase {
    func testDiscoveryMessageUsesExpectedWireFields() throws {
        let message = try DiscoveryMessage(
            version: 1,
            bridgeID: "bridge-1",
            bridgeURL: "https://jarvis.local:8443",
            certificateFingerprint: String(repeating: "ab", count: 32),
            displayName: "Jarvis Desktop",
            requiresPairing: true
        )

        let encoded = try JSONEncoder().encode(message)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        XCTAssertEqual(
            Set(object.keys),
            Set([
                "version",
                "bridge_id",
                "bridge_url",
                "certificate_sha256",
                "display_name",
                "requires_pairing",
            ])
        )
    }

    func testPairingChallengeRoundTrips() throws {
        let challenge = try PairingChallenge(
            version: 1,
            sessionID: "session-1",
            bridgeID: "bridge-1",
            pairingCode: "493821",
            challengeNonce: "nonce-1",
            issuedAt: "2026-09-01T09:00:00Z",
            expiresAt: "2026-09-01T09:05:00Z"
        )

        let data = try JSONEncoder().encode(challenge)
        let decoded = try JSONDecoder().decode(PairingChallenge.self, from: data)

        XCTAssertEqual(decoded, challenge)
    }

    func testPairingPayloadDecodesDesktopQRFixture() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle.module.url(
                forResource: "pairing-payload",
                withExtension: "json",
                subdirectory: "Fixtures"
            )
        )
        let payload = try JSONDecoder().decode(
            PairingPayload.self,
            from: Data(contentsOf: fixtureURL)
        )

        XCTAssertEqual(payload.bridgeID, "jarvis-desktop")
        XCTAssertEqual(payload.sessionID, "session-1")
        XCTAssertEqual(payload.proof, "pairing-proof")
    }

    func testPairingChallengeResponseRejectsUnknownFields() {
        let data = Data(#"{"version":1,"session_id":"session-1","device_name":"iPhone","device_id":"iphone-1","device_public_key":"cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd","pairing_code":"493821","challenge_nonce":"nonce-1","issued_at":"2026-09-01T09:00:00Z","unexpected":true}"#.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(PairingChallengeResponse.self, from: data)) { error in
            XCTAssertEqual(
                error as? BridgeProtocolError,
                .unknownFields(type: "PairingChallengeResponse", fields: ["unexpected"])
            )
        }
    }

    func testPairingChallengeResponseCarriesDeviceIdentityAndKeyBinding() throws {
        let response = try PairingChallengeResponse(
            version: 1,
            sessionID: "session-1",
            bridgeID: "bridge-1",
            deviceName: "iPhone",
            deviceID: "iphone-1",
            devicePublicKey: String(repeating: "cd", count: 32),
            pairingCode: "493821",
            challengeNonce: "nonce-1",
            issuedAt: "2026-09-01T09:00:00Z",
            expiresAt: "2026-09-01T09:05:00Z",
            proof: "pairing-proof"
        )

        XCTAssertEqual(response.deviceID, "iphone-1")
        XCTAssertEqual(response.devicePublicKey, String(repeating: "cd", count: 32))
    }

    func testTaskSubmissionCarriesRequestAndIdempotencyIdentifiers() throws {
        let submission = try TaskSubmission(
            request: Fixtures.openWeChatRequest(),
            expectsConfirmation: true
        )

        XCTAssertEqual(submission.request.requestID, "req-1")
        XCTAssertEqual(submission.request.idempotencyKey, "idem-1")
        XCTAssertTrue(submission.expectsConfirmation)
    }

    func testTaskPreviewRoundTripsExplicitConfirmationPayload() throws {
        let preview = try TaskPreview(
            version: 1,
            requestID: "req-1",
            taskID: "task-1",
            risk: .confirmationRequired,
            title: "Open WeChat",
            summary: "Jarvis will open WeChat on this computer.",
            action: "open_application",
            target: "WeChat",
            arguments: ["name": .string("微信")]
        )

        let data = try JSONEncoder().encode(preview)
        let decoded = try JSONDecoder().decode(TaskPreview.self, from: data)

        XCTAssertEqual(decoded, preview)
    }

    func testTaskConfirmationRequiresExplicitDecision() throws {
        let confirmation = try TaskConfirmation(
            version: 1,
            requestID: "req-1",
            taskID: "task-1",
            decision: .approve,
            decidedAt: "2026-09-01T09:01:00Z"
        )

        XCTAssertEqual(confirmation.decision, .approve)
    }

    func testPairingChallengeFreshnessValidationRejectsStaleMessage() throws {
        let challenge = try PairingChallenge(
            version: 1,
            sessionID: "session-1",
            bridgeID: "bridge-1",
            pairingCode: "493821",
            challengeNonce: "nonce-1",
            issuedAt: "2026-09-01T08:40:00Z",
            expiresAt: "2026-09-01T08:45:00Z"
        )

        XCTAssertThrowsError(
            try challenge.validateFreshness(
                now: Date(timeIntervalSince1970: 1_788_251_400),
                maxAge: 300,
                maxFutureSkew: 30
            )
        ) { error in
            XCTAssertEqual(error as? BridgeProtocolError, .staleMessage(field: "issued_at"))
        }
    }

    func testPairingChallengeResponseFreshnessValidationRejectsStaleMessage() throws {
        let response = try PairingChallengeResponse(
            version: 1,
            sessionID: "session-1",
            bridgeID: "bridge-1",
            deviceName: "iPhone",
            deviceID: "iphone-1",
            devicePublicKey: String(repeating: "cd", count: 32),
            pairingCode: "493821",
            challengeNonce: "nonce-1",
            issuedAt: "2026-09-01T08:40:00Z",
            expiresAt: "2026-09-01T08:45:00Z",
            proof: "pairing-proof"
        )

        XCTAssertThrowsError(
            try response.validateFreshness(
                now: Date(timeIntervalSince1970: 1_788_251_400),
                maxAge: 300,
                maxFutureSkew: 30
            )
        ) { error in
            XCTAssertEqual(error as? BridgeProtocolError, .staleMessage(field: "issued_at"))
        }
    }

    func testTaskConfirmationFreshnessValidationRejectsStaleMessage() throws {
        let confirmation = try TaskConfirmation(
            version: 1,
            requestID: "req-1",
            taskID: "task-1",
            decision: .approve,
            decidedAt: "2026-09-01T08:40:00Z"
        )

        XCTAssertThrowsError(
            try confirmation.validateFreshness(
                now: Date(timeIntervalSince1970: 1_788_251_400),
                maxAge: 300,
                maxFutureSkew: 30
            )
        ) { error in
            XCTAssertEqual(error as? BridgeProtocolError, .staleMessage(field: "decided_at"))
        }
    }

    func testTaskProgressAndTerminalResultRoundTrip() throws {
        let progress = try TaskProgress(
            version: 1,
            requestID: "req-1",
            taskID: "task-1",
            state: .executing,
            progressMessage: "Opening WeChat",
            eventIndex: 2
        )
        let result = try TaskTerminalResult(
            version: 1,
            requestID: "req-1",
            taskID: "task-1",
            state: .completed,
            summary: "WeChat opened",
            output: ["ok": .bool(true)]
        )

        XCTAssertEqual(try JSONDecoder().decode(TaskProgress.self, from: JSONEncoder().encode(progress)), progress)
        XCTAssertEqual(try JSONDecoder().decode(TaskTerminalResult.self, from: JSONEncoder().encode(result)), result)
    }

    func testTaskProgressRejectsTerminalStates() {
        for state in [TaskState.completed, .failed, .cancelled, .resultUnknown] {
            XCTAssertThrowsError(
                try TaskProgress(
                    version: 1,
                    requestID: "req-1",
                    taskID: "task-1",
                    state: state,
                    progressMessage: "Nope",
                    eventIndex: 1
                )
            ) { error in
                XCTAssertEqual(
                    error as? BridgeProtocolError,
                    .invalidLifecycleState(type: "TaskProgress", state: state.rawValue)
                )
            }
        }
    }

    func testTaskTerminalResultRejectsNonTerminalStates() {
        for state in [TaskState.preparing, .awaitingConfirmation, .executing] {
            XCTAssertThrowsError(
                try TaskTerminalResult(
                    version: 1,
                    requestID: "req-1",
                    taskID: "task-1",
                    state: state,
                    summary: "Nope",
                    output: [:]
                )
            ) { error in
                XCTAssertEqual(
                    error as? BridgeProtocolError,
                    .invalidLifecycleState(type: "TaskTerminalResult", state: state.rawValue)
                )
            }
        }
    }

    func testRejectedTaskUsesExplicitReasonCode() throws {
        let rejection = try TaskRejection(
            version: 1,
            requestID: "req-1",
            taskID: "task-1",
            reason: .paymentBlocked,
            message: "Payments stay blocked on mobile control.",
            retryable: false
        )

        XCTAssertEqual(rejection.reason, .paymentBlocked)
        XCTAssertEqual(
            try JSONDecoder().decode(TaskRejection.self, from: JSONEncoder().encode(rejection)),
            rejection
        )
    }

    func testStaleTimestampsAreRejectedByValidation() throws {
        XCTAssertThrowsError(
            try ProtocolValidation.validateTimestamp(
                "2026-09-01T08:40:00Z",
                field: "issued_at",
                now: Date(timeIntervalSince1970: 1_788_251_400),
                maxAge: 300,
                maxFutureSkew: 30
            )
        ) { error in
            XCTAssertEqual(
                error as? BridgeProtocolError,
                .staleMessage(field: "issued_at")
            )
        }
    }

    func testMalformedTimestampsAreRejectedByValidation() throws {
        XCTAssertThrowsError(
            try ProtocolValidation.validateTimestamp(
                "09/01/2026 08:40",
                field: "issued_at",
                now: Date(),
                maxAge: 300,
                maxFutureSkew: 30
            )
        ) { error in
            XCTAssertEqual(
                error as? BridgeProtocolError,
                .invalidTimestamp(field: "issued_at")
            )
        }
    }

    func testCanonicalPayloadMatchesPythonFixture() throws {
        let request = try Fixtures.openWeChatRequest()

        XCTAssertEqual(
            try request.canonicalData(),
            Data(Fixtures.openWeChatCanonicalJSON.utf8)
        )
    }

    func testCanonicalPayloadSortsNestedObjectsAndMatchesPythonUnicodeEscaping() throws {
        let request = try BridgeRequest(
            version: 1,
            requestID: "req-special",
            deviceID: "iphone-1",
            issuedAt: "2026-08-28T00:00:00Z",
            idempotencyKey: "idem-special",
            kind: .chat,
            payload: [
                "z": .string("quote\" slash/ backslash\\ controls\u{08}\u{0c}\n\r\t\u{01}"),
                "a": .object([
                    "emoji": .string("😀"),
                    "cjk": .string("汉"),
                    "array": .array([.bool(true), .null, .integer(2)]),
                ]),
            ]
        )
        let expected = #"{"device_id":"iphone-1","idempotency_key":"idem-special","issued_at":"2026-08-28T00:00:00Z","kind":"chat","payload":{"a":{"array":[true,null,2],"cjk":"\u6c49","emoji":"\ud83d\ude00"},"z":"quote\" slash/ backslash\\ controls\b\f\n\r\t\u0001"},"request_id":"req-special","version":1}"#

        XCTAssertEqual(String(decoding: try request.canonicalData(), as: UTF8.self), expected)
    }

    func testCanonicalPayloadMatchesPythonFloatingPointFixture() throws {
        let request = try Fixtures.numberRequest()

        XCTAssertEqual(
            String(decoding: try request.canonicalData(), as: UTF8.self),
            Fixtures.numberCanonicalJSON
        )
    }

    func testCodableUsesExactSnakeCaseWireNames() throws {
        let request = try Fixtures.openWeChatRequest()
        let encoded = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        XCTAssertEqual(
            Set(object.keys),
            Set([
                "version", "request_id", "device_id", "issued_at",
                "idempotency_key", "kind", "payload",
            ])
        )
        XCTAssertNil(object["requestID"])
        XCTAssertNil(object["deviceID"])
    }

    func testUnknownTaskStateIsAnExplicitProtocolError() throws {
        let data = Data(#"{"version":1,"request_id":"req-1","state":"silently_succeeded","risk":"low","payload":{}}"#.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(BridgeResponse.self, from: data)) { error in
            XCTAssertEqual(
                error as? BridgeProtocolError,
                .unknownEnumValue(type: "TaskState", value: "silently_succeeded")
            )
        }
    }

    func testUnknownRiskIsAnExplicitProtocolError() throws {
        let data = Data(#"{"version":1,"request_id":"req-1","state":"completed","risk":"trusted","payload":{}}"#.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(BridgeResponse.self, from: data)) { error in
            XCTAssertEqual(
                error as? BridgeProtocolError,
                .unknownEnumValue(type: "Risk", value: "trusted")
            )
        }
    }

    func testBridgeRequestRejectsUnknownTopLevelFields() {
        let data = Data(#"{"version":1,"request_id":"req-1","device_id":"iphone-1","issued_at":"2026-08-28T00:00:00Z","idempotency_key":"idem-1","kind":"chat","payload":{},"unexpected":true}"#.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(BridgeRequest.self, from: data)) { error in
            XCTAssertEqual(
                error as? BridgeProtocolError,
                .unknownFields(type: "BridgeRequest", fields: ["unexpected"])
            )
        }
    }

    func testBridgeResponseRejectsUnknownTopLevelFields() {
        let data = Data(#"{"version":1,"request_id":"req-1","state":"completed","risk":"low","payload":{},"unexpected":true}"#.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(BridgeResponse.self, from: data)) { error in
            XCTAssertEqual(
                error as? BridgeProtocolError,
                .unknownFields(type: "BridgeResponse", fields: ["unexpected"])
            )
        }
    }

    func testPairingPayloadRejectsUnknownTopLevelFields() {
        let fingerprint = String(repeating: "ab", count: 32)
        let data = Data(#"{"version":1,"bridge_id":"bridge-1","bridge_url":"https://192.168.1.20:8443","certificate_sha256":"\#(fingerprint)","session_id":"session-1","expires_at":"2026-08-28T00:02:00+00:00","proof":"proof","unexpected":true}"#.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(PairingPayload.self, from: data)) { error in
            XCTAssertEqual(
                error as? BridgeProtocolError,
                .unknownFields(type: "PairingPayload", fields: ["unexpected"])
            )
        }
    }

    func testBridgeRequestKeepsNestedPayloadObjectsOpen() throws {
        let data = Data(#"{"version":1,"request_id":"req-1","device_id":"iphone-1","issued_at":"2026-08-28T00:00:00Z","idempotency_key":"idem-1","kind":"chat","payload":{"future_object":{"new_field":{"deeper":true}}}}"#.utf8)

        let request = try JSONDecoder().decode(BridgeRequest.self, from: data)

        XCTAssertEqual(
            request.payload["future_object"],
            .object(["new_field": .object(["deeper": .bool(true)])])
        )
    }

    func testRequestDebugDescriptionNeverContainsPayloadContent() throws {
        let request = try BridgeRequest(
            version: 1,
            requestID: "req-1",
            deviceID: "iphone-1",
            issuedAt: "2026-08-28T00:00:00Z",
            idempotencyKey: "idem-1",
            kind: .tool,
            payload: ["message": .string("never-log-this-message")]
        )

        XCTAssertFalse(String(describing: request).contains("never-log-this-message"))
        XCTAssertFalse(String(reflecting: request).contains("never-log-this-message"))
    }

    func testSignedRequestEnvelopeUsesStableWireNames() throws {
        let envelope = try SignedRequestEnvelope(
            request: Fixtures.openWeChatRequest(),
            signature: String(repeating: "a", count: 64)
        )

        let encoded = try JSONEncoder().encode(envelope)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        XCTAssertEqual(Set(object.keys), Set(["request", "signature"]))
    }
}

enum Fixtures {
    static let openWeChatCanonicalJSON = #"{"device_id":"iphone-1","idempotency_key":"idem-1","issued_at":"2026-08-28T00:00:00Z","kind":"tool","payload":{"arguments":{"name":"\u5fae\u4fe1"},"tool":"open_application"},"request_id":"req-1","version":1}"#
    static let numberCanonicalJSON = #"{"device_id":"iphone-1","idempotency_key":"idem-numbers","issued_at":"2026-08-28T00:00:00Z","kind":"chat","payload":{"numbers":{"decimal":12.5,"large":1e+20,"negative_zero":-0.0,"one":1.0,"small":1e-07}},"request_id":"req-numbers","version":1}"#

    static func openWeChatRequest() throws -> BridgeRequest {
        try BridgeRequest(
            version: 1,
            requestID: "req-1",
            deviceID: "iphone-1",
            issuedAt: "2026-08-28T00:00:00Z",
            idempotencyKey: "idem-1",
            kind: .tool,
            payload: [
                "tool": .string("open_application"),
                "arguments": .object(["name": .string("微信")]),
            ]
        )
    }

    static func numberRequest() throws -> BridgeRequest {
        try BridgeRequest(
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
    }
}
