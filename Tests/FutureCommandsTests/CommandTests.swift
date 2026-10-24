import Foundation
import Testing
@testable import FutureCommands

@Suite("Commands and the etf:// URL scheme")
struct CommandTests {
    @Test("etf://show opens a timeline at a date")
    func showLink() throws {
        let command = try URLScheme.command(from: URL(string: "etf://show?timeline=savings&at=2030-01")!)
        #expect(command == .show(timeline: "savings", at: PartialDate(year: 2030, month: 1)))
    }

    @Test("Links round-trip")
    func roundTrip() throws {
        let commands: [Command] = [
            .show(timeline: "Fire risk", at: PartialDate("2031-06-15")), .show(timeline: nil, at: nil),
            .toggleWindow, .jumpToNow, .selectSlot(3), .scroll(ticks: -12), .zoom(ticks: 2),
            .copySnapshot(.png), .copySnapshot(.all), .copyData,
        ]
        for command in commands {
            let url = try #require(URLScheme.url(for: command))
            #expect(try URLScheme.command(from: url) == command)
        }
        #expect(URLScheme.url(for: .show(timeline: "savings", at: PartialDate("2030-01")))?.absoluteString
                == "etf://show?timeline=savings&at=2030-01")
        #expect(URLScheme.url(for: .insertEventAtCursor) == nil)
    }

    @Test("Bad links are rejected")
    func badLinks() {
        #expect(throws: URLSchemeError.wrongScheme("https")) { try URLScheme.command(from: URL(string: "https://show")!) }
        #expect(throws: URLSchemeError.invalidParameter(name: "at", value: "2030-13")) {
            try URLScheme.command(from: URL(string: "etf://show?at=2030-13")!)
        }
        #expect(throws: URLSchemeError.invalidParameter(name: "slot", value: "9")) {
            try URLScheme.command(from: URL(string: "etf://select?slot=9")!)
        }
        #expect(throws: URLSchemeError.missingParameter("ticks")) { try URLScheme.command(from: URL(string: "etf://scroll")!) }
        #expect(throws: URLSchemeError.unknownAction("install")) {
            try URLScheme.command(from: URL(string: "etf://install?plugin=x")!)
        }
        let longName = String(repeating: "a", count: 200)
        #expect(throws: URLSchemeError.self) { try URLScheme.command(from: URL(string: "etf://show?timeline=\(longName)")!) }
    }

    @Test("Partial dates accept year, month or day precision")
    func partialDates() {
        #expect(PartialDate("2030")?.date == DateComponents(calendar: .utcGregorianForCommands, year: 2030, month: 1, day: 1).date)
        #expect(PartialDate("2024-02-29") != nil)
        #expect(PartialDate("2023-02-29") == nil)
        #expect(PartialDate("2030-1") == nil)
        #expect(PartialDate("30-01") == nil)
        #expect(PartialDate("2030-01")?.description == "2030-01")
    }

    @Test("Links can navigate, but must ask before editing or touching the clipboard")
    func confirmationPolicy() {
        #expect(!Command.show(timeline: "savings", at: nil).requiresConfirmation(from: .urlScheme))
        #expect(Command.copySnapshot(.all).requiresConfirmation(from: .urlScheme))
        #expect(Command.insertEventAtCursor.requiresConfirmation(from: .urlScheme))
        #expect(!Command.insertEventAtCursor.requiresConfirmation(from: .peripheral))
        #expect(!Command.copySnapshot(.all).requiresConfirmation(from: .keyboard))
        #expect(Command.adjustParameter(name: "rate", ticks: 1).requiresConfirmation(from: .appIntent))
        #expect(!Command.copyData.requiresConfirmation(from: .appIntent))
        #expect(Command.undo.requiresConfirmation(from: .pairedDevice))
    }
}

