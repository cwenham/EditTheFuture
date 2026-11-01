import Foundation
import Testing
@testable import FutureCommands

@Suite("The etf tool's arguments, replies and wire format")
struct CommandLineToolTests {
    func parse(_ line: String) throws -> Invocation {
        try CommandLineTool.parse(line.split(separator: " ").map(String.init))
    }

    func request(_ line: String) throws -> Request? {
        try parse(line).request
    }

    @Test("Reading commands become questions")
    func questions() throws {
        #expect(try request("status") == .query(.status))
        #expect(try request("slots") == .query(.slots))
        #expect(try request("value") == .query(.value(slot: nil, variable: nil, at: nil)))
        #expect(try request("value savings balance --at 2030-01")
                == .query(.value(slot: "savings", variable: "balance", at: PartialDate(year: 2030, month: 1))))
        #expect(try request("value 3 --at=2031") == .query(.value(slot: "3", variable: nil, at: PartialDate(year: 2031))))
        #expect(try parse("value savings --number").output == .number)
        #expect(try parse("value savings --number --json").output == .json)
        #expect(try request("data savings --from 2026 --through 2030 --every monthly")
                == .query(.series(slot: "savings", variable: nil, from: PartialDate(year: 2026), through: PartialDate(year: 2030),
                                  every: .monthly)))
        #expect(try parse("data").output == .csv)
        // A name with spaces arrives as one argument.
        #expect(try CommandLineTool.parse(["value", "Index fund"]).request == .query(.value(slot: "Index fund", variable: nil, at: nil)))
    }

    @Test("Moving the panel")
    func navigation() throws {
        #expect(try request("show savings --at 2030-01")
                == .command(.show(timeline: "savings", at: PartialDate(year: 2030, month: 1))))
        #expect(try request("show") == .command(.show(timeline: nil, at: nil)))
        #expect(try request("goto savings 1m") == .command(.goto("savings 1m")))
        #expect(try request("go to 2035") == .command(.goto("2035")))
        #expect(try request("focus 3") == .command(.selectSlot(3)))
        #expect(try request("focus climate") == .command(.show(timeline: "climate", at: nil)))
        #expect(try request("now") == .command(.jumpToNow))
        #expect(try request("toggle") == .command(.toggleWindow))
        #expect(try request("scroll -12") == .command(.scroll(ticks: -12)))
        #expect(try request("zoom 2") == .command(.zoom(ticks: 2)))
    }

    @Test("Changing the scenario")
    func edits() throws {
        #expect(try request("deposit savings 500 --at 2027-01-01 --every monthly")
                == .command(.addEvent(EventRequest(slot: "savings", kind: "deposit", values: ["amount": Amount(500)],
                                                   at: PartialDate(year: 2027, month: 1, day: 1), every: .monthly))))
        #expect(try request("withdraw savings £6,000")
                == .command(.addEvent(EventRequest(slot: "savings", kind: "withdraw", values: ["amount": Amount(6000)], currency: "£"))))
        #expect(try request("set savings rate 4.5%")
                == .command(.addEvent(EventRequest(slot: "savings", kind: "set", values: ["rate": Amount(0.045, isFraction: true)]))))
        #expect(try request("set savings rate 4.5")
                == .command(.addEvent(EventRequest(slot: "savings", kind: "set", values: ["rate": Amount(4.5)]))))
        #expect(try request("event add savings deposit amount=500 --at 2027-01-01")
                == .command(.addEvent(EventRequest(slot: "savings", kind: "deposit", values: ["amount": Amount(500)],
                                                   at: PartialDate(year: 2027, month: 1, day: 1)))))
        #expect(try request("event add mortgage overpay 10k")
                == .command(.addEvent(EventRequest(slot: "mortgage", kind: "overpay", values: ["amount": Amount(10_000)]))))
        #expect(try request("reading savings 41,200 --at 2026-10-01")
                == .command(.addReading(ReadingRequest(slot: "savings", value: Amount(41_200), at: PartialDate(year: 2026, month: 10, day: 1)))))
        #expect(try request("reading savings 4.2% --of rate")
                == .command(.addReading(ReadingRequest(slot: "savings", variable: "rate", value: Amount(0.042, isFraction: true)))))
        #expect(try request("reading savings £41k")
                == .command(.addReading(ReadingRequest(slot: "savings", value: Amount(41_000), currency: "£"))))
        #expect(throws: UsageError.self) { try request("reading savings") }
        #expect(throws: UsageError.self) { try request("reading savings 5 --every monthly") }
        #expect(try request("add savings account --slot 7") == .command(.addModel(name: "savings account", slot: 7)))
        #expect(try request("remove climate") == .command(.removeSlot("climate")))
        #expect(try request("undo") == .command(.undo))
        #expect(try request("redo") == .command(.redo))
        #expect(try request("copy") == .command(.copySnapshot(.all)))
        #expect(try request("copy --format png") == .command(.copySnapshot(.png)))
        #expect(try request("copy --format data") == .command(.copyData))
    }

    @Test("Help, and options that shape the run")
    func options() throws {
        #expect(try request("help") == nil)
        #expect(try request("value --help") == nil)
        #expect(try CommandLineTool.parse([]).request == nil)
        #expect(try parse("status --no-launch").launchesApp == false)
        #expect(try parse("status").launchesApp)
        #expect(try parse("value --timeout 300").timeout == 300)
    }

    @Test("Mistakes say what's wrong")
    func mistakes() {
        let wrong = [
            "frobnicate", "value a b c", "value --at 2030-13", "value --every monthly", "status --at 2030",
            "deposit savings", "deposit savings -500", "deposit savings 4%", "deposit savings 1,5",
            "set savings rate", "focus 9", "scroll many", "scroll 99999", "copy --format gif", "add --slot 3 loan --slot 12",
            "data --from 2030 --through 2026", "goto", "show savings --colour red", "value --json=yes",
            "event add savings", "event remove savings", "value sav/ings",
        ]
        for line in wrong {
            #expect(throws: UsageError.self, "\(line)") { try parse(line) }
        }
    }

    @Test("Amounts: a point for decimals, thousands grouped by commas, currencies before or after")
    func amounts() throws {
        func read(_ text: String) -> (Double, Bool, String?)? {
            CommandLineTool.parseAmount(text).map { ($0.0.value, $0.0.isFraction, $0.currency) }
        }
        #expect(read("500")! == (500, false, nil))
        #expect(read("-500")! == (-500, false, nil))
        #expect(read("1,200.50")! == (1200.5, false, nil))
        #expect(read("1,234,567")! == (1_234_567, false, nil))
        #expect(read("1.5k")! == (1500, false, nil))
        #expect(read("2m")! == (2_000_000, false, nil))
        #expect(read("1bn")! == (1e9, false, nil))
        #expect(read("4.5%")! == (0.045, true, nil))
        #expect(read("£500")! == (500, false, "£"))
        #expect(read("CA$12")! == (12, false, "CA$"))
        #expect(read("500eur")! == (500, false, "eur"))
        #expect(read("500 EUR")! == (500, false, "eur"))
        #expect(read("1.5k eur")! == (1500, false, "eur"))
        #expect(read("−6,000")! == (-6000, false, nil))
        #expect(read("1,5") == nil)
        #expect(read("1,23") == nil)
        #expect(read("12,345.6,7") == nil)
        #expect(read("abc") == nil)
        #expect(read("£500eur") == nil)
        #expect(read("£4%") == nil)
        #expect(read("1e999") == nil)
        #expect(read("") == nil)
    }

    @Test("Replies print as text, bare numbers, CSV or JSON")
    func rendering() {
        let value = Reply(ok: true, message: "Savings will be £96,420 in Jan 2030.",
                          value: ValueReading(slot: "Savings", variable: "balance", date: "2030-01-01", value: 96420.125,
                                              text: "£96,420", unit: "GBP"))
        #expect(CommandLineTool.render(value, as: .text).out == "£96,420\n")
        #expect(CommandLineTool.render(value, as: .number).out == "96420.125\n")
        #expect(CommandLineTool.render(value, as: .json).out.contains("\"unit\" : \"GBP\""))

        let series = Reply(ok: true, message: "3 rows", series: SeriesReading(slot: "Rocket", variable: "balance", unit: "USD", rows: [
            .init(date: "2046-12-01", value: 1e300), .init(date: "2047-01-01", value: .infinity), .init(date: "2047-02-01", value: .nan),
        ]))
        #expect(CommandLineTool.render(series, as: .csv).out == "date,balance\n2046-12-01,1e+300\n2047-01-01,inf\n2047-02-01,nan\n")

        let slots = Reply(ok: true, message: "", slots: [
            SlotSummary(number: 1, name: "Savings", title: "Savings", model: "Savings account", shows: "balance", outputs: ["balance"],
                        parameters: ["rate"], events: ["deposit"], currency: "GBP", paused: nil),
            SlotSummary(number: 5, name: "EnergyBill", title: "Energy bill", model: "Energy bill", shows: "bill", outputs: ["bill"],
                        parameters: [], events: [], currency: "GBP", paused: "Climate was removed"),
        ])
        let table = CommandLineTool.render(slots, as: .text).out.split(separator: "\n").map(String.init)
        #expect(table.count == 3)
        #expect(table[0].hasPrefix("#  Slot"))
        #expect(table[2].hasSuffix("paused: Climate was removed"))

        let failed = CommandLineTool.render(.failed("There's no slot called x."), as: .text)
        #expect(failed.out.isEmpty)
        #expect(failed.error == "There's no slot called x.\n")
        #expect(CommandLineTool.render(.done("Added +£500 on Jan 2027 to Savings"), as: .text).out == "Added +£500 on Jan 2027 to Savings\n")
    }

    @Test("The wire keeps infinity and NaN, and refuses other versions and dates that aren't real")
    func wire() throws {
        let reply = Reply(ok: true, message: "∞", value: ValueReading(slot: "Rocket", variable: "balance", date: "2047-01-01",
                                                                     value: -.infinity, text: "−∞", unit: "USD"))
        let back = try Wire.decode(Reply.self, from: Wire.encode(reply))
        #expect(back.value?.value == -.infinity)
        let nan = try Wire.decode(Reply.self, from: Wire.encode(Reply(ok: true, message: "", value: ValueReading(
            slot: "", variable: "", date: "", value: .nan, text: "", unit: ""))))
        #expect(nan.value?.value.isNaN == true)

        let requests: [Request] = [
            .query(.series(slot: "savings", variable: "balance", from: PartialDate("2026"), through: nil, every: .quarterly)),
            .command(.addEvent(EventRequest(slot: nil, kind: "set", values: ["rate": Amount(0.04, isFraction: true)], currency: "£",
                                            at: PartialDate("2027-06-15"), every: .yearly))),
            .command(.goto("savings 1m")), .command(.copySnapshot(.pdf)), .command(.addModel(name: "loan", slot: nil)),
        ]
        for request in requests {
            #expect(try Wire.decode(Request.self, from: Wire.encode(request)) == request)
        }

        let future = Data(#"{"version": 99, "body": {"query": {"status": {}}}}"#.utf8)
        #expect(throws: Wire.Problem.otherVersion(99)) { try Wire.decode(Request.self, from: future) }
        let badMonth = Data(#"{"version": 1, "body": {"query": {"value": {"at": {"year": 2030, "month": 13}}}}}"#.utf8)
        #expect(throws: Wire.Problem.self) { try Wire.decode(Request.self, from: badMonth) }
        let hugeYear = Data(#"{"version": 1, "body": {"command": {"show": {"at": {"year": 99999999999}}}}}"#.utf8)
        #expect(throws: Wire.Problem.self) { try Wire.decode(Request.self, from: hugeYear) }
        #expect(throws: Wire.Problem.self) { try Wire.decode(Request.self, from: Data("not json".utf8)) }
    }

    @Test("Requests from outside are checked for range before they run")
    func wellFormed() {
        #expect(Request.command(.selectSlot(3)).isWellFormed)
        #expect(!Request.command(.selectSlot(0)).isWellFormed)
        #expect(!Request.command(.scroll(ticks: 1_000_000)).isWellFormed)
        #expect(!Request.command(.show(timeline: "a/b", at: nil)).isWellFormed)
        #expect(!Request.command(.goto("")).isWellFormed)
        #expect(!Request.command(.goto(String(repeating: "x", count: 500))).isWellFormed)
        #expect(!Request.command(.addModel(name: "loan", slot: 9)).isWellFormed)
        #expect(!Request.command(.addEvent(EventRequest(slot: nil, kind: "deposit", values: ["amount": Amount(.nan)]))).isWellFormed)
        #expect(!Request.command(.addEvent(EventRequest(slot: nil, kind: "deposit", values: [:]))).isWellFormed)
        #expect(!Request.command(.addEvent(EventRequest(slot: nil, kind: "de posit", values: ["amount": Amount(1)]))).isWellFormed)
        #expect(Request.command(.addEvent(.money(-50, slot: "savings"))).isWellFormed)
        #expect(EventRequest.money(-50, slot: "savings").kind == "withdraw")
        #expect(!Request.query(.value(slot: String(repeating: "s", count: 300), variable: nil, at: nil)).isWellFormed)
        #expect(Command.addEvent(.money(5, slot: nil)).category == .editing)
        #expect(Command.goto("2035").category == .navigation)
        #expect(Command.removeSlot("x").requiresConfirmation(from: .appIntent))
        #expect(!Command.removeSlot("x").requiresConfirmation(from: .commandLine))
    }

    @Test("A date picked in Shortcuts is the day it falls on where it was picked")
    func pickedDays() throws {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        // 1 Jan 2030 at 01:00 in Tokyo is still 31 Dec 2029 in UTC.
        let picked = tokyo.date(from: DateComponents(year: 2030, month: 1, day: 1, hour: 1))!
        #expect(PartialDate(day: picked, in: tokyo) == PartialDate(year: 2030, month: 1, day: 1))
    }
}

#if os(macOS)
@Suite("The etf tool's socket")
struct CommandSocketTests {
    /// Sends a request on a thread of its own. Waiting for the reply blocks, and must not tie up the
    /// threads Swift's tasks run on: the server's handler needs one, and the whole suite runs at once.
    func ask(_ request: Request, at path: String) async throws -> Reply {
        try await blocking { try CommandClient.send(request, to: path, timeout: 30) }
    }

    func blocking<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread { continuation.resume(with: Result { try work() }) }
        }
    }

    /// A short path in the temporary folder: a socket's address holds 104 bytes.
    func socketPath() -> String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("etf-\(UUID().uuidString.prefix(8)).sock")
    }

    @Test("A request goes in and its reply comes back")
    func roundTrip() async throws {
        let path = socketPath()
        let server = CommandServer(path: path, check: .sameUser) { request in
            guard case .query(.value(let slot, _, _)) = request else { return .failed("Unexpected") }
            return Reply(ok: true, message: "Read \(slot ?? "")",
                         value: ValueReading(slot: slot ?? "", variable: "balance", date: "2030-01-01", value: .infinity, text: "∞", unit: "USD"))
        }
        try server.start()
        defer { server.stop() }
        var info = stat()
        #expect(lstat(path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)

        let reply = try await ask(.query(.value(slot: "savings", variable: nil, at: nil)), at: path)
        #expect(reply.message == "Read savings")
        #expect(reply.value?.value == .infinity)
        server.stop()
        #expect(lstat(path, &info) != 0)
        #expect(throws: CommandSocketError.notRunning) { try CommandClient.send(.query(.status), to: path, timeout: 5) }
    }

    @Test("Callers whose code doesn't meet the requirement are refused before their request is read")
    func refusesOtherCode() async throws {
        let path = socketPath()
        let reached = Flag()
        let server = CommandServer(path: path, check: .requirement("cdhash H\"\(String(repeating: "0", count: 40))\"")) { _ in
            reached.set()
            return .done("ran")
        }
        try server.start()
        defer { server.stop() }
        let reply = try await ask(.command(.undo), at: path)
        #expect(!reply.ok)
        #expect(reply.message.contains("only from the etf tool"))
        #expect(!reached.isSet)
    }

    @Test("Callers whose code meets the requirement get through, checked by their audit token")
    func acceptsMatchingCode() async throws {
        // The test runner isn't signed, so a program Apple signed connects instead: nc, which can
        // talk to a Unix socket.
        let nc = URL(fileURLWithPath: "/usr/bin/nc")
        try #require(FileManager.default.isExecutableFile(atPath: nc.path))
        let path = socketPath()
        let server = CommandServer(path: path, check: .requirement("anchor apple")) { _ in .done("ran") }
        try server.start()
        defer { server.stop() }

        let process = Process()
        process.executableURL = nc
        process.arguments = ["-U", path]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        let body = try Wire.encode(Request.command(.undo))
        var length = UInt32(body.count).bigEndian
        input.fileHandleForWriting.write(withUnsafeBytes(of: &length) { Data($0) } + body)
        let reading = output.fileHandleForReading
        let answer = try await blocking { reading.readDataToEndOfFile() }
        process.waitUntilExit()
        try input.fileHandleForWriting.close()
        try #require(answer.count > 4)
        #expect(try Wire.decode(Reply.self, from: answer.dropFirst(4)) == .done("ran"))

        // The unsigned test runner, asking the same server, is refused.
        let refused = try await ask(.command(.undo), at: path)
        #expect(!refused.ok)
    }

    @Test("Out-of-range and oversized requests never reach the handler")
    func badRequests() async throws {
        let path = socketPath()
        let reached = Flag()
        let server = CommandServer(path: path, check: .sameUser) { _ in
            reached.set()
            return .done("ran")
        }
        try server.start()
        defer { server.stop() }
        let reply = try await ask(.command(.selectSlot(42)), at: path)
        #expect(!reply.ok)
        #expect(reply.message.contains("out of range"))

        // A length far beyond the limit is refused without reading it.
        let socket = try CommandClient.connect(to: path)
        defer { close(socket) }
        CommandSocket.setTimeout(5, SO_RCVTIMEO, on: socket)
        var length = UInt32(Wire.maxRequestBytes + 1).bigEndian
        _ = withUnsafeBytes(of: &length) { write(socket, $0.baseAddress, 4) }
        let data = try await blocking { try CommandSocket.receive(on: socket, limit: Wire.maxReplyBytes) }
        let answer = try Wire.decode(Reply.self, from: data)
        #expect(!answer.ok)
        #expect(!reached.isSet)
    }

    @Test("A socket left behind is replaced; a live one or anything else at the path is left alone")
    func staleSockets() async throws {
        let path = socketPath()
        let first = CommandServer(path: path, check: .sameUser) { _ in .done("first") }
        try first.start()
        let second = CommandServer(path: path, check: .sameUser) { _ in .done("second") }
        #expect(throws: CommandSocketError.inUse) { try second.start() }
        #expect(try await ask(.command(.undo), at: path) == .done("first"))

        // A copy of the app that crashed leaves its socket file behind, with nothing listening.
        let leftover = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = try CommandSocket.address(path)
        first.stop()
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(leftover, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(bound == 0)
        close(leftover)
        try second.start()
        defer { second.stop() }
        #expect(try await ask(.command(.undo), at: path) == .done("second"))

        let other = socketPath()
        FileManager.default.createFile(atPath: other, contents: Data("notes".utf8))
        defer { try? FileManager.default.removeItem(atPath: other) }
        let third = CommandServer(path: other, check: .sameUser) { _ in .done("third") }
        #expect(throws: CommandSocketError.blocked(other)) { try third.start() }
        #expect(FileManager.default.contents(atPath: other) == Data("notes".utf8))
    }

    @Test("The app trusts only the etf tool inside it when it has no team")
    func trustsItsOwnTool() throws {
        let bundle = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Test-\(UUID().uuidString).app")
        let macOS = bundle.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle) }
        #expect(CallerCheck.forApp(at: bundle, team: nil) == .failure(.noTool(macOS.appendingPathComponent("etf").path)))

        // Any signed program stands in for the tool.
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: macOS.appendingPathComponent("etf"))
        guard case .success(.requirement(let text)) = CallerCheck.forApp(at: bundle, team: nil) else {
            Issue.record("No requirement for a signed tool")
            return
        }
        #expect(text.hasPrefix("cdhash H\""))
        #expect(text.count == "cdhash H\"\"".count + 40)

        #expect(CallerCheck.forApp(at: bundle, team: "ABCDE12345")
                == .success(.requirement("anchor apple generic and certificate leaf[subject.OU] = \"ABCDE12345\"")))
    }

    @Test("The socket's path fits a socket's address")
    func defaultPath() {
        #expect(CommandSocket.defaultPath.utf8.count <= CommandSocket.maxPathLength)
        #expect(CommandSocket.defaultPath.hasSuffix(CommandSocket.fileName))
    }
}

/// Set once from any thread.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
#endif
