import Foundation
import FutureDocument
import FutureEngine

/// Sends a request and gets the answer. Tests use one that answers from fixtures.
public protocol FeedTransport: Sendable {
    /// - Parameter redirectHosts: when a sign-in went with the request, the only hosts a redirect
    ///   may lead to. nil allows any.
    func data(for request: URLRequest, redirectHosts: Set<String>?) async throws -> (Data, HTTPURLResponse)
}

/// The network, through `URLSession`, without cookies or a cache of its own.
public final class URLSessionTransport: FeedTransport {
    /// The most a response may hold.
    public static let byteLimit = 64 * 1024 * 1024
    /// One for the app, so connections are shared.
    public static let shared = URLSessionTransport()

    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 180
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    public func data(for request: URLRequest, redirectHosts: Set<String>?) async throws -> (Data, HTTPURLResponse) {
        let guardian = RedirectGuard(hosts: redirectHosts)
        let (bytes, response) = try await session.bytes(for: request, delegate: guardian)
        guard let http = response as? HTTPURLResponse else { throw FeedError("The source didn't answer over HTTP.") }
        if http.expectedContentLength > Self.byteLimit { throw FeedError("The source's answer is too big (over 64 MB).") }
        var data = Data()
        data.reserveCapacity(max(0, Int(min(http.expectedContentLength, 8 * 1024 * 1024))))
        for try await byte in bytes {
            data.append(byte)
            if data.count > Self.byteLimit { throw FeedError("The source's answer is too big (over 64 MB).") }
        }
        return (data, http)
    }
}

/// Stops a redirect that would carry a sign-in to another host.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let hosts: Set<String>?

    init(hosts: Set<String>?) {
        self.hosts = hosts
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let hosts else { return request }
        guard request.url?.scheme?.lowercased() == "https", let host = request.url?.host?.lowercased(), hosts.contains(host)
        else { return nil }
        return request
    }
}

/// Fetches a feed's readings (docs/DESIGN.md, 15.8): looks up its source and sign-in, sends the
/// requests, follows pages, and reads the answers.
public struct FeedFetcher: Sendable {
    public let transport: any FeedTransport
    public let credentials: any CredentialStore
    /// The most pages one fetch follows.
    public static let pageLimit = 200

    public init(transport: any FeedTransport = URLSessionTransport(), credentials: any CredentialStore = KeychainCredentialStore()) {
        self.transport = transport
        self.credentials = credentials
    }

    /// The feed's readings from `since` on (all of them when nil), in time order, as the source
    /// gives them, before `convert` and `scale`.
    public func fetch(_ spec: FeedSpec, since: Date? = nil, now: Date = Date()) async throws -> [FeedPoint] {
        guard let provider = FeedProviders.named(spec.provider) else {
            throw FeedError("There's no source called “\(spec.provider)”.")
        }
        for field in provider.fields where field.required && (spec[field.key] ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            throw FeedError("\(provider.name) needs “\(field.label)” (\(field.key)).")
        }
        let name = provider.credentialName(for: spec)
        var credential: FeedCredential?
        if provider.signIn.need != .none {
            do {
                credential = try credentials.credential(named: name)
            } catch {
                throw FeedError("Couldn't read the sign-in for \(provider.name): \(error)")
            }
            if let found = credential, !found.isComplete { credential = nil }
        }
        if provider.signIn.need == .required && credential == nil {
            throw FeedError("\(provider.name) needs an API key. Add one in the feed's settings.")
        }
        let context = FeedRequestContext(spec: spec, since: since, credential: credential, now: now)
        var queue = try provider.requests(context)
        var points: [FeedPoint] = []
        var pages = 0
        while !queue.isEmpty {
            let request = queue.removeFirst()
            pages += 1
            guard pages <= Self.pageLimit else { throw FeedError("The source sent more than \(Self.pageLimit) pages.") }
            if let credential, !credential.allows(request.url) {
                throw FeedError("The sign-in “\(name)” can only be sent to \(credential.hosts.joined(separator: ", ")) over HTTPS, "
                                + "not to \(request.url?.host ?? "this address").")
            }
            let (data, response) = try await send(request, credential: credential)
            guard (200..<300).contains(response.statusCode) else {
                let reason = provider.errorMessage(data, status: response.statusCode)
                // A feed at any web address is named by its host.
                let who = provider.signsInByHost ? request.url?.host ?? provider.name : provider.name
                throw FeedError(Self.statusMessage(response.statusCode, provider: who, reason: reason))
            }
            let page = try provider.parse(data, request: request, context: context)
            points += page.points
            if let next = page.next { queue.insert(next, at: 0) }
        }
        return FeedCopy.cleaned(points)
    }

    func send(_ request: URLRequest, credential: FeedCredential?) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport.data(for: request, redirectHosts: credential.map { Set($0.hosts) })
        } catch let error as FeedError {
            throw error
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost: throw FeedError("This Mac isn't online.")
            case .timedOut: throw FeedError("\(request.url?.host ?? "The source") took too long to answer.")
            case .cannotFindHost, .dnsLookupFailed: throw FeedError("Couldn't find \(request.url?.host ?? "the source").")
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate:
                throw FeedError("\(request.url?.host ?? "The source")'s secure connection couldn't be checked.")
            default: throw FeedError(error.localizedDescription)
            }
        }
    }

    static func statusMessage(_ status: Int, provider: String, reason: String?) -> String {
        let what: String
        switch status {
        case 400: what = "didn't accept the request"
        case 401, 403: what = "refused the sign-in, or needs one"
        case 404: what = "has nothing at that address"
        case 429: what = "is asking for fewer requests. It will be tried again later"
        case 500...599: what = "had a problem of its own"
        default: what = "answered with error \(status)"
        }
        return "\(provider) \(what)" + (reason.map { ": \($0)" } ?? ".")
    }
}
