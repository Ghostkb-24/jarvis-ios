import Foundation

public enum BridgeProtocolError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
    case emptyField(String)
    case invalidJSONNumber
    case invalidSecretLength
    case invalidSignature
    case invalidFingerprint
    case invalidTimestamp(field: String)
    case staleMessage(field: String)
    case unknownFields(type: String, fields: [String])
    case unknownEnumValue(type: String, value: String)
}

extension BridgeProtocolError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion:
            "Unsupported Bridge protocol version"
        case let .emptyField(field):
            "Bridge protocol field is empty: \(field)"
        case .invalidJSONNumber:
            "Bridge payload contains a non-finite JSON number"
        case .invalidSecretLength:
            "Device secret must contain exactly 32 bytes"
        case .invalidSignature:
            "Request signature must be 64 lowercase hexadecimal characters"
        case .invalidFingerprint:
            "Certificate fingerprint must be 64 lowercase hexadecimal characters"
        case let .invalidTimestamp(field):
            "Bridge protocol timestamp is invalid: \(field)"
        case let .staleMessage(field):
            "Bridge protocol message is stale: \(field)"
        case let .unknownFields(type, fields):
            "Unknown \(type) fields: \(fields.joined(separator: ", "))"
        case let .unknownEnumValue(type, value):
            "Unknown \(type) wire value: \(value)"
        }
    }
}

public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case string(String)
    case integer(Int64)
    case double(Double)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            guard value.isFinite else { throw BridgeProtocolError.invalidJSONNumber }
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported Bridge JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .integer(value):
            try container.encode(value)
        case let .double(value):
            guard value.isFinite else { throw BridgeProtocolError.invalidJSONNumber }
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }
}

public enum RequestKind: String, Codable, CaseIterable, Sendable {
    case chat
    case tool
    case confirm
    case cancel

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let decoded = Self(rawValue: value) else {
            throw BridgeProtocolError.unknownEnumValue(type: "RequestKind", value: value)
        }
        self = decoded
    }
}

public enum TaskState: String, Codable, CaseIterable, Sendable {
    case preparing
    case awaitingConfirmation = "awaiting_confirmation"
    case executing
    case completed
    case failed
    case cancelled
    case resultUnknown = "result_unknown"

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let decoded = Self(rawValue: value) else {
            throw BridgeProtocolError.unknownEnumValue(type: "TaskState", value: value)
        }
        self = decoded
    }
}

public enum Risk: String, Codable, CaseIterable, Sendable {
    case low
    case confirmationRequired = "confirmation_required"

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let decoded = Self(rawValue: value) else {
            throw BridgeProtocolError.unknownEnumValue(type: "Risk", value: value)
        }
        self = decoded
    }
}

public enum ConfirmationDecision: String, Codable, CaseIterable, Sendable {
    case approve
    case decline

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let decoded = Self(rawValue: value) else {
            throw BridgeProtocolError.unknownEnumValue(type: "ConfirmationDecision", value: value)
        }
        self = decoded
    }
}

public enum RejectionReason: String, Codable, CaseIterable, Sendable {
    case confirmationDeclined = "confirmation_declined"
    case paymentBlocked = "payment_blocked"
    case fileDeletionBlocked = "file_deletion_blocked"
    case passwordEntryBlocked = "password_entry_blocked"
    case malformedRequest = "malformed_request"
    case staleRequest = "stale_request"
    case invalidSignature = "invalid_signature"
    case duplicateRequest = "duplicate_request"
    case unsupportedOperation = "unsupported_operation"

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let decoded = Self(rawValue: value) else {
            throw BridgeProtocolError.unknownEnumValue(type: "RejectionReason", value: value)
        }
        self = decoded
    }
}

public struct BridgeRequest: Codable, Equatable, Sendable {
    public let version: Int
    public let requestID: String
    public let deviceID: String
    public let issuedAt: String
    public let idempotencyKey: String
    public let kind: RequestKind
    public let payload: [String: JSONValue]

