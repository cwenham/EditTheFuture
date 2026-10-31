#if os(macOS)
import Darwin
import Foundation
import Security

/// The local socket the `etf` command-line tool reaches the app through (docs/DESIGN.md, 10.2 and 13).
///
/// A private Unix socket rather than XPC: an XPC service needs a launch agent registered with
/// macOS, which shows in Login Items. The rule is the same either way: the app checks each caller's
/// code signature before reading anything from it (`CallerCheck`).
public enum CommandSocket {
    public static let fileName = "commands.sock"

    /// `~/Library/Application Support/Edit The Future/commands.sock`, or the per-user cache folder
    /// when that's too long for a socket's address.
    public static var defaultPath: String {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Edit The Future", isDirectory: true)
        let path = folder.appendingPathComponent(fileName).path
        if path.utf8.count <= maxPathLength { return path }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, buffer.count) > 0 {
            let cache = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            return (cache as NSString).appendingPathComponent("EditTheFuture-" + fileName)
        }
        return path
    }

    /// A socket's address holds 104 bytes, with the zero at the end.
    public static let maxPathLength = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

    static func address(_ path: String) throws(CommandSocketError) -> sockaddr_un {
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, bytes.count <= maxPathLength else { throw .pathTooLong(path) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }

    static func setTimeout(_ seconds: TimeInterval, _ option: Int32, on socket: Int32) {
        var time = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - seconds.rounded(.down)) * 1_000_000))
        setsockopt(socket, SOL_SOCKET, option, &time, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Makes writing to a socket whose other end has gone fail, rather than stop the process with
    /// SIGPIPE. Fails when the other end has already hung up: macOS refuses socket options then,
    /// so nothing may be written to that socket.
    static func preventSigpipe(on socket: Int32) -> Bool {
        var on: Int32 = 1
        return setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0
    }

    /// Writes a message: its length as four bytes, high byte first, then the message.
    static func send(_ data: Data, on socket: Int32) throws(CommandSocketError) {
        var length = UInt32(data.count).bigEndian
        let header = withUnsafeBytes(of: &length) { Data($0) }
        try writeAll(header + data, to: socket)
    }

    /// Reads one message, refusing any longer than `limit`.
    static func receive(on socket: Int32, limit: Int) throws(CommandSocketError) -> Data {
        let header = try read(4, from: socket)
        let length = header.reduce(0) { ($0 << 8) | Int($1) }
        guard length <= limit else { throw .tooLarge }
        return try read(length, from: socket)
    }

    private static func writeAll(_ data: Data, to socket: Int32) throws(CommandSocketError) {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { raw in
                Darwin.write(socket, raw.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if written < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN { throw .timedOut }
                if errno == EPIPE || errno == ECONNRESET { throw .closed }
                throw .system("write", errno)
            }
            offset += written
        }
    }

    private static func read(_ count: Int, from socket: Int32) throws(CommandSocketError) -> Data {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let got = data.withUnsafeMutableBytes { raw in
                Darwin.read(socket, raw.baseAddress!.advanced(by: offset), count - offset)
            }
            if got == 0 { throw .closed }
            if got < 0 {
                if errno == EINTR { continue }
                if errno == ECONNRESET { throw .closed }
                if errno == EAGAIN { throw .timedOut }
                throw .system("read", errno)
            }
            offset += got
        }
        return data
    }
}

public enum CommandSocketError: Error, Equatable, CustomStringConvertible {
    /// Nothing is listening: the app isn't running.
    case notRunning
    case timedOut
    /// The other end hung up before the message was complete.
    case closed
    case tooLarge
    case pathTooLong(String)
    /// Another copy of the app is already listening.
    case inUse
    /// Something that isn't the app's socket is where the socket goes.
    case blocked(String)
    case system(String, Int32)

    public var description: String {
        switch self {
        case .notRunning: return "Edit The Future isn't running."
        case .timedOut: return "Edit The Future didn't answer in time."
        case .closed: return "Edit The Future closed the connection."
        case .tooLarge: return "The answer was too large."
        case .pathTooLong(let path): return "The socket's path is too long: \(path)"
        case .inUse: return "Another copy of Edit The Future is already taking commands."
        case .blocked(let path): return "Something else is at \(path)."
        case .system(let call, let code): return "\(call) failed: \(String(cString: strerror(code)))"
        }
    }
}

/// Who is at the other end of a connection, from the kernel rather than from anything it sent.
public struct Caller: Sendable {
    public let pid: pid_t
    public let uid: uid_t
    /// The caller's audit token, which names the exact process even if its pid is reused.
    let auditToken: Data

