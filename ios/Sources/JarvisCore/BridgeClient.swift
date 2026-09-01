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
    case requestRejected(TaskRejection)
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
        case let .requestRejected(rejection):
            rejection.message
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

public final class PinnedCertificateDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
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

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
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

public enum BridgeEndpoint: Equatable, Sendable {
    case discovered(DiscoveryMessage)
    case manual(baseURL: URL, certificateFingerprint: String)

    fileprivate var resolvedURL: URL? {
        switch self {
        case let .discovered(message):
            URL(string: message.bridgeURL)
        case let .manual(baseURL, _):
            baseURL
        }
    }

    fileprivate var certificateFingerprint: String {
        switch self {
        case let .discovered(message):
            message.certificateFingerprint
        case let .manual(_, fingerprint):
            fingerprint
        }
    }
}

public enum BridgeConnectionState: Equatable, Sendable {
    case unpaired(endpoint: BridgeEndpoint)
    case paired(endpoint: BridgeEndpoint, deviceID: String)
    case connecting(endpoint: BridgeEndpoint, deviceID: String)
    case connected(endpoint: BridgeEndpoint, deviceID: String)
    case disconnected(endpoint: BridgeEndpoint, deviceID: String, canRetryReads: Bool)
}

public enum BridgeEvent: Equatable, Sendable {
    case preview(TaskPreview)
    case progress(TaskProgress)
    case terminal(TaskTerminalResult)
    case rejection(TaskRejection)
}

public struct BridgeClient: Sendable {
    private let endpointSelection: BridgeEndpoint
    private let baseURL: URL
    private let credentials: DeviceCredentials
    private let transport: any BridgeTransport
    private let retryPolicy: BridgeRetryPolicy
    private let stateStore: BridgeConnectionStateStore

    public init(
        endpoint: BridgeEndpoint,
        credentials: DeviceCredentials,
        transportFactory: any PinnedTransportFactory = URLSessionPinnedTransportFactory(),
        retryPolicy: BridgeRetryPolicy = .safeReadsOnly()
    ) throws {
        let baseURL = try validatedBaseURL(for: endpoint)
        let transport = try transportFactory.makeTransport(
            certificateFingerprint: endpoint.certificateFingerprint
        )
        self.endpointSelection = endpoint
        self.baseURL = baseURL
        self.credentials = credentials
        self.transport = transport
        self.retryPolicy = retryPolicy
        stateStore = BridgeConnectionStateStore(
            initial: .paired(endpoint: endpoint, deviceID: credentials.deviceID)
        )
    }

    public init(
        endpoint: BridgeEndpoint,
        credentials: DeviceCredentials,
        transport: any BridgeTransport,
        retryPolicy: BridgeRetryPolicy = .safeReadsOnly()
    ) throws {
        self.endpointSelection = endpoint
        baseURL = try Self.validatedBaseURL(for: endpoint)
        self.credentials = credentials
        self.transport = transport
        self.retryPolicy = retryPolicy
        stateStore = BridgeConnectionStateStore(
            initial: .paired(endpoint: endpoint, deviceID: credentials.deviceID)
        )
    }

    public init(
        baseURL: URL,
        certificateFingerprint: String,
        credentials: DeviceCredentials,
        transportFactory: any PinnedTransportFactory = URLSessionPinnedTransportFactory(),
        retryPolicy: BridgeRetryPolicy = .safeReadsOnly()
    ) throws {
        try self.init(
            endpoint: .manual(
                baseURL: baseURL,
                certificateFingerprint: certificateFingerprint
            ),
            credentials: credentials,
            transportFactory: transportFactory,
            retryPolicy: retryPolicy
        )
    }

    public init(
        baseURL: URL,
        certificateFingerprint: String,
        credentials: DeviceCredentials,
        transport: any BridgeTransport,
        retryPolicy: BridgeRetryPolicy = .safeReadsOnly()
    ) throws {
        try self.init(
            endpoint: .manual(
                baseURL: baseURL,
                certificateFingerprint: certificateFingerprint
            ),
            credentials: credentials,
            transport: transport,
            retryPolicy: retryPolicy
        )
    }