    public init(
        version: Int,
        requestID: String,
        deviceID: String,
        issuedAt: String,
        idempotencyKey: String,
        kind: RequestKind,
        payload: [String: JSONValue]
    ) throws {
        guard version == 1 else { throw BridgeProtocolError.unsupportedVersion(version) }
        try Self.requireNonempty(requestID, field: "request_id")
        try Self.requireNonempty(deviceID, field: "device_id")
        try Self.requireNonempty(issuedAt, field: "issued_at")
        try Self.requireNonempty(idempotencyKey, field: "idempotency_key")
        self.version = version
        self.requestID = requestID
        self.deviceID = deviceID
        self.issuedAt = issuedAt
        self.idempotencyKey = idempotencyKey
        self.kind = kind
        self.payload = payload
    }

    public init(from decoder: Decoder) throws {
        try validateNoUnknownFields(
            decoder,
            type: "BridgeRequest",
            allowed: [
                "version", "request_id", "device_id", "issued_at",
                "idempotency_key", "kind", "payload",
            ]
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            version: container.decode(Int.self, forKey: .version),
            requestID: container.decode(String.self, forKey: .requestID),
            deviceID: container.decode(String.self, forKey: .deviceID),
            issuedAt: container.decode(String.self, forKey: .issuedAt),
            idempotencyKey: container.decode(String.self, forKey: .idempotencyKey),
            kind: container.decode(RequestKind.self, forKey: .kind),
            payload: container.decode([String: JSONValue].self, forKey: .payload)
        )
    }

    public func canonicalData() throws -> Data {
        let object: [String: JSONValue] = [
            "version": .integer(Int64(version)),
            "request_id": .string(requestID),
            "device_id": .string(deviceID),
            "issued_at": .string(issuedAt),
            "idempotency_key": .string(idempotencyKey),
            "kind": .string(kind.rawValue),
            "payload": .object(payload),
        ]
        return Data(try CanonicalJSON.serialize(.object(object)).utf8)
    }

    private static func requireNonempty(_ value: String, field: String) throws {
        guard !value.isEmpty else { throw BridgeProtocolError.emptyField(field) }
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case requestID = "request_id"
        case deviceID = "device_id"
        case issuedAt = "issued_at"
        case idempotencyKey = "idempotency_key"
        case kind
        case payload
    }
}

extension BridgeRequest: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "BridgeRequest(version: \(version), requestID: \(requestID), kind: \(kind.rawValue), payload: <redacted>)"
    }

    public var debugDescription: String { description }
}

public struct BridgeResponse: Codable, Equatable, Sendable {
    public let version: Int
    public let requestID: String
    public let state: TaskState
    public let risk: Risk
    public let payload: [String: JSONValue]

    public init(
        version: Int,
        requestID: String,
        state: TaskState,
        risk: Risk,
        payload: [String: JSONValue]
    ) throws {
        guard version == 1 else { throw BridgeProtocolError.unsupportedVersion(version) }
        guard !requestID.isEmpty else { throw BridgeProtocolError.emptyField("request_id") }
        self.version = version
        self.requestID = requestID
        self.state = state
        self.risk = risk
        self.payload = payload
    }

    public init(from decoder: Decoder) throws {
        try validateNoUnknownFields(
            decoder,
            type: "BridgeResponse",
            allowed: ["version", "request_id", "state", "risk", "payload"]
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            version: container.decode(Int.self, forKey: .version),
            requestID: container.decode(String.self, forKey: .requestID),
            state: container.decode(TaskState.self, forKey: .state),
            risk: container.decode(Risk.self, forKey: .risk),
            payload: container.decode([String: JSONValue].self, forKey: .payload)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case requestID = "request_id"
        case state
        case risk
        case payload
    }
}

public struct SignedRequestEnvelope: Codable, Equatable, Sendable {
    public let request: BridgeRequest
    public let signature: String

    public init(request: BridgeRequest, signature: String) throws {
        try RequestSigner.validate(signature: signature)
        self.request = request
        self.signature = signature
    }
}

public struct DiscoveryMessage: Codable, Equatable, Sendable {
    public let version: Int
    public let bridgeID: String
    public let bridgeURL: String
    public let certificateFingerprint: String
    public let displayName: String
    public let requiresPairing: Bool

