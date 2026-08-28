import Foundation
import XCTest
@testable import JarvisProtocol

final class BridgeModelsTests: XCTestCase {
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