    init?(socket: Int32) {
        var token = audit_token_t()
        var tokenLength = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(socket, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &tokenLength) == 0 else { return nil }
        var credentials = xucred()
        var credentialsLength = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(socket, SOL_LOCAL, LOCAL_PEERCRED, &credentials, &credentialsLength) == 0,
              credentials.cr_version == XUCRED_VERSION else { return nil }
        var pid: pid_t = 0
        var pidLength = socklen_t(MemoryLayout<pid_t>.size)
        getsockopt(socket, SOL_LOCAL, LOCAL_PEERPID, &pid, &pidLength)
        self.pid = pid
        uid = credentials.cr_uid
        auditToken = withUnsafeBytes(of: &token) { Data($0) }
    }
}

/// Which callers the app takes commands from (docs/DESIGN.md, 13).
public enum CallerCheck: Sendable, Equatable {
    /// Anyone running as this user. Only for tests.
    case sameUser
    /// Code that meets this code-signing requirement, running as this user.
    case requirement(String)

    func allows(_ caller: Caller) -> Bool {
        guard caller.uid == geteuid() else { return false }
        switch self {
        case .sameUser: return true
        case .requirement(let text): return Self.caller(caller, meets: text)
        }
    }

    static func caller(_ caller: Caller, meets text: String) -> Bool {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit: caller.auditToken] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    /// The team the running code is signed by, if it has one.
    public static func ownTeam() -> String? {
        guard let info = ownSigning() else { return nil }
        let team = info[kSecCodeInfoTeamIdentifier as String] as? String
        return team?.isEmpty == false ? team : nil
    }

    /// The running code's own hash, as a code-signing requirement takes it.
    static func ownHash() -> String? {
        (ownSigning()?[kSecCodeInfoUnique as String] as? Data).map(hex)
    }

    private static func ownSigning() -> [String: Any]? {
        var me: SecCode?
        var staticMe: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me, SecCodeCopyStaticCode(me, [], &staticMe) == errSecSuccess,
              let staticMe, SecCodeCopySigningInformation(staticMe, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return nil }
        return info as? [String: Any]
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// What the app at `bundle` accepts: code signed by its team, or, in a build signed without a
    /// team (ad hoc, as `scripts/build-app.sh` signs), only the exact `etf` tool inside it. Fails
    /// when there's no such tool to trust.
    public static func forApp(at bundle: URL, tool: String = "etf",
                              team: String? = CallerCheck.ownTeam()) -> Result<CallerCheck, CallerCheckProblem> {
        if let team {
            return .success(.requirement("anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""))
        }
        let url = bundle.appendingPathComponent("Contents/MacOS").appendingPathComponent(tool)
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return .failure(.noTool(url.path)) }
        var toolCode: SecStaticCode?
        var toolInfo: CFDictionary?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &toolCode) == errSecSuccess, let toolCode,
              SecStaticCodeCheckValidity(toolCode, [], nil) == errSecSuccess,
              SecCodeCopySigningInformation(toolCode, [], &toolInfo) == errSecSuccess,
              let hash = (toolInfo as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else {
            return .failure(.unsigned(url.path))
        }
        return .success(.requirement("cdhash H\"\(hex(hash))\""))
    }
}

public enum CallerCheckProblem: Error, Equatable, CustomStringConvertible {
    case noTool(String)
    case unsigned(String)

    public var description: String {
        switch self {
        case .noTool(let path): return "There's no etf tool at \(path), so the app takes no commands from the command line."
        case .unsigned(let path): return "The etf tool at \(path) isn't signed, so the app takes no commands from the command line."
        }
    }
}

/// Listens on the socket and answers each connection: one request, one reply.
///
/// Connections are served off the main thread. Each caller is checked before its request is read;
/// a request that's too large, unreadable or out of range is answered with why, and never reaches
/// the handler.
public final class CommandServer: @unchecked Sendable {
    public typealias Handler = @Sendable (Request) async -> Reply

    public let path: String
    let check: CallerCheck
    let handler: Handler
    /// Connections served at once; more are closed straight away.
    static let maxConnections = 8
    /// How long a caller has to send its request.
    static let requestTimeout: TimeInterval = 5

    private let lock = NSLock()
    private var source: DispatchSourceRead?
    private var active = 0
    /// The socket file this server made, so stopping removes only that one.
    private var made: (device: dev_t, inode: ino_t)?
    private let queue = DispatchQueue(label: "com.editthefuture.commands", attributes: .concurrent)

    public init(path: String = CommandSocket.defaultPath, check: CallerCheck, handler: @escaping Handler) {
        self.path = path
        self.check = check
        self.handler = handler
    }

    deinit { stop() }

    public func start() throws(CommandSocketError) {
        let folder = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try clearStale()
        var address = try CommandSocket.address(path)
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw .system("socket", errno) }
        _ = fcntl(listener, F_SETFD, FD_CLOEXEC)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else {
            let code = errno
            close(listener)
            throw code == EADDRINUSE ? .inUse : .system("bind", code)
        }
        // Only this user may connect. The folder is private too.
        chmod(path, 0o600)
        guard listen(listener, 16) == 0 else {
            let code = errno
            close(listener)
            unlink(path)
            throw .system("listen", code)
        }
        _ = fcntl(listener, F_SETFL, fcntl(listener, F_GETFL) | O_NONBLOCK)
        var info = stat()
        let identity = lstat(path, &info) == 0 ? (info.st_dev, info.st_ino) : nil

        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptWaiting(on: listener) }
        source.setCancelHandler { close(listener) }
        lock.withLock {
            self.source = source
            self.made = identity
        }
        source.resume()
    }