    public init(
        version: Int,
        bridgeID: String,
        bridgeURL: String,
        certificateFingerprint: String,
        displayName: String,
        requiresPairing: Bool
    ) throws {
        try validateVersion(version)
        try requireNonempty(bridgeID, field: "bridge_id")
        try requireNonempty(bridgeURL, field: "bridge_url")
        try requireNonempty(displayName, field: "display_name")
        try ProtocolValidation.validateFingerprint(certificateFingerprint)
        self.version = version
        self.bridgeID = bridgeID
        self.bridgeURL = bridgeURL
        self.certificateFingerprint = certificateFingerprint
        self.displayName = displayName
        self.requiresPairing = requiresPairing
    }

    public init(from decoder: Decoder) throws {
        try validateNoUnknownFields(
            decoder,
            type: "DiscoveryMessage",
            allowed: [
                "version",
                "bridge_id",
                "bridge_url",
                "certificate_sha256",
                "display_name",
                "requires_pairing",
            ]
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            version: container.decode(Int.self, forKey: .version),
            bridgeID: container.decode(String.self, forKey: .bridgeID),
            bridgeURL: container.decode(String.self, forKey: .bridgeURL),
            certificateFingerprint: container.decode(String.self, forKey: .certificateFingerprint),
            displayName: container.decode(String.self, forKey: .displayName),
            requiresPairing: container.decode(Bool.self, forKey: .requiresPairing)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case bridgeID = "bridge_id"
        case bridgeURL = "bridge_url"
        case certificateFingerprint = "certificate_sha256"
        case displayName = "display_name"
        case requiresPairing = "requires_pairing"
    }
}

public struct PairingPayload: Codable, Equatable, Sendable {
    public let version: Int
    public let bridgeID: String
    public let bridgeURL: String
    public let certificateFingerprint: String
    public let sessionID: String
    public let expiresAt: String
    public let proof: String

    public init(
        version: Int,
        bridgeID: String,
        bridgeURL: String,
        certificateFingerprint: String,
        sessionID: String,
        expiresAt: String,
        proof: String
    ) throws {
        guard version == 1 else { throw BridgeProtocolError.unsupportedVersion(version) }
        for (value, field) in [
            (bridgeID, "bridge_id"),
            (bridgeURL, "bridge_url"),
            (sessionID, "session_id"),
            (expiresAt, "expires_at"),
            (proof, "proof"),
        ] {
            guard !value.isEmpty else { throw BridgeProtocolError.emptyField(field) }
        }
        try ProtocolValidation.validateFingerprint(certificateFingerprint)
        self.version = version
        self.bridgeID = bridgeID
        self.bridgeURL = bridgeURL
        self.certificateFingerprint = certificateFingerprint
        self.sessionID = sessionID
        self.expiresAt = expiresAt
        self.proof = proof
    }

    public init(from decoder: Decoder) throws {
        try validateNoUnknownFields(
            decoder,
            type: "PairingPayload",
            allowed: [
                "version", "bridge_id", "bridge_url", "certificate_sha256",
                "session_id", "expires_at", "proof",
            ]
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            version: container.decode(Int.self, forKey: .version),
            bridgeID: container.decode(String.self, forKey: .bridgeID),
            bridgeURL: container.decode(String.self, forKey: .bridgeURL),
            certificateFingerprint: container.decode(String.self, forKey: .certificateFingerprint),
            sessionID: container.decode(String.self, forKey: .sessionID),
            expiresAt: container.decode(String.self, forKey: .expiresAt),
            proof: container.decode(String.self, forKey: .proof)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case bridgeID = "bridge_id"
        case bridgeURL = "bridge_url"
        case certificateFingerprint = "certificate_sha256"
        case sessionID = "session_id"
        case expiresAt = "expires_at"
        case proof
    }
}

public struct PairingChallenge: Codable, Equatable, Sendable {
    public let version: Int
    public let sessionID: String
    public let bridgeID: String
    public let pairingCode: String
    public let challengeNonce: String
    public let issuedAt: String
    public let expiresAt: String

