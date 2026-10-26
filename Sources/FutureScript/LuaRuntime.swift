import CLua
import Foundation
import FutureEngine

/// A Lua 5.5 state with one script loaded (docs/DESIGN.md, 6.4). Only the safe libraries are
/// opened, memory is capped, and each call has a time limit.
final class LuaRuntime: ScriptRuntime {
    private let state: OpaquePointer
    private let limits: ScriptLimits
    /// The prelude's table of functions, and its number lists, in the registry.
    private let rt: Int32
    private let vals: Int32
    private let ins: Int32
    private let tim: Int32
    private let evs: Int32
    let descriptionJSON: String

    /// The chunk name for scripts, so errors read "script:12: ...".
    static let chunkName = "=script"

    init(source: String, libraries: [URL], limits: ScriptLimits) throws {
        guard let state = etf_lua_open(limits.memory) else { throw ScriptError("Lua couldn't start: there isn't enough memory.") }
        self.state = state
        self.limits = limits
        etf_lua_set_library_paths(state, libraries.map(\.path).joined(separator: "\n"))
        etf_lua_set_time_limit(state, limits.loadSeconds)

        func fail(_ status: Int32) -> ScriptError {
            let error = Self.error(from: Self.popString(state) ?? "Lua failed (\(status)).")
            etf_lua_close(state)
            return error
        }

        var status = etf_lua_load(state, luaPrelude, luaPrelude.utf8.count, "=etf")
        if status == LUA_OK { status = etf_lua_pcall(state, 0, 1) }
        guard status == LUA_OK else { throw fail(status) }
        let rt = etf_lua_ref(state)
        self.rt = rt
        func reference(_ field: String) -> Int32 {
            etf_lua_push_field(state, rt, field)
            return etf_lua_ref(state)
        }
        vals = reference("vals")
        ins = reference("ins")
        tim = reference("tim")
        evs = reference("evs")

        status = etf_lua_load(state, source, source.utf8.count, Self.chunkName)
        if status == LUA_OK { status = etf_lua_pcall(state, 0, 0) }
        guard status == LUA_OK else { throw fail(status) }

        etf_lua_push_field(state, rt, "finish")
        status = etf_lua_pcall(state, 0, 0)
        guard status == LUA_OK else { throw fail(status) }

        etf_lua_push_field(state, rt, "describe")
        status = etf_lua_pcall(state, 0, 1)
        guard status == LUA_OK, let json = Self.popString(state) else { throw fail(status) }
        descriptionJSON = json
    }

    deinit {
        etf_lua_close(state)
    }

    func start(_ values: inout [Double], inputs: [Double], time: ScriptTime) throws {
        try call("start", values: &values, inputs: inputs, time: time, events: [])
    }

    func step(_ values: inout [Double], inputs: [Double], time: ScriptTime, events: [Event]) throws -> [GeneratedEvent] {
        let count = try call("step", values: &values, inputs: inputs, time: time, events: events)
        guard count > 0 else { return [] }
        etf_lua_push_field(state, rt, "emitted")
        guard etf_lua_pcall(state, 0, 1) == LUA_OK, let json = Self.popString(state) else {
            throw Self.error(from: Self.popString(state) ?? "The script's events couldn't be read.")
        }
        return try ScriptEvents.decode(json)
    }

