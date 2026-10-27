import Foundation
import Security

/// A saved sign-in for a source: an API key, a token, or a username and password
/// (docs/DESIGN.md, 15.8). It's kept in the Keychain, never in a scenario, and sent only to its
/// hosts, and only over HTTPS. A scenario names a saved sign-in only by its name.
public struct FeedCredential: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, CaseIterable, Sendable, Identifiable {
        /// An API key. A built-in source puts it where it wants it; another source takes it in the
        /// web address, as the parameter `name` (`?api_key=…`).
        case key
        /// A key or token in a header named `name`: `X-API-Key: …`.
        case header
        /// `Authorization: Bearer …`.
        case bearer
        /// A username and password (HTTP Basic).
        case basic

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .key: return "API key"
            case .header: return "Key in a header"
            case .bearer: return "Bearer token"
            case .basic: return "Username and password"
            }
        }
    }

    public var kind: Kind
    /// The key, token or password.
    public var secret: String
    /// For `basic`.
    public var username: String
    /// For `key`, the web address's parameter; for `header`, the header's name.
    public var name: String
    /// Where it may be sent: host names, such as `api.stlouisfed.org`.
    public var hosts: [String]

    public init(kind: Kind, secret: String, username: String = "", name: String = "", hosts: [String]) {
        self.kind = kind
        self.secret = secret
        self.username = username
        self.name = name
        self.hosts = hosts.map { $0.lowercased() }
    }

    /// Whether it may be sent with a request to this address: only to its hosts, over HTTPS.
    public func allows(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return hosts.contains(host)
    }

    /// Adds it to a request the way its kind says. Built-in sources that want a key somewhere
    /// else place it themselves.
    public func apply(to request: inout URLRequest) {
        switch kind {
        case .key:
            guard let url = request.url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
            var items = components.queryItems ?? []
            items.append(URLQueryItem(name: name.isEmpty ? "api_key" : name, value: secret))
            components.queryItems = items
            request.url = components.url
        case .header:
            request.setValue(secret, forHTTPHeaderField: name.isEmpty ? "X-API-Key" : name)
        case .bearer:
            request.setValue("Bearer " + secret, forHTTPHeaderField: "Authorization")
        case .basic:
            let pair = Data((username + ":" + secret).utf8).base64EncodedString()
            request.setValue("Basic " + pair, forHTTPHeaderField: "Authorization")
        }
    }

    /// Whether it says enough to be used.
    public var isComplete: Bool {
        switch kind {
        case .basic: return !username.isEmpty && !secret.isEmpty
        case .header: return !secret.isEmpty && !name.isEmpty
        default: return !secret.isEmpty
        }
    }
}

/// Where sign-ins are kept.
public protocol CredentialStore: Sendable {
    func credential(named name: String) throws -> FeedCredential?
    /// Whether one is saved, without reading its secret (which can make the Mac ask for permission).
    func hasCredential(named name: String) -> Bool
    func save(_ credential: FeedCredential, named name: String) throws
    func remove(named name: String) throws
}

/// Sign-ins in the Keychain, as generic passwords: the service is `service`, the account is the
/// sign-in's name, and the secret is the credential as JSON.
public final class KeychainCredentialStore: CredentialStore {
    public let service: String

    public init(service: String = "com.editthefuture.feeds") {
        self.service = service
    }

    private func query(_ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: name]
    }

    public func credential(named name: String) throws -> FeedCredential? {
        var query = query(name)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status) }
        return try JSONDecoder().decode(FeedCredential.self, from: data)
    }

    public func hasCredential(named name: String) -> Bool {
        var query = query(name)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    public func save(_ credential: FeedCredential, named name: String) throws {
        let data = try JSONEncoder().encode(credential)
        let update: [String: Any] = [kSecValueData as String: data,
                                     kSecAttrLabel as String: "Edit The Future: \(name)"]
        let status = SecItemUpdate(query(name) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(name)
            add.merge(update) { $1 }
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let added = SecItemAdd(add as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(added) }
        } else if status != errSecSuccess {
            throw KeychainError(status)
        }
    }

    public func remove(named name: String) throws {
        let status = SecItemDelete(query(name) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status) }
    }
}

public struct KeychainError: Error, CustomStringConvertible {
    public let status: OSStatus
    init(_ status: OSStatus) { self.status = status }
    public var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
        return "The Keychain said: \(message)"
    }
}

/// Sign-ins kept in memory, for tests and previews.
public final class MemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: FeedCredential]

    public init(_ items: [String: FeedCredential] = [:]) {
        self.items = items
    }

    public func credential(named name: String) throws -> FeedCredential? {
        lock.withLock { items[name] }
    }

    public func hasCredential(named name: String) -> Bool {
        lock.withLock { items[name] != nil }
    }

    public func save(_ credential: FeedCredential, named name: String) throws {
        lock.withLock { items[name] = credential }
    }

    public func remove(named name: String) throws {
        _ = lock.withLock { items.removeValue(forKey: name) }
    }
}