@Suite("MIDI")
struct MIDITests {
    @Test("Byte streams with running status, real-time bytes and sysex")
    func parseBytes() {
        #expect(MIDIMessage.parse([0x90, 36, 100, 37, 0]) == [
            .noteOn(channel: 0, note: 36, velocity: 100),
            .noteOff(channel: 0, note: 37, velocity: 0),
        ])
        #expect(MIDIMessage.parse([0xB1, 0xF8, 16, 1]) == [.controlChange(channel: 1, controller: 16, value: 1)])
        #expect(MIDIMessage.parse([0xF0, 0x7D, 1, 2, 0xF7, 0xC0, 5]) == [.sysEx([0x7D, 1, 2]), .programChange(channel: 0, program: 5)])
        #expect(MIDIMessage.parse([0xE0, 0x00, 0x40]) == [.pitchBend(channel: 0, value: 8192)])
    }

    @Test("Messages encode back to the same bytes")
    func encode() {
        let messages: [MIDIMessage] = [
            .noteOn(channel: 2, note: 40, velocity: 90), .noteOff(channel: 2, note: 40, velocity: 10),
            .controlChange(channel: 0, controller: 16, value: 127), .programChange(channel: 3, program: 7),
            .pitchBend(channel: 0, value: 1234), .sysEx([0x7D, 0x45, 0x54]),
        ]
        #expect(MIDIMessage.parse(messages.flatMap(\.bytes)) == messages)
    }

    @Test("Universal MIDI Packets from CoreMIDI")
    func parseUMP() {
        #expect(MIDIMessage.parse(umpWords: [0x2090_2464]) == [.noteOn(channel: 0, note: 0x24, velocity: 0x64)])
        #expect(MIDIMessage.parse(umpWords: [0x40B0_1000, 0x8000_0000]) == [.controlChange(channel: 0, controller: 16, value: 64)])
        #expect(MIDIMessage.parse(umpWords: [0x4090_2400, 0x0000_0000]) == [.noteOn(channel: 0, note: 0x24, velocity: 1)])
        #expect(MIDIMessage.parse(umpWords: [0x1000_0000, 0x2080_2400]) == [.noteOff(channel: 0, note: 0x24, velocity: 0)])
    }

    @Test("Relative encoder formats")
    func relativeEncoding() {
        #expect(RelativeEncoding.twosComplement.delta(1) == 1)
        #expect(RelativeEncoding.twosComplement.delta(127) == -1)
        #expect(RelativeEncoding.offset64.delta(65) == 1)
        #expect(RelativeEncoding.offset64.delta(60) == -4)
        #expect(RelativeEncoding.signMagnitude.delta(3) == 3)
        #expect(RelativeEncoding.signMagnitude.delta(67) == -3)
    }

    @Test("The prototype profile maps buttons and the wheel to commands")
    func interpreter() {
        var interpreter = MIDIInterpreter()
        interpreter.adjustableParameters = ["rate"]

        #expect(interpreter.interpret(.noteOn(channel: 0, note: 38, velocity: 100)) == [.selectSlot(3)])
        #expect(interpreter.interpret(.noteOn(channel: 0, note: 44, velocity: 100)) == [.toggleWindow])
        #expect(interpreter.interpret(.noteOn(channel: 0, note: 45, velocity: 100)) == [.peek(.begin)])
        #expect(interpreter.interpret(.noteOff(channel: 0, note: 45, velocity: 0)) == [.peek(.end)])
        #expect(interpreter.interpret(.controlChange(channel: 0, controller: 16, value: 127)) == [.scroll(ticks: -1)])
        #expect(interpreter.interpret(.controlChange(channel: 0, controller: 17, value: 2)) == [.zoom(ticks: 2)])

        #expect(interpreter.interpret(.noteOn(channel: 0, note: 51, velocity: 100)) == [.setWheelMode(.zoom)])
        #expect(interpreter.interpret(.controlChange(channel: 0, controller: 16, value: 2)) == [.zoom(ticks: 2)])
        #expect(interpreter.interpret(.noteOn(channel: 0, note: 51, velocity: 100)) == [.setWheelMode(.parameter("rate"))])
        #expect(interpreter.interpret(.controlChange(channel: 0, controller: 16, value: 3)) == [.adjustParameter(name: "rate", ticks: 3)])
        #expect(interpreter.interpret(.noteOn(channel: 0, note: 51, velocity: 100)) == [.setWheelMode(.scroll)])

        #expect(interpreter.interpret(.noteOn(channel: 5, note: 38, velocity: 100)).isEmpty)
        #expect(interpreter.interpret(.controlChange(channel: 0, controller: 16, value: 0)).isEmpty)
    }

    @Test("Slot LEDs and display messages for the device")
    func feedback() {
        let feedback = DeviceFeedback(
            bank: 0,
            slots: [
                SlotFeedback(name: "Savings", colorIndex: 21, status: .idle, isSelected: true),
                SlotFeedback(name: "Café", colorIndex: 45, status: .computing),
            ],
            cursorText: "2030-01  41,223",
            wheelMode: .parameter("rate")
        )
        let lights = MIDIFeedbackEncoder.slotLights(feedback, profile: .prototype)
        #expect(lights.count == 8)
        #expect(lights[0] == .noteOn(channel: 0, note: 36, velocity: 21))
        #expect(lights[1] == .noteOn(channel: 1, note: 37, velocity: 45))
        #expect(lights[2] == .noteOn(channel: 0, note: 38, velocity: 0))

        let display = MIDIFeedbackEncoder.displayMessages(feedback)
        #expect(display.count == 3)
        for message in display {
            guard case .sysEx(let payload) = message else {
                Issue.record("Expected sysex")
                continue
            }
            #expect(Array(payload.prefix(3)) == MIDIFeedbackEncoder.header)
            #expect(payload.allSatisfy { $0 < 0x80 })
        }
        #expect(MIDIFeedbackEncoder.ascii("Café", limit: 16) == Array("Caf?".utf8))
    }
}
