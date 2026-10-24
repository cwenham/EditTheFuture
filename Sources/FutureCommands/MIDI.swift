import Foundation

// MIDI is the first hardware transport: it works over USB and Bluetooth LE on Mac, iPad and
// iPhone with no drivers. This file has no CoreMIDI dependency; the app's adapter converts
// CoreMIDI packets to `MIDIMessage` and back.

/// A MIDI 1.0 channel voice or system exclusive message. Channels are zero-based (0 = channel 1).
public enum MIDIMessage: Hashable, Sendable {
    case noteOn(channel: UInt8, note: UInt8, velocity: UInt8)
    case noteOff(channel: UInt8, note: UInt8, velocity: UInt8)
    case controlChange(channel: UInt8, controller: UInt8, value: UInt8)
    case programChange(channel: UInt8, program: UInt8)
    /// 14-bit value, 8192 = centre.
    case pitchBend(channel: UInt8, value: UInt16)
    /// The bytes between F0 and F7.
    case sysEx([UInt8])

    /// Parses a MIDI 1.0 byte stream, including running status. Real-time bytes are skipped,
    /// and messages the app doesn't use (aftertouch, system common) are dropped.
    public static func parse(_ bytes: [UInt8]) -> [MIDIMessage] {
        var messages: [MIDIMessage] = []
        var status: UInt8?
        var data: [UInt8] = []
        var sysEx: [UInt8]?

        for byte in bytes {
            if byte >= 0xF8 { continue }  // real-time messages can appear anywhere
            if sysEx != nil {
                if byte == 0xF7 {
                    messages.append(.sysEx(sysEx!))
                    sysEx = nil
                    continue
                }
                if byte < 0x80 {
                    sysEx!.append(byte)
                    continue
                }
                sysEx = nil  // a status byte ends an unterminated sysex; handle it below
            }
            if byte == 0xF0 {
                sysEx = []
                status = nil
                data = []
            } else if byte >= 0xF0 {
                status = nil  // system common messages cancel running status
                data = []
            } else if byte >= 0x80 {
                status = byte
                data = []
            } else if let current = status {
                data.append(byte)
                if data.count == dataLength(current) {
                    if let message = channelMessage(status: current, data: data) { messages.append(message) }
                    data = []
                }
            }
        }
        return messages
    }

    /// Parses Universal MIDI Packets as CoreMIDI delivers them. Handles MIDI 1.0 channel voice
    /// (message type 2) and MIDI 2.0 channel voice (type 4, scaled down to 7 bits).
    public static func parse(umpWords words: [UInt32]) -> [MIDIMessage] {
        var messages: [MIDIMessage] = []
        var index = 0
        while index < words.count {
            let first = words[index]
            let type = first >> 28
            let length = umpWordCount(type)
            defer { index += length }
            guard index + length <= words.count else { break }

            switch type {
            case 0x2:
                let status = UInt8((first >> 16) & 0xFF)
                let data = [UInt8((first >> 8) & 0x7F), UInt8(first & 0x7F)]
                if let message = channelMessage(status: status, data: Array(data.prefix(dataLength(status)))) {
                    messages.append(message)
                }
            case 0x4:
                let second = words[index + 1]
                let kind = UInt8((first >> 20) & 0xF)
                let channel = UInt8((first >> 16) & 0xF)
                let index7 = UInt8((first >> 8) & 0x7F)
                switch kind {
                case 0x9:
                    // In MIDI 2.0 a velocity of 0 is still a note on, so never scale below 1.
                    let velocity = UInt8(max((second >> 16) >> 9, 1))
                    messages.append(.noteOn(channel: channel, note: index7, velocity: velocity))
                case 0x8:
                    messages.append(.noteOff(channel: channel, note: index7, velocity: UInt8((second >> 16) >> 9)))
                case 0xB:
                    messages.append(.controlChange(channel: channel, controller: index7, value: UInt8(second >> 25)))
                case 0xC:
                    messages.append(.programChange(channel: channel, program: UInt8((second >> 24) & 0x7F)))
                case 0xE:
                    messages.append(.pitchBend(channel: channel, value: UInt16(second >> 18)))
                default:
                    break
                }
            default:
                break
            }
        }
        return messages
    }

    /// The message as MIDI 1.0 bytes.
    public var bytes: [UInt8] {
        switch self {
        case .noteOn(let channel, let note, let velocity):
            return [0x90 | (channel & 0x0F), note & 0x7F, velocity & 0x7F]
        case .noteOff(let channel, let note, let velocity):
            return [0x80 | (channel & 0x0F), note & 0x7F, velocity & 0x7F]
        case .controlChange(let channel, let controller, let value):
            return [0xB0 | (channel & 0x0F), controller & 0x7F, value & 0x7F]
        case .programChange(let channel, let program):
            return [0xC0 | (channel & 0x0F), program & 0x7F]
        case .pitchBend(let channel, let value):
            return [0xE0 | (channel & 0x0F), UInt8(value & 0x7F), UInt8((value >> 7) & 0x7F)]
        case .sysEx(let payload):
            return [0xF0] + payload.map { $0 & 0x7F } + [0xF7]
        }
    }