    public init(
        version: Int,
        sessionID: String,
        bridgeID: String,
        pairingCode: String,
        challengeNonce: String,
        issuedAt: String,
        expiresAt: String
    ) throws {
        try validateVersion(version)
        try requireNonempty(sessionID, field: "session_id")
        try requireNonempty(bridgeID, field: "bridge_id")
        try requireNonempty(pairingCode, field: "pairing_code")
        try requireNonempty(challengeNonce, field: "challenge_nonce")
        _ = try ProtocolValidation.parseTimestamp(issuedAt, field: "issued_at")
        _ = try ProtocolValidation.parseTimestamp(expiresAt, field: "expires_at")
        self.version = version
        self.sessionID = sessionID
        self.bridgeID = bridgeID
        self.pairingCode = pairingCode
        self.challengeNonce = challengeNonce
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }

    public init(from decoder: Decoder) throws {
        try validateNoUnknownFields(
            decoder,
            type: "PairingChallenge",
            allowed: [
                "version",
                "session_id",
                "bridge_id",
                "pairing_code",
                "challenge_nonce",
                "issued_at",
                "expires_at",
            ]
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            version: container.decode(Int.self, forKey: .version),
            sessionID: container.decode(String.self, forKey: .sessionID),
            bridgeID: container.decode(String.self, forKey: .bridgeID),
            pairingCode: container.decode(String.self, forKey: .pairingCode),
            challengeNonce: container.decode(String.self, forKey: .challengeNonce),
            issuedAt: container.decode(String.self, forKey: .issuedAt),
            expiresAt: container.decode(String.self, forKey: .expiresAt)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case sessionID = "session_id"
        case bridgeID = "bridge_id"
        case pairingCode = "pairing_code"
        case challengeNonce = "challenge_nonce"
        case issuedAt = "issued_at"
        case expiresAt = "expires_at"
    }
}

public struct PairingChallengeResponse: Codable, Equatable, Sendable {
    public let version: Int
    public let sessionID: String
    public let deviceName: String
    public let pairingCode: String
    public let challengeNonce: String
    public let issuedAt: String

    public init(
        version: Int,
        sessionID: String,
        deviceName: String,
        pairingCode: String,
        challengeNonce: String,
        issuedAt: String
    ) throws {
        try validateVersion(version)
        try requireNonempty(sessionID, field: "session_id")
        try requireNonempty(deviceName, field: "device_name")
        try requireNonempty(pairingCode, field: "pairing_code")
        try requireNonempty(challengeNonce, field: "challenge_nonce")
        _ = try ProtocolValidation.parseTimestamp(issuedAt, field: "issued_at")
        self.version = version
        self.sessionID = sessionID
        self.deviceName = deviceName
        self.pairingCode = pairingCode
        self.challengeNonce = challengeNonce
        self.issuedAt = issuedAt
    }

    public init(from decoder: Decoder) throws {
        try validateNoUnknownFields(
            decoder,
            type: "PairingChallengeResponse",
            allowed: [
                "version",
                "session_id",
                "device_name",
                "pairing_code",
                "challenge_nonce",
                "issued_at",
            ]
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            version: container.decode(Int.self, forKey: .version),
            sessionID: container.decode(String.self, forKey: .sessionID),
            deviceName: container.decode(String.self, forKey: .deviceName),
            pairingCode: container.decode(String.self, forKey: .pairingCode),
            challengeNonce: container.decode(String.self, forKey: .challengeNonce),
            issuedAt: container.decode(String.self, forKey: .issuedAt)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case sessionID = "session_id"
        case deviceName = "device_name"
        case pairingCode = "pairing_code"
        case challengeNonce = "challenge_nonce"
        case issuedAt = "issued_at"
    }
}

public struct TaskSubmission: Codable, Equatable, Sendable {
    public let version: Int
    public let request: BridgeRequest
    public let expectsConfirmation: Bool

    public init(
        version: Int = 1,
        request: BridgeRequest,
        expectsConfirmation: Bool
    ) throws {
        try validateVersion(version)
        self.version = version
        self.request = request
        self.expectsConfirmation = expectsConfirmation
    }

