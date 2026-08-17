import Foundation

// launchd management for the scheduled agents:
//   • backup  (eu.itteam.gdrive-sync)   — runs the engine on the sync interval
//   • verify  (eu.itteam.gdrive-verify) — runs `engine --verify` on the check interval
// The GUI regenerates each plist so interval changes take effect, then reloads.
enum Schedule {

    private static var uid: String { String(getuid()) }
    private static var domain: String { "gui/\(uid)" }

    // Pure, testable plist generator. `extraArgs` are appended to the engine
    // invocation (e.g. ["--verify"]); `logBase` names the stdout/stderr files.
    static func plistString(label: String, seconds: Int, extraArgs: [String], logBase: String) -> String {
        let s = max(60, seconds)
        let argXML = (["/bin/bash", Paths.script] + extraArgs)
            .map { "    <string>\($0)</string>" }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>\(label)</string>
          <key>ProgramArguments</key>
          <array>
        \(argXML)
          </array>
          <key>RunAtLoad</key>
          <true/>
          <key>StartInterval</key>
          <integer>\(s)</integer>
          <key>ProcessType</key>
          <string>Background</string>
          <key>LowPriorityIO</key>
          <true/>
          <key>Nice</key>
          <integer>10</integer>
          <key>StandardOutPath</key>
          <string>\(Paths.home)/Library/Logs/\(logBase).out</string>
          <key>StandardErrorPath</key>
          <string>\(Paths.home)/Library/Logs/\(logBase).err</string>
        </dict>
        </plist>
        """
    }

    private static func writeAgent(label: String, path: String, seconds: Int,
                                   extraArgs: [String], logBase: String) throws {
        let dir = "\(Paths.home)/Library/LaunchAgents"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try plistString(label: label, seconds: seconds, extraArgs: extraArgs, logBase: logBase)
            .write(toFile: path, atomically: true, encoding: .utf8)
    }

    private static func isLoaded(_ label: String) -> Bool {
        Runner.shell("/bin/launchctl", ["print", "\(domain)/\(label)"]).status == 0
    }

    // (re)write plist + bootstrap (bootout first to be idempotent; legacy fallback).
    private static func enableAgent(label: String, path: String, seconds: Int,
                                    extraArgs: [String], logBase: String) throws {
        try writeAgent(label: label, path: path, seconds: seconds, extraArgs: extraArgs, logBase: logBase)
        _ = Runner.shell("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        let r = Runner.shell("/bin/launchctl", ["bootstrap", domain, path])
        if r.status != 0 { _ = Runner.shell("/bin/launchctl", ["load", "-w", path]) }
    }

    private static func disableAgent(label: String, path: String) {
        _ = Runner.shell("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        _ = Runner.shell("/bin/launchctl", ["unload", "-w", path])   // legacy fallback
    }

    // ---- backup agent ------------------------------------------------------
    static func writePlist(intervalMinutes: Int) throws {
        try writeAgent(label: Paths.backupLabel, path: Paths.backupPlist,
                       seconds: intervalMinutes * 60, extraArgs: [], logBase: "gdrive-sync")
    }
    static func isLoaded() -> Bool { isLoaded(Paths.backupLabel) }
    static func enable(intervalMinutes: Int) throws {
        try enableAgent(label: Paths.backupLabel, path: Paths.backupPlist,
                        seconds: intervalMinutes * 60, extraArgs: [], logBase: "gdrive-sync")
    }
    static func disable() { disableAgent(label: Paths.backupLabel, path: Paths.backupPlist) }

    // ---- verify agent (scheduled integrity check) --------------------------
    static func isVerifyLoaded() -> Bool { isLoaded(Paths.verifyLabel) }
    static func enableVerify(intervalDays: Int) throws {
        try enableAgent(label: Paths.verifyLabel, path: Paths.verifyPlist,
                        seconds: max(1, intervalDays) * 86400, extraArgs: ["--verify"], logBase: "gdrive-verify")
    }
    static func disableVerify() { disableAgent(label: Paths.verifyLabel, path: Paths.verifyPlist) }
}