    private static func dataLength(_ status: UInt8) -> Int {
        switch status >> 4 {
        case 0xC, 0xD: return 1
        default: return 2
        }
    }

    private static func channelMessage(status: UInt8, data: [UInt8]) -> MIDIMessage? {
        let channel = status & 0x0F
        switch status >> 4 {
        case 0x8:
            return .noteOff(channel: channel, note: data[0], velocity: data[1])
        case 0x9:
            return data[1] == 0
                ? .noteOff(channel: channel, note: data[0], velocity: 0)
                : .noteOn(channel: channel, note: data[0], velocity: data[1])
        case 0xB:
            return .controlChange(channel: channel, controller: data[0], value: data[1])
        case 0xC:
            return .programChange(channel: channel, program: data[0])
        case 0xE:
            return .pitchBend(channel: channel, value: UInt16(data[0]) | (UInt16(data[1]) << 7))
        default:
            return nil
        }
    }

    private static func umpWordCount(_ type: UInt32) -> Int {
        switch type {
        case 0x0, 0x1, 0x2, 0x6, 0x7: return 1
        case 0x3, 0x4, 0x8, 0x9, 0xA: return 2
        case 0xB, 0xC: return 3
        default: return 4
        }
    }
}

/// How a relative encoder reports turns in a control change value.
public enum RelativeEncoding: String, Hashable, Sendable, Codable {
    /// 1...63 = +1...+63, 127...65 = -1...-63. The default.
    case twosComplement
    /// 64 = no change, 65 = +1, 63 = -1.
    case offset64
    /// Bit 6 is the sign: 1...63 = +, 65...127 = -(value - 64).
    case signMagnitude

    public func delta(_ value: UInt8) -> Int {
        let value = Int(value & 0x7F)
        switch self {
        case .twosComplement: return value < 64 ? value : value - 128
        case .offset64: return value - 64
        case .signMagnitude: return value & 0x40 == 0 ? value & 0x3F : -(value & 0x3F)
        }
    }
}

/// Maps a controller's notes and knobs to commands.
public struct MIDIProfile: Hashable, Sendable, Codable {
    public enum Button: String, Hashable, Sendable, Codable {
        case toggleWindow, peek, jumpToNow, copySnapshot, copyData, insertEvent
        case previousBank, nextBank, cycleWheelMode, undo, redo
    }

    /// Zero-based MIDI channel the device uses (0 = channel 1).
    public var channel: UInt8
    /// Notes for slot buttons 1...8, in order.
    public var slotNotes: [UInt8]
    public var buttons: [UInt8: Button]
    /// Relative controller for the main wheel; what it does depends on the wheel mode.
    public var wheelController: UInt8
    /// Optional relative controller that always zooms.
    public var zoomController: UInt8?
    public var encoding: RelativeEncoding

    public init(channel: UInt8, slotNotes: [UInt8], buttons: [UInt8: Button], wheelController: UInt8,
                zoomController: UInt8?, encoding: RelativeEncoding) {
        self.channel = channel
        self.slotNotes = slotNotes
        self.buttons = buttons
        self.wheelController = wheelController
        self.zoomController = zoomController
        self.encoding = encoding
    }

    /// The profile for the hardware prototype. Also works with common pad controllers.
    public static let prototype = MIDIProfile(
        channel: 0,
        slotNotes: Array(36...43),
        buttons: [
            44: .toggleWindow, 45: .peek, 46: .jumpToNow, 47: .copySnapshot,
            48: .insertEvent, 49: .previousBank, 50: .nextBank, 51: .cycleWheelMode,
        ],
        wheelController: 16,
        zoomController: 17,
        encoding: .twosComplement
    )
}

/// Turns incoming MIDI messages into commands. Keeps the wheel mode, which changes what
/// the main wheel does; call `setWheelMode` when the app changes it another way.
public struct MIDIInterpreter: Sendable {
    public var profile: MIDIProfile
    public private(set) var wheelMode: WheelMode = .scroll
    /// Parameters the wheel can be switched to adjust, after scroll and zoom.
    public var adjustableParameters: [String] = []

    public init(profile: MIDIProfile = .prototype) {
        self.profile = profile
    }

    public mutating func setWheelMode(_ mode: WheelMode) {
        wheelMode = mode
    }

    public mutating func interpret(_ message: MIDIMessage) -> [Command] {
        switch message {
        case .noteOn(let channel, let note, _) where channel == profile.channel:
            if let slot = profile.slotNotes.firstIndex(of: note) { return [.selectSlot(slot + 1)] }
            if let button = profile.buttons[note] { return pressed(button) }
        case .noteOff(let channel, let note, _) where channel == profile.channel:
            if profile.buttons[note] == .peek { return [.peek(.end)] }
        case .controlChange(let channel, let controller, let value) where channel == profile.channel:
            let delta = profile.encoding.delta(value)
            guard delta != 0 else { return [] }
            if controller == profile.wheelController {
                switch wheelMode {
                case .scroll: return [.scroll(ticks: delta)]
                case .zoom: return [.zoom(ticks: delta)]
                case .parameter(let name): return [.adjustParameter(name: name, ticks: delta)]
                }
            }
            if controller == profile.zoomController { return [.zoom(ticks: delta)] }
        default:
            break
        }
        return []
    }

