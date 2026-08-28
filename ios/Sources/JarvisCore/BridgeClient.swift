import CryptoKit
import Foundation
import JarvisProtocol
import Network
import Security

public enum BridgeError: Error, Equatable, Sendable {
    case invalidBridgeURL
    case invalidHTTPResponse
    case httpStatus(Int)
    case invalidProtocolResponse
    case invalidPairingResponse
    case invalidOperationRequest
    case requestOwnershipMismatch
    case requestTargetMismatch
    case resultUnknown
    case transportUnavailable
}

extension BridgeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidBridgeURL:
            "Bridge URL must use HTTPS and a private or local host"
        case .invalidHTTPResponse:
            "Bridge returned an invalid HTTP response"
        case let .httpStatus(status):
            "Bridge returned HTTP status \(status)"
        case .invalidProtocolResponse:
            "Bridge returned an invalid protocol response"
        case .invalidPairingResponse:
            "Bridge returned invalid pairing credentials"
        case .invalidOperationRequest:
            "Signed request kind does not match this Bridge operation"
        case .requestOwnershipMismatch:
            "Signed request does not belong to the paired device"
        case .requestTargetMismatch:
            "Signed target does not match the requested task"
        case .resultUnknown:
            "Bridge request result is unknown; do not automatically resubmit"
        case .transportUnavailable:
            "Bridge transport is unavailable"
        }
    }
}

public protocol BridgeTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public final class URLSessionTransport: BridgeTransport, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw BridgeError.invalidHTTPResponse
        }
        return (data, response)
    }
}

public protocol PinnedTransportFactory: Sendable {
    func makeTransport(certificateFingerprint: String) throws -> any BridgeTransport
}

public struct URLSessionPinnedTransportFactory: PinnedTransportFactory {
    public init() {}

    public func makeTransport(certificateFingerprint: String) throws -> any BridgeTransport {
        let delegate = try PinnedCertificateDelegate(fingerprint: certificateFingerprint)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        return URLSessionTransport(session: session)
    }
}

public final class PinnedCertificateDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let fingerprint: String

    public init(fingerprint: String) throws {
        try ProtocolValidation.validateFingerprint(fingerprint)
        self.fingerprint = fingerprint
        super.init()
    }

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (
            URLSession.AuthChallengeDisposition,
            URLCredential?
        ) -> Void
    ) {
        let protectionSpace = challenge.protectionSpace
        guard
            protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let trust = protectionSpace.serverTrust,
            let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
            let leaf = chain.first
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let leafData = SecCertificateCopyData(leaf) as Data
        guard disposition(
            authenticationMethod: protectionSpace.authenticationMethod,
            leafCertificateDER: leafData
        ) == .useCredential else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func disposition(
        authenticationMethod: String,
        leafCertificateDER: Data?
    ) -> URLSession.AuthChallengeDisposition {
        guard
            authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let leafCertificateDER
        else {
            return .cancelAuthenticationChallenge
        }
        let actual = SHA256.hash(data: leafCertificateDER)
            .map { String(format: "%02x", $0) }
            .joined()
        return constantTimeEquals(actual, fingerprint)
            ? .useCredential
            : .cancelAuthenticationChallenge
    }

    private func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }
}

public struct BridgeRetryPolicy: Equatable, Sendable {
    public let maximumReadAttempts: Int

    public static func safeReadsOnly(maxAttempts: Int = 2) -> BridgeRetryPolicy {
        BridgeRetryPolicy(maximumReadAttempts: max(1, maxAttempts))
    }

    private init(maximumReadAttempts: Int) {
        self.maximumReadAttempts = maximumReadAttempts
    }
}

public struct BridgeClient: Sendable {
    private let baseURL: URL
    private let credentials: DeviceCredentials
    private let transport: any BridgeTransport
    private let retryPolicy: BridgeRetryPolicy

    public init(
        baseURL: URL,
        credentials: DeviceCredentials,
        transportFactory: any PinnedTransportFactory = URLSessionPinnedTransportFactory(),
        retryPolicy: BridgeRetryPolicy = .safeReadsOnly()
    ) throws {
        let transport = try transportFactory.makeTransport(
            certificateFingerprint: credentials.certificateFingerprint
        )
        try self.init(
            baseURL: baseURL,
            credentials: credentials,
            transport: transport,
            retryPolicy: retryPolicy
        )
    }

    public init(
        baseURL: URL,
        credentials: DeviceCredentials,
        transport: any BridgeTransport,
        retryPolicy: BridgeRetryPolicy = .safeReadsOnly()
    ) throws {
        self.baseURL = try BridgeURLValidator.validate(baseURL)
        self.credentials = credentials
        self.transport = transport
        self.retryPolicy = retryPolicy
    }