    public init(from decoder: Decoder) throws {
        try validateNoUnknownFields(
            decoder,
            type: "TaskSubmission",
            allowed: ["version", "request", "expects_confirmation"]
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            version: container.decode(Int.self, forKey: .version),
            request: container.decode(BridgeRequest.self, forKey: .request),
            expectsConfirmation: container.decode(Bool.self, forKey: .expectsConfirmation)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case request
        case expectsConfirmation = "expects_confirmation"
    }
}

public struct TaskPreview: Codable, Equatable, Sendable {
    public let version: Int
    public let requestID: String
    public let taskID: String
    public let risk: Risk
    public let title: String
    public let summary: String
    public let action: String
    public let target: String
    public let arguments: [String: JSONValue]

    public init(
        version: Int,
        requestID: String,
        taskID: String,
        risk: Risk,
        title: String,
        summary: String,
        action: String,
        target: String,
        arguments: [String: JSONValue]
    ) throws {
        try validateVersion(version)
        try requireNonempty(requestID, field: "request_id")
        try requireNonempty(taskID, field: "task_id")
        try requireNonempty(title, field: "title")
        try requireNonempty(summary, field: "summary")
        try requireNonempty(action, field: "action")
        try requireNonempty(target, field: "target")
        self.version = version
        self.requestID = requestID
        self.taskID = taskID
        self.risk = risk
        self.title = title
        self.summary = summary
        self.action = action
        self.target = target
        self.arguments = arguments
    }

    public init(from decoder: Decoder) throws {
        try validateNoUnknownFields(
            decoder,
            type: "TaskPreview",
            allowed: [
                "version",
                "request_id",
                "task_id",
                "risk",
                "title",
                "summary",
                "action",
                "target",
                "arguments",
            ]
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            version: container.decode(Int.self, forKey: .version),
            requestID: container.decode(String.self, forKey: .requestID),
            taskID: container.decode(String.self, forKey: .taskID),
            risk: container.decode(Risk.self, forKey: .risk),
            title: container.decode(String.self, forKey: .title),
            summary: container.decode(String.self, forKey: .summary),
            action: container.decode(String.self, forKey: .action),
            target: container.decode(String.self, forKey: .target),
            arguments: container.decode([String: JSONValue].self, forKey: .arguments)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case requestID = "request_id"
        case taskID = "task_id"
        case risk
        case title
        case summary
        case action
        case target
        case arguments
    }
}

public struct TaskConfirmation: Codable, Equatable, Sendable {
    public let version: Int
    public let requestID: String
    public let taskID: String
    public let decision: ConfirmationDecision
    public let decidedAt: String

    public init(
        version: Int,
        requestID: String,
        taskID: String,
        decision: ConfirmationDecision,
        decidedAt: String
    ) throws {
        try validateVersion(version)
        try requireNonempty(requestID, field: "request_id")
        try requireNonempty(taskID, field: "task_id")
        _ = try ProtocolValidation.parseTimestamp(decidedAt, field: "decided_at")
        self.version = version
        self.requestID = requestID
        self.taskID = taskID
        self.decision = decision
        self.decidedAt = decidedAt
    }

    public init(from decoder: Decoder) throws {
        try validateNoUnknownFields(
            decoder,
            type: "TaskConfirmation",
            allowed: ["version", "request_id", "task_id", "decision", "decided_at"]
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            version: container.decode(Int.self, forKey: .version),
            requestID: container.decode(String.self, forKey: .requestID),
            taskID: container.decode(String.self, forKey: .taskID),
            decision: container.decode(ConfirmationDecision.self, forKey: .decision),
            decidedAt: container.decode(String.self, forKey: .decidedAt)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case requestID = "request_id"
        case taskID = "task_id"
        case decision
        case decidedAt = "decided_at"
    }
}

public struct TaskProgress: Codable, Equatable, Sendable {
    public let version: Int
    public let requestID: String
    public let taskID: String
    public let state: TaskState
    public let progressMessage: String
    public let eventIndex: Int

