// The etf command-line tool (docs/DESIGN.md, 10.2): sends one request to the running app through
// its local socket and prints the answer. It ships inside the app, in Contents/MacOS, and the app
// takes commands only from that copy (or, once signed, from the same team's code).
//
// Exit codes: 0 done, 1 the app said no, 2 the arguments were wrong, 3 the app couldn't be reached.
#if os(macOS)
import Darwin
import Foundation
import FutureCommands

func fail(_ text: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("etf: \(text)\n".utf8))
    exit(code)
}

let invocation: Invocation
do {
    invocation = try CommandLineTool.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    fail(error.description, code: 2)
}
guard let request = invocation.request else {
    print(CommandLineTool.usage)
    exit(0)
}

/// The app this tool came with, when it's in one: etf lives in EditTheFuture.app/Contents/MacOS,
/// perhaps reached through a link on the PATH.
func appBundle() -> URL? {
    var size: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &size)
    var buffer = [CChar](repeating: 0, count: Int(size) + 1)
    guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
    let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    let executable = URL(fileURLWithPath: path).resolvingSymlinksInPath()
    let macOS = executable.deletingLastPathComponent()
    let contents = macOS.deletingLastPathComponent()
    let app = contents.deletingLastPathComponent()
    guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents", app.pathExtension == "app" else { return nil }
    return app
}

/// Starts the app in the background: this tool's own, or whichever copy macOS knows.
func launchApp() {
    FileHandle.standardError.write(Data("Starting Edit The Future…\n".utf8))
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    // In the background, and without showing the panel: the app shows it when a command asks.
    if let app = appBundle() {
        open.arguments = ["-g", "-a", app.path, "--args", "--background"]
    } else {
        open.arguments = ["-g", "-b", "com.editthefuture.mac", "--args", "--background"]
    }
    open.standardOutput = FileHandle.nullDevice
    open.standardError = FileHandle.nullDevice
    do {
        try open.run()
        open.waitUntilExit()
    } catch {
        fail("Couldn't start Edit The Future: \(error.localizedDescription)", code: 3)
    }
    guard open.terminationStatus == 0 else { fail("Couldn't find Edit The Future to start it.", code: 3) }
}

func send() throws -> Reply {
    try CommandClient.send(request, timeout: invocation.timeout)
}

var reply: Reply
do {
    reply = try send()
} catch CommandSocketError.notRunning where invocation.launchesApp {
    launchApp()
    // The app listens as soon as it has launched, and answers once its scenario is open.
    let deadline = Date().addingTimeInterval(20)
    while true {
        do {
            reply = try send()
            break
        } catch CommandSocketError.notRunning where Date() < deadline {
            usleep(250_000)
        } catch {
            fail(String(describing: error), code: 3)
        }
    }
} catch {
    fail(String(describing: error), code: 3)
}

let (out, error) = CommandLineTool.render(reply, as: invocation.output)
FileHandle.standardOutput.write(Data(out.utf8))
FileHandle.standardError.write(Data(error.utf8))
exit(reply.ok ? 0 : 1)
#else
print("etf runs on the Mac.")
#endif