    public func submit(_ request: BridgeRequest) async throws -> BridgeResponse {
        guard request.kind == .chat || request.kind == .tool else {
            throw BridgeError.invalidOperationRequest
        }
        try requireOwner(request)
        let url = endpoint(["v1", "requests"])
        let urlRequest = try signedURLRequest(url: url, method: "POST", request: request)
        return try await sendStateChanging(urlRequest)
    }

    public func status(
        for requestID: String,
        authentication: BridgeRequest
    ) async throws -> BridgeResponse {
        guard authentication.kind == .chat else {
            throw BridgeError.invalidOperationRequest
        }
        try requireOwner(authentication)
        try requireTarget(requestID, request: authentication)
        let url = endpoint(["v1", "tasks", requestID])
        let urlRequest = try signedURLRequest(
            url: url,
            method: "GET",
            request: authentication
        )
        return try await sendReadOnly(urlRequest)
    }

    public func confirm(
        _ requestID: String,
        confirmation: BridgeRequest
    ) async throws -> BridgeResponse {
        guard confirmation.kind == .confirm else {
            throw BridgeError.invalidOperationRequest
        }
        return try await submitConfirmation(
            requestID,
            authorization: confirmation
        )
    }

    public func cancel(
        _ requestID: String,
        cancellation: BridgeRequest
    ) async throws -> BridgeResponse {
        guard cancellation.kind == .cancel else {
            throw BridgeError.invalidOperationRequest
        }
        return try await submitConfirmation(
            requestID,
            authorization: cancellation
        )
    }

    public static func claimPairing(
        _ payload: PairingPayload,
        deviceName: String,
        store: KeychainDeviceStore,
        transportFactory: any PinnedTransportFactory = URLSessionPinnedTransportFactory()
    ) async throws -> DeviceCredentials {
        guard !deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BridgeProtocolError.emptyField("device_name")
        }
        guard let rawURL = URL(string: payload.bridgeURL) else {
            throw BridgeError.invalidBridgeURL
        }
        let baseURL = try BridgeURLValidator.validate(rawURL)
        let transport = try transportFactory.makeTransport(
            certificateFingerprint: payload.certificateFingerprint
        )
        let body = PairClaimRequest(
            sessionID: payload.sessionID,
            deviceName: deviceName.trimmingCharacters(in: .whitespacesAndNewlines),
            proof: payload.proof
        )
        var request = URLRequest(
            url: Self.endpoint(baseURL: baseURL, components: ["v1", "pair", "claim"])
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            if Self.isAmbiguousTransportError(error) {
                throw BridgeError.resultUnknown
            }
            throw BridgeError.transportUnavailable
        }
        guard (200 ... 299).contains(response.statusCode) else {
            throw BridgeError.httpStatus(response.statusCode)
        }
        let decoded: PairClaimResponse
        do {
            decoded = try JSONDecoder().decode(PairClaimResponse.self, from: data)
        } catch {
            throw BridgeError.invalidPairingResponse
        }
        guard
            decoded.version == 1,
            !decoded.deviceID.isEmpty,
            let secret = Self.decodeURLSafeBase64(decoded.deviceSecret),
            secret.count == 32
        else {
            throw BridgeError.invalidPairingResponse
        }
        let credentials: DeviceCredentials
        do {
            credentials = try DeviceCredentials(
                deviceID: decoded.deviceID,
                secret: secret,
                certificateFingerprint: payload.certificateFingerprint
            )
        } catch {
            throw BridgeError.invalidPairingResponse
        }
        try store.save(credentials)
        return credentials
    }

    private func submitConfirmation(
        _ requestID: String,
        authorization: BridgeRequest
    ) async throws -> BridgeResponse {
        try requireOwner(authorization)
        try requireTarget(requestID, request: authorization)
        let url = endpoint(["v1", "tasks", requestID, "confirm"])
        let urlRequest = try signedURLRequest(
            url: url,
            method: "POST",
            request: authorization
        )
        return try await sendStateChanging(urlRequest)
    }

    private func signedURLRequest(
        url: URL,
        method: String,
        request: BridgeRequest
    ) throws -> URLRequest {
        let signature = try RequestSigner.signature(for: request, secret: credentials.secret)
        let envelope = SignedBridgeRequest(request: request, signature: signature)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(envelope)
        return urlRequest
    }

    private func sendStateChanging(_ request: URLRequest) async throws -> BridgeResponse {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            if Self.isAmbiguousTransportError(error) {
                throw BridgeError.resultUnknown
            }
            throw BridgeError.transportUnavailable
        }
        guard (200 ... 299).contains(response.statusCode) else {
            throw BridgeError.httpStatus(response.statusCode)
        }
        do {
            return try JSONDecoder().decode(BridgeResponse.self, from: data)
        } catch {
            throw BridgeError.resultUnknown
        }
    }

    private func sendReadOnly(_ request: URLRequest) async throws -> BridgeResponse {
        var attempt = 0
        while attempt < retryPolicy.maximumReadAttempts {
            attempt += 1
            do {
                let (data, response) = try await transport.send(request)
                guard (200 ... 299).contains(response.statusCode) else {
                    throw BridgeError.httpStatus(response.statusCode)
                }
                do {
                    return try JSONDecoder().decode(BridgeResponse.self, from: data)
                } catch {
                    throw BridgeError.invalidProtocolResponse
                }
            } catch {
                if Self.isAmbiguousTransportError(error),
                   attempt < retryPolicy.maximumReadAttempts {
                    continue
                }
                if let bridgeError = error as? BridgeError {
                    throw bridgeError
                }
                throw BridgeError.transportUnavailable
            }
        }
        throw BridgeError.transportUnavailable
    }

    private func requireOwner(_ request: BridgeRequest) throws {
        guard request.deviceID == credentials.deviceID else {
            throw BridgeError.requestOwnershipMismatch
        }
    }

    private func requireTarget(_ requestID: String, request: BridgeRequest) throws {
        guard
            request.payload.count == 1,
            case let .string(target)? = request.payload["target_request_id"],
            target == requestID
        else {
            throw BridgeError.requestTargetMismatch
        }
    }

    private func endpoint(_ components: [String]) -> URL {
        Self.endpoint(baseURL: baseURL, components: components)
    }

    private static func endpoint(baseURL: URL, components: [String]) -> URL {
        components.reduce(baseURL) { partial, component in
            partial.appendingPathComponent(component, isDirectory: false)
        }
    }

    private static func decodeURLSafeBase64(_ value: String) -> Data? {
        var normalized = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.utf8.count % 4
        if remainder != 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: normalized)
    }

    private static func isAmbiguousTransportError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        return [
            URLError.Code.timedOut,
            .networkConnectionLost,
            .cancelled,
        ].contains(urlError.code)
    }
}