    /// Hands the state, inputs, time and events to `rt[function]`, runs it, and reads the state back.
    /// Returns what the function returned as a number (the count of events sent, for `step`).
    @discardableResult
    private func call(_ function: String, values: inout [Double], inputs: [Double], time: ScriptTime, events: [Event]) throws -> Int {
        let state = self.state
        etf_lua_set_time_limit(state, limits.callSeconds)

        write(vals, values)
        write(ins, inputs)
        write(tim, time.numbers)
        clearEvents()
        for event in events {
            etf_lua_push_event(state, evs, event.kind, event.originSlot, ScriptEvents.dateText(event.time))
            for (name, value) in event.values where name != "kind" && name != "slot" && name != "date" {
                etf_lua_set_number_field(state, name, value)
            }
            etf_lua_pop(state, 1)
        }

        etf_lua_push_field(state, rt, function)
        lua_pushstring(state, time.date)
        lua_pushinteger(state, lua_Integer(Int64(bitPattern: time.seed)))
        lua_pushinteger(state, lua_Integer(time.index))
        let status = etf_lua_pcall(state, 3, 1)
        guard status == LUA_OK else {
            throw Self.error(from: Self.popString(state) ?? "Lua failed (\(status)).")
        }
        var isNumber: Int32 = 0
        let result = lua_tointegerx(state, -1, &isNumber)
        etf_lua_pop(state, 1)

        etf_lua_push_ref(state, vals)
        let bad = values.withUnsafeMutableBufferPointer { buffer in
            etf_lua_read_numbers(state, -1, buffer.baseAddress, Int32(buffer.count))
        }
        etf_lua_pop(state, 1)
        if bad != 0 { throw ScriptError("A state value isn't a number.") }
        return isNumber != 0 ? Int(result) : 0
    }

    private func write(_ list: Int32, _ numbers: [Double]) {
        etf_lua_push_ref(state, list)
        numbers.withUnsafeBufferPointer { buffer in
            etf_lua_write_numbers(state, -1, buffer.baseAddress, Int32(buffer.count))
        }
        etf_lua_pop(state, 1)
    }

    private func clearEvents() {
        etf_lua_push_ref(state, evs)
        let count = lua_rawlen(state, -1)
        if count > 0 {
            for index in stride(from: Int(count), through: 1, by: -1) {
                lua_pushnil(state)
                lua_rawseti(state, -2, lua_Integer(index))
            }
        }
        etf_lua_pop(state, 1)
    }

    /// The text printed with `print`, newest last.
    var printed: String {
        etf_lua_push_field(state, rt, "output")
        guard etf_lua_pcall(state, 0, 1) == LUA_OK else { etf_lua_pop(state, 1); return "" }
        return Self.popString(state) ?? ""
    }

    // MARK: Helpers

    private static func popString(_ state: OpaquePointer) -> String? {
        var length = 0
        guard let pointer = etf_lua_tostring(state, -1, &length) else {
            etf_lua_pop(state, 1)
            return nil
        }
        let text = String(decoding: UnsafeRawBufferPointer(start: pointer, count: length), as: UTF8.self)
        etf_lua_pop(state, 1)
        return text
    }

    /// "script:12: attempt to ..." becomes line 12 and the rest. Errors from libraries keep their
    /// file name: "stats.lua:5: ...".
    static func error(from message: String) -> ScriptError {
        let prefix = "script:"
        if message.hasPrefix(prefix) {
            let rest = message.dropFirst(prefix.count)
            if let colon = rest.firstIndex(of: ":"), let line = Int(rest[..<colon]) {
                return ScriptError(String(rest[rest.index(after: colon)...]).trimmingCharacters(in: .whitespaces), line: line)
            }
        }
        return ScriptError(message)
    }
}

/// Events a script sent, as both preludes report them: `[{"kind": "...", "values": {...}}]`.
enum ScriptEvents {
    private struct Sent: Decodable {
        var kind: String
        var values: [String: Double?]?
    }

    /// "2031-06-01", in UTC.
    static func dateText(_ date: Date) -> String {
        let civil = CivilDate(date)
        return dateText(year: civil.year, month: civil.month, day: civil.day)
    }

    /// "2031-06-01". Built by hand: String(format:) took longer than a Lua step.
    static func dateText(year: Int, month: Int, day: Int) -> String {
        func padded(_ value: Int, _ width: Int) -> String {
            let digits = String(abs(value))
            return (value < 0 ? "-" : "") + String(repeating: "0", count: max(0, width - digits.count)) + digits
        }
        return padded(year, 4) + "-" + padded(month, 2) + "-" + padded(day, 2)
    }

    static func decode(_ json: String) throws -> [GeneratedEvent] {
        do {
            return try JSONDecoder().decode([Sent].self, from: Data(json.utf8)).map { sent in
                GeneratedEvent(kind: sent.kind, values: (sent.values ?? [:]).mapValues { $0 ?? .nan })
            }
        } catch {
            throw ScriptError("The script's events couldn't be read (\(error)).")
        }
    }
}