    public init(
        version: Int,
        requestID: String,
        taskID: String,
        state: TaskState,
        progressMessage: String,
        eventIndex: Int
    ) throws {
        try validateVersion(version)
        try requireNonempty(requestID, field: "request_id")
        try requireNonempty(taskID, field: "task_id")
        try requireNonempty(progressMessage, field: "progress_message")
        self.version = version
        self.requestID = requestID
        self.taskID = taskID
        self.state = state
        self.progressMessage = progressMessage
        self.eventIndex = eventIndex
    }

    public init(from decoder: Decoder) throws {
        try validateNoUnknownFields(
            decoder,
            type: "TaskProgress",
            allowed: [
                "version",
                "request_id",
                "task_id",
                "state",
                "progress_message",
                "event_index",
            ]
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            version: container.decode(Int.self, forKey: .version),
            requestID: container.decode(String.self, forKey: .requestID),
            taskID: container.decode(String.self, forKey: .taskID),
            state: container.decode(TaskState.self, forKey: .state),
            progressMessage: container.decode(String.self, forKey: .progressMessage),
            eventIndex: container.decode(Int.self, forKey: .eventIndex)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case requestID = "request_id"
        case taskID = "task_id"
        case state
        case progressMessage = "progress_message"
        case eventIndex = "event_index"
    }
}

public struct TaskTerminalResult: Codable, Equatable, Sendable {
    public let version: Int
    public let requestID: String
    public let taskID: String
    public let state: TaskState
    public let summary: String
    public let output: [String: JSONValue]

    public init(
        version: Int,
        requestID: String,
        taskID: String,
        state: TaskState,
        summary: String,
        output: [String: JSONValue]
    ) throws {
        try validateVersion(version)
        try requireNonempty(requestID, field: "request_id")
        try requireNonempty(taskID, field: "task_id")
        try requireNonempty(summary, field: "summary")
        self.version = version
        self.requestID = requestID
        self.taskID = taskID
        self.state = state
        self.summary = summary
        self.output = output
    }

    public init(from decoder: Decoder) throws {
        try validateNoUnknownFields(
            decoder,
            type: "TaskTerminalResult",
            allowed: ["version", "request_id", "task_id", "state", "summary", "output"]
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            version: container.decode(Int.self, forKey: .version),
            requestID: container.decode(String.self, forKey: .requestID),
            taskID: container.decode(String.self, forKey: .taskID),
            state: container.decode(TaskState.self, forKey: .state),
            summary: container.decode(String.self, forKey: .summary),
            output: container.decode([String: JSONValue].self, forKey: .output)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case requestID = "request_id"
        case taskID = "task_id"
        case state
        case summary
        case output
    }
}

public struct TaskRejection: Codable, Equatable, Sendable {
    public let version: Int
    public let requestID: String
    public let taskID: String
    public let reason: RejectionReason
    public let message: String
    public let retryable: Bool

    public init(
        version: Int,
        requestID: String,
        taskID: String,
        reason: RejectionReason,
        message: String,
        retryable: Bool
    ) throws {
        try validateVersion(version)
        try requireNonempty(requestID, field: "request_id")
        try requireNonempty(taskID, field: "task_id")
        try requireNonempty(message, field: "message")
        self.version = version
        self.requestID = requestID
        self.taskID = taskID
        self.reason = reason
        self.message = message
        self.retryable = retryable
    }

    public init(from decoder: Decoder) throws {
        try validateNoUnknownFields(
            decoder,
            type: "TaskRejection",
            allowed: ["version", "request_id", "task_id", "reason", "message", "retryable"]
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            version: container.decode(Int.self, forKey: .version),
            requestID: container.decode(String.self, forKey: .requestID),
            taskID: container.decode(String.self, forKey: .taskID),
            reason: container.decode(RejectionReason.self, forKey: .reason),
            message: container.decode(String.self, forKey: .message),
            retryable: container.decode(Bool.self, forKey: .retryable)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case requestID = "request_id"
        case taskID = "task_id"
        case reason
        case message
        case retryable
    }
}

private struct AnyProtocolCodingKey: CodingKey {
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

private func validateNoUnknownFields(
    _ decoder: Decoder,
    type: String,
    allowed: Set<String>
) throws {
    let container = try decoder.container(keyedBy: AnyProtocolCodingKey.self)
    let unexpected = container.allKeys
        .map(\.stringValue)
        .filter { !allowed.contains($0) }
        .sorted()
    guard unexpected.isEmpty else {
        throw BridgeProtocolError.unknownFields(type: type, fields: unexpected)
    }
}

extension PairingPayload: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "PairingPayload(version: \(version), bridgeID: \(bridgeID), sensitiveFields: <redacted>)"
    }