    private mutating func pressed(_ button: MIDIProfile.Button) -> [Command] {
        switch button {
        case .toggleWindow: return [.toggleWindow]
        case .peek: return [.peek(.begin)]
        case .jumpToNow: return [.jumpToNow]
        case .copySnapshot: return [.copySnapshot(.all)]
        case .copyData: return [.copyData]
        case .insertEvent: return [.insertEventAtCursor]
        case .previousBank: return [.previousBank]
        case .nextBank: return [.nextBank]
        case .undo: return [.undo]
        case .redo: return [.redo]
        case .cycleWheelMode:
            wheelMode = nextWheelMode()
            return [.setWheelMode(wheelMode)]
        }
    }

    /// scroll → zoom → each adjustable parameter → scroll.
    private func nextWheelMode() -> WheelMode {
        switch wheelMode {
        case .scroll:
            return .zoom
        case .zoom:
            return adjustableParameters.first.map(WheelMode.parameter) ?? .scroll
        case .parameter(let name):
            guard let index = adjustableParameters.firstIndex(of: name), index + 1 < adjustableParameters.count else {
                return .scroll
            }
            return .parameter(adjustableParameters[index + 1])
        }
    }
}

/// Encodes `DeviceFeedback` as MIDI for the device's LEDs and display.
///
/// - Slot LEDs: Note On on each slot's note, velocity = palette color (0 = off).
///   Profile channel = solid, next channel = pulsing (computing or error).
/// - Display: SysEx `F0 7D 45 54 <command> … F7`, using the non-commercial manufacturer ID 0x7D.
///   Register a real manufacturer ID before shipping hardware.
public enum MIDIFeedbackEncoder {
    public static let manufacturerID: UInt8 = 0x7D
    /// "ET" after the manufacturer ID, so other non-commercial devices can ignore our messages.
    public static let header: [UInt8] = [manufacturerID, 0x45, 0x54]
    public static let errorColor: UInt8 = 5
    public static let maxNameLength = 16
    public static let maxCursorTextLength = 32

    public enum SysExCommand: UInt8 {
        case slots = 0x01
        case cursorText = 0x02
        case wheelMode = 0x03
    }

    public static func slotLights(_ feedback: DeviceFeedback, profile: MIDIProfile) -> [MIDIMessage] {
        profile.slotNotes.enumerated().map { index, note in
            let slot = index < feedback.slots.count ? feedback.slots[index] : .empty
            let pulsing = slot.status == .computing || slot.status == .error
            let channel = (profile.channel + (pulsing ? 1 : 0)) & 0x0F
            var color = slot.status == .error ? errorColor : slot.colorIndex & 0x7F
            if slot.status == .empty || !slot.isVisible { color = 0 }
            return .noteOn(channel: channel, note: note, velocity: color)
        }
    }

    public static func displayMessages(_ feedback: DeviceFeedback) -> [MIDIMessage] {
        var slotBytes: [UInt8] = [UInt8(clamping: feedback.bank) & 0x7F, UInt8(min(feedback.slots.count, 8))]
        for (index, slot) in feedback.slots.prefix(8).enumerated() {
            let flags: UInt8 = (slot.isSelected ? 1 : 0) | (slot.isSoloed ? 2 : 0) | (slot.isVisible ? 4 : 0)
            let name = ascii(slot.name, limit: maxNameLength)
            slotBytes += [UInt8(index), statusCode(slot.status), flags, slot.colorIndex & 0x7F, UInt8(name.count)] + name
        }

        var wheelBytes: [UInt8]
        switch feedback.wheelMode {
        case .scroll: wheelBytes = [0]
        case .zoom: wheelBytes = [1]
        case .parameter(let name):
            let text = ascii(name, limit: maxNameLength)
            wheelBytes = [2, UInt8(text.count)] + text
        }
        wheelBytes.append(feedback.isPeeking ? 1 : 0)

        return [
            .sysEx(header + [SysExCommand.slots.rawValue] + slotBytes),
            .sysEx(header + [SysExCommand.cursorText.rawValue] + ascii(feedback.cursorText, limit: maxCursorTextLength)),
            .sysEx(header + [SysExCommand.wheelMode.rawValue] + wheelBytes),
        ]
    }

    private static func statusCode(_ status: SlotFeedback.Status) -> UInt8 {
        switch status {
        case .empty: return 0
        case .idle: return 1
        case .computing: return 2
        case .error: return 3
        }
    }

    /// Printable 7-bit ASCII only; anything else becomes "?".
    static func ascii(_ text: String, limit: Int) -> [UInt8] {
        text.unicodeScalars.prefix(limit).map { scalar in
            (0x20...0x7E).contains(scalar.value) ? UInt8(scalar.value) : UInt8(ascii: "?")
        }
    }
}
