import CryptoKit
import Foundation

public enum RequestSigner {
    public static func canonicalSigningPayload(for request: BridgeRequest) throws -> Data {
        try request.canonicalData()
    }

    public static func signature(for request: BridgeRequest, secret: Data) throws -> String {
        try signature(for: canonicalSigningPayload(for: request), secret: secret)
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
