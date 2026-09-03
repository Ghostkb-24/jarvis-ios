import Foundation
import XCTest
@testable import JarvisProtocol

final class RequestSignerTests: XCTestCase {
    func testCanonicalSigningPayloadMatchesCanonicalRequestBytes() throws {
        let request = try Fixtures.openWeChatRequest()

        let payload = try RequestSigner.canonicalSigningPayload(for: request)
        XCTAssertEqual(payload, try request.canonicalData())
    }

    func testHMACMatchesPythonFixtureAndUsesLowercaseHex() throws {
        let request = try Fixtures.openWeChatRequest()
        let secret = Data("0123456789abcdef0123456789abcdef".utf8)

        let signature = try RequestSigner.signature(for: request, secret: secret)

        XCTAssertEqual(
            signature,
            "15f1e3c306fc21a0ccf84ef41b54f41289752805ec916df8f583bca157a445ba"
        )
        XCTAssertNoThrow(try RequestSigner.validate(signature: signature))
    }

    func testHMACMatchesPythonFloatingPointFixture() throws {
        let request = try Fixtures.numberRequest()
        let secret = Data("0123456789abcdef0123456789abcdef".utf8)

        let signature = try RequestSigner.signature(for: request, secret: secret)
        XCTAssertEqual(signature, "10e5b6f4e96399c9ae514dbd3ca8fbc3e1ab81f901dd3f918ac108be7f5fcc89")
    }

    func testSignerRejectsSecretsThatAreNotExactly32Bytes() throws {
        let request = try Fixtures.openWeChatRequest()

        for length in [0, 31, 33] {
            XCTAssertThrowsError(
                try RequestSigner.signature(for: request, secret: Data(repeating: 0, count: length))
            ) { error in
                XCTAssertEqual(error as? BridgeProtocolError, .invalidSecretLength)
            }
        }
    }

    func testSignatureValidationRejectsUppercaseWrongLengthAndNonHex() {
        let invalid = [
            String(repeating: "A", count: 64),
            String(repeating: "a", count: 63),
            String(repeating: "g", count: 64),
        ]

        for signature in invalid {
            XCTAssertThrowsError(try RequestSigner.validate(signature: signature)) { error in
                XCTAssertEqual(error as? BridgeProtocolError, .invalidSignature)
            }
        }
    }

    func testVerifyRejectsStaleRequestMetadata() throws {
        let request = try BridgeRequest(
            version: 1,
            requestID: "req-1",
            deviceID: "iphone-1",
            issuedAt: "2026-09-01T08:40:00Z",
            idempotencyKey: "idem-1",
            kind: .tool,
            payload: ["tool": .string("open_application")]
        )

        XCTAssertThrowsError(
            try RequestSigner.validateRequestMetadata(
                request,
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

    func testVerifyAcceptsFreshRequestMetadata() throws {
        let request = try BridgeRequest(
            version: 1,
            requestID: "req-1",
            deviceID: "iphone-1",
            issuedAt: "2026-09-01T08:59:30Z",
            idempotencyKey: "idem-1",
            kind: .tool,
            payload: ["tool": .string("open_application")]
        )

        XCTAssertNoThrow(
            try RequestSigner.validateRequestMetadata(
                request,
                now: Date(timeIntervalSince1970: 1_788_251_400),
                maxAge: 300,
                maxFutureSkew: 30
            )
        )
    }
}
