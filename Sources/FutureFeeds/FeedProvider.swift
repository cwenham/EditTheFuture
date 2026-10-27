import Foundation
import FutureDocument
import FutureEngine

/// A setting a source takes, as the feed setup screen shows it (docs/UI.md, 5.10).
public struct FeedField: Sendable, Identifiable, Hashable {
    public struct Choice: Sendable, Hashable, Identifiable {
        public let value: String
        public let label: String
        public var id: String { value }
        public init(_ value: String, _ label: String) {
            self.value = value
            self.label = label
        }
    }

    /// The setting's name in `scenario.md`: `series`.
    public let key: String
    public let label: String
    public let placeholder: String
    public let help: String?
    public let required: Bool
    /// Values to pick from, when there's a short list. Others can still be typed.
    public let choices: [Choice]

    public var id: String { key }

    public init(_ key: String, _ label: String, placeholder: String = "", help: String? = nil, required: Bool = true,
                choices: [Choice] = []) {
        self.key = key
        self.label = label
        self.placeholder = placeholder
        self.help = help
        self.required = required
        self.choices = choices
    }
}

/// What a source needs to sign in.
public struct FeedSignIn: Sendable {
    public enum Need: Sendable, Equatable {
        /// It's open to everyone.
        case none
        /// It works without one, and does more with one.
        case optional
        case required
    }

    public let need: Need
    /// The kinds of sign-in it takes. Built-in sources take a key, placed where they want it.
    public let kinds: [FeedCredential.Kind]
    /// Where to get one, often for free.
    public let signUp: URL?
    /// What a sign-in changes: "Without a key, FRED's CSV download is used…"
    public let note: String?

    public init(_ need: Need, kinds: [FeedCredential.Kind] = [.key], signUp: URL? = nil, note: String? = nil) {
        self.need = need
        self.kinds = kinds
        self.signUp = signUp
        self.note = note
    }

    public static let open = FeedSignIn(.none, kinds: [])
}

/// What a source needs to build its requests.
public struct FeedRequestContext: Sendable {
    public let spec: FeedSpec
    /// Readings from this date on. nil for all of them (or from the feed's `from:`).
    public let since: Date?
    public let credential: FeedCredential?
    public let now: Date

    public init(spec: FeedSpec, since: Date? = nil, credential: FeedCredential? = nil, now: Date = Date()) {
        self.spec = spec
        self.since = since
        self.credential = credential
        self.now = now
    }

    /// The earliest reading wanted: `since`, else the feed's `from:`.
    public var earliest: Date? {
        switch (since, spec.start) {
        case let (since?, start?): return max(since, start)
        case let (since?, nil): return since
        case let (nil, start): return start
        }
    }

    /// A setting's value, without spaces at the ends; nil when it's missing or empty.
    public subscript(key: String) -> String? {
        let value = spec[key]?.trimmingCharacters(in: .whitespaces)
        return value?.isEmpty == false ? value : nil
    }

    /// A setting that must be there.
    public func required(_ key: String) throws -> String {
        guard let value = self[key] else { throw FeedError("The feed needs “\(key)”.") }
        return value
    }
}

/// One response's readings, and the request for the next page when there is one.
public struct FeedPage: Sendable {
    public var points: [FeedPoint]
    public var next: URLRequest?

    public init(points: [FeedPoint], next: URLRequest? = nil) {
        self.points = points
        self.next = next
    }
}

/// A public source of readings (docs/DESIGN.md, 15.8).
public protocol FeedProvider: Sendable {
    /// What `feed:` calls it: `fred`.
    var id: String { get }
    /// "FRED (Federal Reserve Bank of St. Louis)".
    var name: String { get }
    var summary: String { get }
    var website: URL { get }
    var fields: [FeedField] { get }
    var signIn: FeedSignIn { get }
    /// How often to check for new readings, unless the feed says (`every:`).
    var refresh: StepRate { get }
    /// Whether sign-ins are saved by host rather than for the source as a whole.
    var signsInByHost: Bool { get }

    /// The hosts a sign-in for this feed may be sent to.
    func hosts(for spec: FeedSpec) -> [String]
    /// The requests for a feed's readings, in order. Sources that page give the first and say the
    /// next with each page.
    func requests(_ context: FeedRequestContext) throws -> [URLRequest]
    func parse(_ data: Data, request: URLRequest, context: FeedRequestContext) throws -> FeedPage
    /// What the source says went wrong, from an error response.
    func errorMessage(_ data: Data, status: Int) -> String?
}

extension FeedProvider {
    /// The name its sign-in is saved under, unless the feed says (`credential:`): the source's
    /// own name, or for a feed at any web address, its host.
    public func credentialName(for spec: FeedSpec) -> String {
        if let name = spec.credentialName { return name }
        if signsInByHost, let host = hosts(for: spec).first { return host }
        return id
    }

    public var signsInByHost: Bool { false }

    public func errorMessage(_ data: Data, status: Int) -> String? {
        FeedProviders.commonErrorMessage(data)
    }
}

/// The built-in sources.
public enum FeedProviders {
    public static let all: [any FeedProvider] = [
        FREDProvider(), TreasuryProvider(), WorldBankProvider(), BLSProvider(), NOAAProvider(), OpenMeteoProvider(),
        SocrataProvider(), TiingoProvider(), CSVProvider(), JSONProvider(),
    ]

    public static func named(_ id: String) -> (any FeedProvider)? {
        all.first { $0.id == id.lowercased() }
    }

    /// A GET request for an address made of parts, with a time limit.
    static func request(_ base: String, _ items: [(String, String?)] = []) throws -> URLRequest {
        guard var components = URLComponents(string: base) else { throw FeedError("“\(base)” isn't a web address.") }
        let query = items.compactMap { name, value in value.map { URLQueryItem(name: name, value: $0) } }
        if !query.isEmpty { components.queryItems = (components.queryItems ?? []) + query }
        // URLComponents leaves "+" alone, which servers read as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw FeedError("“\(base)” isn't a web address.") }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("EditTheFuture/0.1 (data feeds)", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// The usual places sources put an error: `message`, `error_message`, `reason`, `detail`.
    static func commonErrorMessage(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        for key in ["error_message", "message", "reason", "detail", "error"] {
            if let text = JSONPath.value(key, in: json) as? String, !text.isEmpty { return trimmed(text) }
        }
        if let list = (json as? [Any])?.first.flatMap({ JSONPath.value("message.0.value", in: $0) }) as? String { return trimmed(list) }
        return nil
    }

    static func trimmed(_ text: String) -> String {
        let single = text.replacingOccurrences(of: "\n", with: " ")
        return single.count > 200 ? String(single.prefix(200)) + "…" : single
    }
}
