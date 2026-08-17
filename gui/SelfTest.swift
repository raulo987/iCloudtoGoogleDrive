import Foundation

// Headless self-test of the risky path: generating the shell config the engine
// sources. Prints the generated config to stdout for a bash round-trip check.
// Invoked with `Drive Backup --selftest`; exits before any UI is created.
enum SelfTest {
    static func run() {
        var c = BackupConfig()
        c.sources = [
            "Documents",
            "Desktop",
            "/Volumes/My Work",                 // space in path
            "Weird $name `x` \"q\" \\z",         // shell-nasty chars — must stay literal
        ]
        c.intervalMinutes = 30
        c.maxDelete = 250
        c.retention = "60d"
        c.scheduleEnabled = true
        if let data = c.shellConfigText().data(using: .utf8) {
            FileHandle.standardOutput.write(data)
        }
    }
}