    public var debugDescription: String { description }
}

public enum ProtocolValidation {
    public static func parseTimestamp(_ value: String, field: String) throws -> Date {
        guard let timestamp = TimestampParser.parse(value) else {
            throw BridgeProtocolError.invalidTimestamp(field: field)
        }
        return timestamp
    }

    public static func validateTimestamp(
        _ value: String,
        field: String,
        now: Date,
        maxAge: TimeInterval,
        maxFutureSkew: TimeInterval
    ) throws -> Date {
        let timestamp = try parseTimestamp(value, field: field)
        guard timestamp.timeIntervalSince(now) <= maxFutureSkew,
              now.timeIntervalSince(timestamp) <= maxAge
        else {
            throw BridgeProtocolError.staleMessage(field: field)
        }
        return timestamp
    }

    public static func validateFingerprint(_ value: String) throws {
        guard isLowercaseHex(value, length: 64) else {
            throw BridgeProtocolError.invalidFingerprint
        }
    }

    public static func isLowercaseHex(_ value: String, length: Int) -> Bool {
        value.utf8.count == length
            && value.utf8.allSatisfy { byte in
                (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
            }
    }
}

private enum TimestampParser {
    static func parse(_ value: String) -> Date? {
        internetDateTime.date(from: value) ?? fractionalInternetDateTime.date(from: value)
    }

    private static let internetDateTime: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let fractionalInternetDateTime: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private func validateVersion(_ version: Int) throws {
    guard version == 1 else { throw BridgeProtocolError.unsupportedVersion(version) }
}

private func requireNonempty(_ value: String, field: String) throws {
    guard !value.isEmpty else { throw BridgeProtocolError.emptyField(field) }
}

private enum CanonicalJSON {
    static func serialize(_ value: JSONValue) throws -> String {
        switch value {
        case .null:
            "null"
        case let .bool(value):
            value ? "true" : "false"
        case let .string(value):
            "\"\(escape(value))\""
        case let .integer(value):
            String(value)
        case let .double(value):
            try serialize(value)
        case let .array(values):
            try "[" + values.map(serialize).joined(separator: ",") + "]"
        case let .object(object):
            try "{" + object.sorted { lhs, rhs in
                pythonKeyOrder(lhs.key, rhs.key)
            }.map { entry in
                "\"\(escape(entry.key))\":\(try serialize(entry.value))"
            }.joined(separator: ",") + "}"
        }
    }

    private static func serialize(_ value: Double) throws -> String {
        guard value.isFinite else { throw BridgeProtocolError.invalidJSONNumber }
        return String(value)
    }

    private static func pythonKeyOrder(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }

    private static func escape(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.utf8.count)
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08:
                escaped += "\\b"
            case 0x09:
                escaped += "\\t"
            case 0x0A:
                escaped += "\\n"
            case 0x0C:
                escaped += "\\f"
            case 0x0D:
                escaped += "\\r"
            case 0x22:
                escaped += "\\\""
            case 0x5C:
                escaped += "\\\\"
            case 0x20 ... 0x7E:
                escaped.unicodeScalars.append(scalar)
            case 0 ... 0xFFFF:
                escaped += String(format: "\\u%04x", scalar.value)
            default:
                let adjusted = scalar.value - 0x1_0000
                let high = 0xD800 + (adjusted >> 10)
                let low = 0xDC00 + (adjusted & 0x3FF)
                escaped += String(format: "\\u%04x\\u%04x", high, low)
            }
        }
        return escaped
    }
}
