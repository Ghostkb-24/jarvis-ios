import CryptoKit
import Foundation

public enum RequestSigner {
    public static func canonicalSigningPayload(for request: BridgeRequest) throws -> Data {
        try request.canonicalData()
    }

    public static func canonicalSigningPayload(
        for request: BridgeRequest,
        confirmation: TaskConfirmation
    ) throws -> Data {
        let object: [String: JSONValue] = [
            "request": .object([
                "version": .integer(Int64(request.version)),
                "request_id": .string(request.requestID),
                "device_id": .string(request.deviceID),
                "issued_at": .string(request.issuedAt),
                "idempotency_key": .string(request.idempotencyKey),
                "kind": .string(request.kind.rawValue),
                "payload": .object(request.payload),
            ]),
            "confirmation": .object([
                "version": .integer(Int64(confirmation.version)),
                "request_id": .string(confirmation.requestID),
                "task_id": .string(confirmation.taskID),
                "decision": .string(confirmation.decision.rawValue),
                "decided_at": .string(confirmation.decidedAt),
            ]),
        ]
        return Data(try CanonicalJSON.serialize(.object(object)).utf8)
    }

    public static func signature(for request: BridgeRequest, secret: Data) throws -> String {
        try signature(for: canonicalSigningPayload(for: request), secret: secret)
    }

    public static func signature(
        for request: BridgeRequest,
        confirmation: TaskConfirmation,
        secret: Data
    ) throws -> String {
        try signature(
            for: canonicalSigningPayload(for: request, confirmation: confirmation),
            secret: secret
        )
    }

    public static func signature(for canonicalRequestData: Data, secret: Data) throws -> String {
        guard secret.count == 32 else { throw BridgeProtocolError.invalidSecretLength }
        let key = SymmetricKey(data: secret)
        let authenticationCode = HMAC<SHA256>.authenticationCode(
            for: canonicalRequestData,
            using: key
        )
        let signature = authenticationCode.map { String(format: "%02x", $0) }.joined()
        try validate(signature: signature)
        return signature
    }

    public static func validate(signature: String) throws {
        guard ProtocolValidation.isLowercaseHex(signature, length: 64) else {
            throw BridgeProtocolError.invalidSignature
        }
    }

    public static func validateRequestMetadata(
        _ request: BridgeRequest,
        now: Date,
        maxAge: TimeInterval = 300,
        maxFutureSkew: TimeInterval = 30
    ) throws {
        _ = try ProtocolValidation.validateTimestamp(
            request.issuedAt,
            field: "issued_at",
            now: now,
            maxAge: maxAge,
            maxFutureSkew: maxFutureSkew
        )
    }
}