    public func connectionState() async -> BridgeConnectionState {
        await stateStore.current()
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
        let urlRequest = try signedURLRequest(url: url, method: "GET", request: authentication)
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
        transportFactory: any PinnedTransportFactory = URLSessionPinnedTransportFactory(),
        now: Date = Date()
    ) async throws -> DeviceCredentials {
        guard !deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BridgeProtocolError.emptyField("device_name")
        }
        let expiry = try ProtocolValidation.parseTimestamp(payload.expiresAt, field: "expires_at")
        guard expiry.timeIntervalSince(now) >= -30 else {
            throw BridgeProtocolError.staleMessage(field: "expires_at")
        }
        guard let rawURL = URL(string: payload.bridgeURL) else {
            throw BridgeError.invalidBridgeURL
        }
        let manualEndpoint = BridgeEndpoint.manual(
            baseURL: rawURL,
            certificateFingerprint: payload.certificateFingerprint
        )
        let baseURL = try validatedBaseURL(for: manualEndpoint)
        let transport = try transportFactory.makeTransport(
            certificateFingerprint: manualEndpoint.certificateFingerprint
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
        return try await claimCredentials(
            request: request,
            transport: transport,
            store: store,
            expectedDeviceID: payload.deviceID,
            expectedDevicePublicKey: payload.devicePublicKey
        )
    }

