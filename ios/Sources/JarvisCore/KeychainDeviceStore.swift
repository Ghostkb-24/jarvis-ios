import Foundation
import JarvisProtocol
import Security

public struct DeviceCredentials: Equatable, Sendable {
    public let deviceID: String
    public let secret: Data

    public init(deviceID: String, secret: Data) throws {
        guard !deviceID.isEmpty else { throw BridgeProtocolError.emptyField("device_id") }
        guard secret.count == 32 else { throw BridgeProtocolError.invalidSecretLength }
        self.deviceID = deviceID
        self.secret = secret
    }
}

extension DeviceCredentials: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "DeviceCredentials(deviceID: \(deviceID), secret: <redacted>)"
    }

    public var debugDescription: String { description }
}

public enum KeychainItemClass: Equatable, Sendable {
    case genericPassword
}

public enum KeychainAccessibility: Equatable, Sendable {
    case afterFirstUnlockThisDeviceOnly
}

public struct KeychainItem: Equatable, Sendable {
    public let itemClass: KeychainItemClass
    public let service: String
    public let account: String
    public let value: Data
    public let accessibility: KeychainAccessibility

    public init(
        itemClass: KeychainItemClass,
        service: String,
        account: String,
        value: Data,
        accessibility: KeychainAccessibility
    ) {
        self.itemClass = itemClass
        self.service = service
        self.account = account
        self.value = value
        self.accessibility = accessibility
    }
}

extension KeychainItem: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "KeychainItem(class: genericPassword, service: \(service), account: \(account), value: <redacted>)"
    }

    public var debugDescription: String { description }
}

public protocol SecurityItemAccess: Sendable {
    func add(_ item: KeychainItem) -> OSStatus
    func copy(service: String, account: String) -> (OSStatus, Data?)
    func update(_ item: KeychainItem) -> OSStatus
    func delete(service: String, account: String) -> OSStatus
}

public struct SystemSecurityItemAccess: SecurityItemAccess {
    public init() {}

    public func add(_ item: KeychainItem) -> OSStatus {
        SecItemAdd(attributes(for: item) as CFDictionary, nil)
    }

    public func copy(service: String, account: String) -> (OSStatus, Data?) {
        var result: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    public func update(_ item: KeychainItem) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: item.service,
            kSecAttrAccount as String: item.account,
        ]
        let changes: [String: Any] = [
            kSecValueData as String: item.value,
            kSecAttrAccessible as String: securityAccessibility(item.accessibility),
        ]
        return SecItemUpdate(query as CFDictionary, changes as CFDictionary)
    }

    public func delete(service: String, account: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        return SecItemDelete(query as CFDictionary)
    }

    private func attributes(for item: KeychainItem) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: item.service,
            kSecAttrAccount as String: item.account,
            kSecValueData as String: item.value,
            kSecAttrAccessible as String: securityAccessibility(item.accessibility),
        ]
    }

    private func securityAccessibility(_ accessibility: KeychainAccessibility) -> CFString {
        switch accessibility {
        case .afterFirstUnlockThisDeviceOnly:
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
    }
}

public enum KeychainStoreError: Error, Equatable, Sendable {
    case unexpectedStatus(operation: String, status: OSStatus)
    case invalidEncoding
    case incompleteCredentials
}

extension KeychainStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .unexpectedStatus(operation, status):
            "Keychain \(operation) failed with status \(status)"
        case .invalidEncoding:
            "Keychain credential encoding is invalid"
        case .incompleteCredentials:
            "Keychain credentials are incomplete"
        }
    }
}

public struct KeychainDeviceStore: Sendable {
    public static let credentialAccounts = [
        "device-id",
        "device-secret",
    ]

    private let service: String
    private let security: any SecurityItemAccess

    public init(
        service: String = "com.jarvis.ios.bridge",
        security: any SecurityItemAccess = SystemSecurityItemAccess()
    ) {
        self.service = service
        self.security = security
    }

    public func save(_ credentials: DeviceCredentials) throws {
        let values: [(String, Data)] = [
            (Self.credentialAccounts[0], Data(credentials.deviceID.utf8)),
            (Self.credentialAccounts[1], credentials.secret),
        ]
        for (account, value) in values {
            try write(value, account: account)
        }
    }

    public func load() throws -> DeviceCredentials? {
        let values = try Self.credentialAccounts.map { account in
            try read(account: account)
        }
        if values.allSatisfy({ $0 == nil }) {
            return nil
        }
        guard
            let deviceData = values[0],
            let secret = values[1]
        else {
            throw KeychainStoreError.incompleteCredentials
        }
        guard let deviceID = String(data: deviceData, encoding: .utf8) else {
            throw KeychainStoreError.invalidEncoding
        }
        return try DeviceCredentials(deviceID: deviceID, secret: secret)
    }

    public func delete() throws {
        for account in Self.credentialAccounts {
            let status = security.delete(service: service, account: account)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainStoreError.unexpectedStatus(operation: "delete", status: status)
            }
        }
    }

    private func write(_ value: Data, account: String) throws {
        let item = KeychainItem(
            itemClass: .genericPassword,
            service: service,
            account: account,
            value: value,
            accessibility: .afterFirstUnlockThisDeviceOnly
        )
        let addStatus = security.add(item)
        if addStatus == errSecDuplicateItem {
            let updateStatus = security.update(item)
            guard updateStatus == errSecSuccess else {
                throw KeychainStoreError.unexpectedStatus(
                    operation: "update",
                    status: updateStatus
                )
            }
        } else if addStatus != errSecSuccess {
            throw KeychainStoreError.unexpectedStatus(operation: "add", status: addStatus)
        }
    }

    private func read(account: String) throws -> Data? {
        let (status, value) = security.copy(service: service, account: account)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let value else {
            throw KeychainStoreError.unexpectedStatus(operation: "read", status: status)
        }
        return value
    }
}