    /// Stops listening and removes the socket file, if it's still the one this server made.
    public func stop() {
        let (source, made) = lock.withLock { () -> (DispatchSourceRead?, (device: dev_t, inode: ino_t)?) in
            defer {
                self.source = nil
                self.made = nil
            }
            return (self.source, self.made)
        }
        source?.cancel()
        var info = stat()
        if let made, lstat(path, &info) == 0, info.st_dev == made.device, info.st_ino == made.inode {
            unlink(path)
        }
    }

    /// A socket left by a copy of the app that quit without removing it is removed. Anything else
    /// at the path is left alone.
    private func clearStale() throws(CommandSocketError) {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == geteuid() else { throw .blocked(path) }
        if CommandClient.isListening(at: path) { throw .inUse }
        unlink(path)
    }

    private func acceptWaiting(on listener: Int32) {
        while true {
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { return }
            _ = fcntl(connection, F_SETFD, FD_CLOEXEC)
            // A caller that has already hung up gets nothing.
            guard CommandSocket.preventSigpipe(on: connection) else {
                close(connection)
                continue
            }
            // Accepted sockets inherit the listener's non-blocking flag; reads here wait, with time limits.
            _ = fcntl(connection, F_SETFL, fcntl(connection, F_GETFL) & ~O_NONBLOCK)
            CommandSocket.setTimeout(Self.requestTimeout, SO_RCVTIMEO, on: connection)
            CommandSocket.setTimeout(30, SO_SNDTIMEO, on: connection)
            let admitted = lock.withLock {
                guard active < Self.maxConnections else { return false }
                active += 1
                return true
            }
            guard admitted else {
                close(connection)
                continue
            }
            queue.async { self.serve(connection) }
        }
    }

    private func serve(_ connection: Int32) {
        guard let caller = Caller(socket: connection), check.allows(caller) else {
            finish(connection, with: .failed("Edit The Future takes commands only from the etf tool that came with it."))
            return
        }
        let request: Request
        do {
            let data = try CommandSocket.receive(on: connection, limit: Wire.maxRequestBytes)
            request = try Wire.decode(Request.self, from: data)
        } catch let error as CommandSocketError {
            if error == .closed { finish(connection, with: nil) } else { finish(connection, with: .failed(error.description)) }
            return
        } catch {
            finish(connection, with: .failed(String(describing: error)))
            return
        }
        guard request.isWellFormed else {
            finish(connection, with: .failed("That request has a value out of range: a slot outside 1–8, a name that's too long, or an amount that isn't a number."))
            return
        }
        let handler = handler
        Task {
            let reply = await handler(request)
            self.queue.async { self.finish(connection, with: reply) }
        }
    }

    private func finish(_ connection: Int32, with reply: Reply?) {
        if let reply, let data = try? Wire.encode(reply) {
            try? CommandSocket.send(data, on: connection)
        }
        close(connection)
        lock.withLock { active -= 1 }
    }
}

/// The command line's side: one request, one reply.
public enum CommandClient {
    public static func send(_ request: Request, to path: String = CommandSocket.defaultPath,
                            timeout: TimeInterval = 120) throws -> Reply {
        let connection = try connect(to: path)
        defer { close(connection) }
        guard CommandSocket.preventSigpipe(on: connection) else { throw CommandSocketError.closed }
        CommandSocket.setTimeout(timeout, SO_RCVTIMEO, on: connection)
        CommandSocket.setTimeout(10, SO_SNDTIMEO, on: connection)
        try CommandSocket.send(try Wire.encode(request), on: connection)
        let data = try CommandSocket.receive(on: connection, limit: Wire.maxReplyBytes)
        return try Wire.decode(Reply.self, from: data)
    }

    /// Whether something is accepting connections at `path`.
    public static func isListening(at path: String) -> Bool {
        guard let connection = try? connect(to: path) else { return false }
        close(connection)
        return true
    }

    static func connect(to path: String) throws(CommandSocketError) -> Int32 {
        var address = try CommandSocket.address(path)
        let connection = socket(AF_UNIX, SOCK_STREAM, 0)
        guard connection >= 0 else { throw .system("socket", errno) }
        _ = fcntl(connection, F_SETFD, FD_CLOEXEC)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(connection, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else {
            let code = errno
            close(connection)
            throw code == ENOENT || code == ECONNREFUSED ? .notRunning : .system("connect", code)
        }
        return connection
    }
}
#endif