    public static func completePairing(
        challenge: PairingChallenge,
        response: PairingChallengeResponse,
        endpoint: BridgeEndpoint,
        store: KeychainDeviceStore,
        now: Date = Date(),
        transportFactory: any PinnedTransportFactory = URLSessionPinnedTransportFactory()
    ) async throws -> DeviceCredentials {
        try challenge.validateFreshness(now: now)
        try response.validateFreshness(now: now)
        guard challenge.sessionID == response.sessionID else {
            throw BridgeError.invalidPairingResponse
        }
        guard challenge.pairingCode == response.pairingCode else {
            throw BridgeError.invalidPairingResponse
        }
        guard challenge.challengeNonce == response.challengeNonce else {
            throw BridgeError.invalidPairingResponse
        }
        if case let .discovered(discovery) = endpoint,
           discovery.bridgeID != challenge.bridgeID {
            throw BridgeError.invalidPairingResponse
        }

        let baseURL = try validatedBaseURL(for: endpoint)
        let transport = try transportFactory.makeTransport(
            certificateFingerprint: endpoint.certificateFingerprint
        )
        var request = URLRequest(
            url: Self.endpoint(baseURL: baseURL, components: ["v1", "pair", "challenge"])
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(response)
        return try await claimCredentials(
            request: request,
            transport: transport,
            store: store,
            expectedDeviceID: response.deviceID,
            expectedDevicePublicKey: response.devicePublicKey
        )
    }

    public static func decodeEvent(_ data: Data) throws -> BridgeEvent {
        let decoder = JSONDecoder()
        if let preview = try? decoder.decode(TaskPreview.self, from: data) {
            return .preview(preview)
        }
        if let progress = try? decoder.decode(TaskProgress.self, from: data) {
            return .progress(progress)
        }
        if let terminal = try? decoder.decode(TaskTerminalResult.self, from: data) {
            return .terminal(terminal)
        }
        if let rejection = try? decoder.decode(TaskRejection.self, from: data) {
            return .rejection(rejection)
        }
        throw BridgeError.invalidProtocolResponse
    }

    private func submitConfirmation(
        _ requestID: String,
        authorization: BridgeRequest
    ) async throws -> BridgeResponse {
        try requireOwner(authorization)
        try requireTarget(requestID, request: authorization)
        let confirmation = try taskConfirmation(for: requestID, authorization: authorization)
        let url = endpoint(["v1", "tasks", requestID, "confirm"])
        let urlRequest = try signedConfirmationRequest(
            url: url,
            method: "POST",
            request: authorization,
            confirmation: confirmation
        )
        return try await sendStateChanging(urlRequest)
    }

    private func signedURLRequest(
        url: URL,
        method: String,
        request: BridgeRequest
    ) throws -> URLRequest {
        let signature = try RequestSigner.signature(for: request, secret: credentials.secret)
        let envelope = try SignedRequestEnvelope(request: request, signature: signature)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(envelope)
        return urlRequest
    }

    private func signedConfirmationRequest(
        url: URL,
        method: String,
        request: BridgeRequest,
        confirmation: TaskConfirmation
    ) throws -> URLRequest {
        let signature = try RequestSigner.signature(for: request, secret: credentials.secret)
        let envelope = try SignedTaskConfirmationEnvelope(
            request: request,
            confirmation: confirmation,
            signature: signature
        )
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(envelope)
        return urlRequest
    }

    private func sendStateChanging(_ request: URLRequest) async throws -> BridgeResponse {
        await stateStore.update(.connecting(endpoint: endpointSelection, deviceID: credentials.deviceID))
        do {
            let (data, response) = try await transport.send(request)
            let decoded = try decodeResponse(data: data, response: response)
            await stateStore.update(.connected(endpoint: endpointSelection, deviceID: credentials.deviceID))
            return decoded
        } catch {
            if Self.isAmbiguousTransportError(error) {
                await markDisconnected(canRetryReads: true)
                throw BridgeError.resultUnknown
            }
            if let bridgeError = error as? BridgeError {
                switch bridgeError {
                case .requestRejected(_), .httpStatus(_):
                    await stateStore.update(
                        .connected(endpoint: endpointSelection, deviceID: credentials.deviceID)
                    )
                default:
                    await markDisconnected(canRetryReads: true)
                }
                throw bridgeError
            }
            await markDisconnected(canRetryReads: true)
            throw BridgeError.transportUnavailable
        }
    }

    private func sendReadOnly(_ request: URLRequest) async throws -> BridgeResponse {
        var attempt = 0
        while attempt < retryPolicy.maximumReadAttempts {
            attempt += 1
            await stateStore.update(.connecting(endpoint: endpointSelection, deviceID: credentials.deviceID))
            do {
                let (data, response) = try await transport.send(request)
                let decoded = try decodeResponse(data: data, response: response)
                await stateStore.update(
                    .connected(endpoint: endpointSelection, deviceID: credentials.deviceID)
                )
                return decoded
            } catch {
                if Self.isAmbiguousTransportError(error) {
                    await markDisconnected(canRetryReads: true)
                    if attempt < retryPolicy.maximumReadAttempts {
                        continue
                    }
                    throw BridgeError.transportUnavailable
                }
                if let bridgeError = error as? BridgeError {
                    switch bridgeError {
                    case .requestRejected(_),
                         .httpStatus(_),
                         .invalidProtocolResponse,
                         .invalidHTTPResponse:
                        await markPaired()
                    default:
                        await markDisconnected(canRetryReads: true)
                    }
                    throw bridgeError
                }
                await markDisconnected(canRetryReads: true)
                throw BridgeError.transportUnavailable
            }
        }
        await markDisconnected(canRetryReads: true)
        throw BridgeError.transportUnavailable
    }

    private func decodeResponse(
        data: Data,
        response: HTTPURLResponse
    ) throws -> BridgeResponse {
        let decoder = JSONDecoder()
        if let rejection = try? decoder.decode(TaskRejection.self, from: data) {
            throw BridgeError.requestRejected(rejection)
        }
        if let direct = try? decoder.decode(BridgeResponse.self, from: data) {
            return direct
        }
        if let preview = try? decoder.decode(TaskPreview.self, from: data) {
            return try bridgeResponse(from: preview)
        }
        if let progress = try? decoder.decode(TaskProgress.self, from: data) {
            return try bridgeResponse(from: progress)
        }
        if let terminal = try? decoder.decode(TaskTerminalResult.self, from: data) {
            return try bridgeResponse(from: terminal)
        }
        guard (200 ... 299).contains(response.statusCode) else {
            throw BridgeError.httpStatus(response.statusCode)
        }
        throw BridgeError.invalidProtocolResponse
    }

    private func bridgeResponse(from preview: TaskPreview) throws -> BridgeResponse {
        try BridgeResponse(
            version: preview.version,
            requestID: preview.requestID,
            state: .awaitingConfirmation,
            risk: preview.risk,
            payload: [
                "task_id": .string(preview.taskID),
                "title": .string(preview.title),
                "summary": .string(preview.summary),
                "action": .string(preview.action),
                "target": .string(preview.target),
                "arguments": .object(preview.arguments),
            ]
        )
    }

    private func bridgeResponse(from progress: TaskProgress) throws -> BridgeResponse {
        try BridgeResponse(
            version: progress.version,
            requestID: progress.requestID,
            state: progress.state,
            risk: .low,
            payload: [
                "task_id": .string(progress.taskID),
                "progress_message": .string(progress.progressMessage),
                "event_index": .integer(Int64(progress.eventIndex)),
            ]
        )
    }

    private func bridgeResponse(from terminal: TaskTerminalResult) throws -> BridgeResponse {
        var payload = terminal.output
        payload["task_id"] = .string(terminal.taskID)
        payload["summary"] = .string(terminal.summary)
        return try BridgeResponse(
            version: terminal.version,
            requestID: terminal.requestID,
            state: terminal.state,
            risk: .low,
            payload: payload
        )
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

    private func taskConfirmation(
        for taskID: String,
        authorization: BridgeRequest,
        now: Date = Date()
    ) throws -> TaskConfirmation {
        let decision: ConfirmationDecision
        switch authorization.kind {
        case .confirm:
            decision = .approve
        case .cancel:
            decision = .decline
        case .chat, .tool:
            throw BridgeError.invalidOperationRequest
        }
        let confirmation = try TaskConfirmation(
            version: 1,
            requestID: authorization.requestID,
            taskID: taskID,
            decision: decision,
            decidedAt: Self.timestamp(now)
        )
        try confirmation.validateFreshness(now: now)
        return confirmation
    }

    private func markPaired() async {
        await stateStore.update(
            .paired(endpoint: endpointSelection, deviceID: credentials.deviceID)
        )
    }

    private func markDisconnected(canRetryReads: Bool) async {
        await stateStore.update(
            .disconnected(
                endpoint: endpointSelection,
                deviceID: credentials.deviceID,
                canRetryReads: canRetryReads
            )
        )
    }

    private static func validatedBaseURL(for endpoint: BridgeEndpoint) throws -> URL {
        guard let rawURL = endpoint.resolvedURL else {
            throw BridgeError.invalidBridgeURL
        }
        return try BridgeURLValidator.validate(rawURL)
    }

    private static func endpoint(baseURL: URL, components: [String]) -> URL {
        components.reduce(baseURL) { partial, component in
            partial.appendingPathComponent(component, isDirectory: false)
        }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func claimCredentials(
        request: URLRequest,
        transport: any BridgeTransport,
        store: KeychainDeviceStore,
        expectedDeviceID: String,
        expectedDevicePublicKey: String
    ) async throws -> DeviceCredentials {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            if isAmbiguousTransportError(error) {
                throw BridgeError.resultUnknown
            }
            throw BridgeError.transportUnavailable
        }
        if let rejection = try? JSONDecoder().decode(TaskRejection.self, from: data) {
            throw BridgeError.requestRejected(rejection)
        }
        guard (200 ... 299).contains(response.statusCode) else {
            throw BridgeError.httpStatus(response.statusCode)
        }
        let credentials = try decodePairClaimResponse(
            data,
            expectedDeviceID: expectedDeviceID,
            expectedDevicePublicKey: expectedDevicePublicKey
        )
        try store.save(credentials)
        return credentials
    }

    private static func decodePairClaimResponse(
        _ data: Data,
        expectedDeviceID: String,
        expectedDevicePublicKey: String
    ) throws -> DeviceCredentials {
        let decoded: PairClaimResponse
        do {
            decoded = try JSONDecoder().decode(PairClaimResponse.self, from: data)
        } catch {
            throw BridgeError.invalidPairingResponse
        }
        guard
            decoded.version == 1,
            !decoded.deviceID.isEmpty,
            decoded.deviceID == expectedDeviceID,
            decoded.devicePublicKey == expectedDevicePublicKey,
            let secret = decodeURLSafeBase64(decoded.deviceSecret),
            secret.count == 32
        else {
            throw BridgeError.invalidPairingResponse
        }
        do {
            return try DeviceCredentials(deviceID: decoded.deviceID, secret: secret)
        } catch {
            throw BridgeError.invalidPairingResponse
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

private actor BridgeConnectionStateStore {
    private var state: BridgeConnectionState

    init(initial: BridgeConnectionState) {
        state = initial
    }

    func current() -> BridgeConnectionState {
        state
    }

    func update(_ next: BridgeConnectionState) {
        state = next
    }
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

private struct SignedTaskConfirmationEnvelope: Encodable {
    let request: BridgeRequest
    let confirmation: TaskConfirmation
    let signature: String

    init(
        request: BridgeRequest,
        confirmation: TaskConfirmation,
        signature: String
    ) throws {
        try RequestSigner.validate(signature: signature)
        self.request = request
        self.confirmation = confirmation
        self.signature = signature
    }
}

private struct PairClaimResponse: Decodable {
    let version: Int
    let deviceID: String
    let devicePublicKey: String
    let deviceSecret: String

    init(from decoder: Decoder) throws {
        let allFields = try decoder.container(keyedBy: AnyPairClaimCodingKey.self)
        let unexpected = allFields.allKeys
            .map(\.stringValue)
            .filter { !Self.allowedFields.contains($0) }
            .sorted()
        guard unexpected.isEmpty else {
            throw BridgeProtocolError.unknownFields(
                type: "PairClaimResponse",
                fields: unexpected
            )
        }
        let container = try decoder.container(keyedBy: PairClaimResponseCodingKey.self)
        version = try container.decode(Int.self, forKey: .version)
        deviceID = try container.decode(String.self, forKey: .deviceID)
        devicePublicKey = try container.decode(String.self, forKey: .devicePublicKey)
        deviceSecret = try container.decode(String.self, forKey: .deviceSecret)
    }

    private static let allowedFields: Set<String> = [
        "version",
        "device_id",
        "device_public_key",
        "device_secret",
    ]

    private enum PairClaimResponseCodingKey: String, CodingKey {
        case version
        case deviceID = "device_id"
        case devicePublicKey = "device_public_key"
        case deviceSecret = "device_secret"
    }
}

private struct AnyPairClaimCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
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
