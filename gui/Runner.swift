import Foundation

// Runs the shell engine and small helper commands. Never embeds credentials.
enum Runner {

    // Run a command synchronously, capturing merged stdout+stderr.
    @discardableResult
    static func shell(_ launchPath: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch {
            return (-1, "Failed to launch \(launchPath): \(error.localizedDescription)")
        }
        // Read to EOF before waiting to avoid deadlock on a full pipe buffer.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    // Run the backup engine with the given args, off the main thread; result on main.
    static func runEngine(_ args: [String], completion: @escaping (Int32, String) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let r = shell("/bin/bash", [Paths.script] + args)
            DispatchQueue.main.async { completion(r.status, r.output) }
        }
    }

    // Best-effort macOS notification via osascript (no entitlements needed).
    // Every notification is ALSO appended to the shared engine log, so nothing
    // shown to the user is missing from the log. NOTIFY=0 suppresses only the
    // on-screen banner (used by tests), never the log line.
    static func notify(_ title: String, _ message: String) {
        appendLog("NOTIFY(gui): \(title) — \(message)")
        if ProcessInfo.processInfo.environment["NOTIFY"] == "0" { return }
        let safe = message.replacingOccurrences(of: "\"", with: "'")
        _ = shell("/usr/bin/osascript",
                  ["-e", "display notification \"\(safe)\" with title \"\(title)\""])
    }

    // Append a timestamped line to the engine log (same file + format as the
    // shell engine, `YYYY-MM-DD HH:MM:SS …`). `path` is injectable for tests;
    // it defaults to the real log. Creates the file/dir if missing.
    static func appendLog(_ s: String, to path: String = Paths.log) {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "\(df.string(from: Date())) \(s)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let fh = FileHandle(forWritingAtPath: path) {
            defer { try? fh.close() }
            fh.seekToEndOfFile()
            fh.write(data)
        } else {
            try? FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