extension BridgeClient: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "BridgeClient(baseURL: \(baseURL.absoluteString), credentials: <redacted>)"
    }

    public var debugDescription: String { description }
}

private struct SignedBridgeRequest: Encodable {
    let request: BridgeRequest
    let signature: String
}

private struct PairClaimRequest: Encodable {
    let sessionID: String
    let deviceName: String
    let proof: String

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case deviceName = "device_name"
        case proof
    }
}

private struct PairClaimResponse: Decodable {
    let version: Int
    let deviceID: String
    let deviceSecret: String

    private enum CodingKeys: String, CodingKey {
        case version
        case deviceID = "device_id"
        case deviceSecret = "device_secret"
    }
}

private enum BridgeURLValidator {
    static func validate(_ url: URL) throws -> URL {
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme?.lowercased() == "https",
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil,
            components.path.isEmpty || components.path == "/",
            let host = components.host?.lowercased(),
            isPrivateOrLocal(host)
        else {
            throw BridgeError.invalidBridgeURL
        }
        return url
    }

    private static func isPrivateOrLocal(_ host: String) -> Bool {
        var normalized = host.hasSuffix(".") ? String(host.dropLast()) : host
        if normalized.hasPrefix("["), normalized.hasSuffix("]") {
            normalized = String(normalized.dropFirst().dropLast())
        }
        if isLegacyNumericHost(normalized) {
            return false
        }
        if let address = IPv4Address(normalized) {
            let bytes = [UInt8](address.rawValue)
            guard bytes.count == 4 else { return false }
            return bytes[0] == 10
                || bytes[0] == 127
                || (bytes[0] == 169 && bytes[1] == 254)
                || (bytes[0] == 172 && (16 ... 31).contains(bytes[1]))
                || (bytes[0] == 192 && bytes[1] == 168)
        }
        if let address = IPv6Address(normalized) {
            let bytes = [UInt8](address.rawValue)
            guard bytes.count == 16 else { return false }
            let isLoopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
            let isUniqueLocal = (bytes[0] & 0xFE) == 0xFC
            let isLinkLocal = bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80
            return isLoopback || isUniqueLocal || isLinkLocal
        }
        if normalized.contains(":") {
            return false
        }
        return normalized == "localhost"
            || normalized.hasSuffix(".local")
            || (!normalized.isEmpty && !normalized.contains("."))
    }

    private static func isLegacyNumericHost(_ host: String) -> Bool {
        if !host.isEmpty && host.utf8.allSatisfy({ (48 ... 57).contains($0) }) {
            return true
        }
        guard host.hasPrefix("0x"), host.utf8.count > 2 else { return false }
        return host.utf8.dropFirst(2).allSatisfy { byte in
            (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
        }
    }
}
