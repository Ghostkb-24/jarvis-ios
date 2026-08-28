import CryptoKit
import Foundation

public enum RequestSigner {
    public static func signature(for request: BridgeRequest, secret: Data) throws -> String {
        try signature(for: request.canonicalData(), secret: secret)
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
}
