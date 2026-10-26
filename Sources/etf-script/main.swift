// Runs a Lua or Python script model without the app and prints its values as CSV
// (docs/DESIGN.md, 6.4).
//
//   swift run etf-script model.lua [--from 2026-01-01] [--through 2030-01-01] [--set name=value]... [--libraries folder]
//
// The language comes from the file's extension: .lua or .py.
import Foundation
import FutureEngine
import FutureScript

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func date(_ text: String) -> Date {
    let parts = text.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3, let date = Calendar.utcGregorian.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else {
        fail("\(text) isn't a date like 2030-01-01.")
    }
    return date
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard let path = arguments.first, !path.hasPrefix("-") else {
    fail("Usage: etf-script <model.lua|model.py> [--from YYYY-MM-DD] [--through YYYY-MM-DD] [--set name=value]... [--libraries folder]")
}
arguments.removeFirst()

var from = date("2026-01-01")
var through: Date?
var values: [String: Double] = [:]
while let option = arguments.first {
    arguments.removeFirst()
    guard let value = arguments.first else { fail("\(option) needs a value.") }
    arguments.removeFirst()
    switch option {
    case "--from": from = date(value)
    case "--through": through = date(value)
    case "--set":
        let parts = value.split(separator: "=", maxSplits: 1)
        guard parts.count == 2, let number = Double(parts[1]) else { fail("--set needs name=value, like rate=0.04.") }
        values[String(parts[0])] = number
    case "--libraries": ScriptPrograms.librariesFolder = URL(fileURLWithPath: value)
    default: fail("There's no option called \(option).")
    }
}

let url = URL(fileURLWithPath: path)
guard let language = ScriptLanguage.allCases.first(where: { $0.fileExtension == url.pathExtension.lowercased() }) else {
    fail("\(url.lastPathComponent) should end in .lua or .py.")
}
guard let source = try? String(contentsOf: url, encoding: .utf8) else { fail("Couldn't read \(path).") }

do {
    let name = url.deletingPathExtension().lastPathComponent.filter { $0.isLetter || $0.isNumber || $0 == "_" }
    let model = try ScriptModel(source, language: language, name: name.first?.isLetter == true ? name : "Script", values: values)
    let scenario = Scenario(start: from)
    let slot = try scenario.addSlot(model.descriptor.name, model: model)
    let end = through ?? Calendar.utcGregorian.date(byAdding: .year, value: 10, to: from)!
    let names = model.descriptor.readable.map(\.name)
    let columns = try names.map { try scenario.series($0, of: slot, from: from, through: end) }
    print((["date"] + names).joined(separator: ","))
    for (row, sample) in (columns.first ?? []).enumerated() {
        let civil = CivilDate(sample.time)
        let day = String(format: "%04d-%02d-%02d", civil.year, civil.month, civil.day)
        print(([day] + columns.map { String($0[row].value) }).joined(separator: ","))
    }
} catch {
    fail(String(describing: error))
}
