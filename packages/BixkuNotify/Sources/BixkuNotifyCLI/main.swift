import BixkuNotify
import Foundation

// bixku-notify: thin wrapper that turns arguments into a bixku://notify URL and opens it.
// Exit codes follow sysexits: 64 usage error, 69 could not hand the URL to macOS.

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("bixku-notify: \(message)\n".utf8))
    exit(code)
}

switch NotifyCommand.parse(Array(CommandLine.arguments.dropFirst())) {
case .failure(.helpRequested):
    print(NotifyCommand.usage)
case .failure(let error):
    fail("\(error)\n\n\(NotifyCommand.usage)", code: 64)
case .success(let command):
    if command.printOnly {
        print(command.url.absoluteString)
    } else {
        #if os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        // -g: do not bring the app to the foreground. The URL is one argument, no shell involved.
        process.arguments = ["-g", command.url.absoluteString]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            fail("could not run open: \(error.localizedDescription)", code: 69)
        }
        if process.terminationStatus != 0 {
            fail("open failed; is Bixku Utilities installed?", code: 69)
        }
        #else
        fail("opening URLs is only supported on macOS; use --print", code: 69)
        #endif
    }
}
