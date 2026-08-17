import Foundation

// Well-known paths. Kept in one place so the app and the shell engine agree.
enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    // Scripts bundled inside the .app make it self-contained (drag-to-Applications
    // install needs no ~/bin); fall back to ~/bin for source / CLI installs.
    private static func bundledOrBin(_ name: String) -> String {
        if let res = Bundle.main.resourcePath {
            let bundled = "\(res)/\(name)"
            if FileManager.default.fileExists(atPath: bundled) { return bundled }
        }
        return "\(home)/bin/\(name)"
    }
    static var script:       String { bundledOrBin("icloud-gdrive-sync.sh") }
    static var rcloneSetup:  String { bundledOrBin("rclone-setup.command") }
    static var configDir:    String { "\(home)/.config/gdrive-backup" }
    static var guiState:     String { "\(configDir)/gui.json" }      // GUI owns this
    static var shellConfig:  String { "\(configDir)/config" }        // generated for the script
    static var backupPlist:  String { "\(home)/Library/LaunchAgents/eu.itteam.gdrive-sync.plist" }
    static var verifyPlist:  String { "\(home)/Library/LaunchAgents/eu.itteam.gdrive-verify.plist" }
    static var log:          String { "\(home)/Library/Logs/gdrive-sync.log" }
    static var lastSuccess:  String { "\(home)/Library/Caches/gdrive-sync/last-success" }
    static let backupLabel = "eu.itteam.gdrive-sync"
    static let verifyLabel = "eu.itteam.gdrive-verify"
}

// The full configuration the GUI manages. Persisted as JSON (gui.json); the
// shell `config` file is *generated* from it so the shell is never parsed here.
struct BackupConfig: Codable {
    var sources: [String] = ["Documents", "Desktop"]   // names (under $HOME) or absolute paths
    var intervalMinutes: Int = 60
    var maxDelete: Int = 500
    var retention: String = "90d"
    var scheduleEnabled: Bool = false
    var language: String = ""            // "" = auto (system), "et", or "en"
    var checksum: Bool = false           // thorough compare (rclone --checksum) vs size+mtime
    var bandwidthLimit: String = ""      // rclone --bwlimit, e.g. "10M"; empty = unlimited
    var verifyEnabled: Bool = false      // scheduled integrity check (rclone check)
    var verifyIntervalDays: Int = 7      // how often the integrity check runs

    // ---- load / save -------------------------------------------------------

    static func load() -> BackupConfig {
        guard let data = FileManager.default.contents(atPath: Paths.guiState),
              let cfg = try? JSONDecoder().decode(BackupConfig.self, from: data)
        else { return BackupConfig() }
        return cfg
    }

    // Tolerant decoder: any key absent from gui.json (e.g. `language` added in a
    // later version) falls back to its default instead of failing the whole
    // decode — which would silently reset every other saved setting.
    enum CodingKeys: String, CodingKey {
        case sources, intervalMinutes, maxDelete, retention, scheduleEnabled, language
        case checksum, bandwidthLimit, verifyEnabled, verifyIntervalDays
    }
    init() {}
    init(from decoder: Decoder) throws {
        var cfg = BackupConfig()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cfg.sources           = try c.decodeIfPresent([String].self, forKey: .sources)           ?? cfg.sources
        cfg.intervalMinutes   = try c.decodeIfPresent(Int.self,      forKey: .intervalMinutes)    ?? cfg.intervalMinutes
        cfg.maxDelete         = try c.decodeIfPresent(Int.self,      forKey: .maxDelete)          ?? cfg.maxDelete
        cfg.retention         = try c.decodeIfPresent(String.self,   forKey: .retention)          ?? cfg.retention
        cfg.scheduleEnabled   = try c.decodeIfPresent(Bool.self,     forKey: .scheduleEnabled)    ?? cfg.scheduleEnabled
        cfg.language          = try c.decodeIfPresent(String.self,   forKey: .language)           ?? cfg.language
        cfg.checksum          = try c.decodeIfPresent(Bool.self,     forKey: .checksum)           ?? cfg.checksum
        cfg.bandwidthLimit    = try c.decodeIfPresent(String.self,   forKey: .bandwidthLimit)     ?? cfg.bandwidthLimit
        cfg.verifyEnabled     = try c.decodeIfPresent(Bool.self,     forKey: .verifyEnabled)      ?? cfg.verifyEnabled
        cfg.verifyIntervalDays = try c.decodeIfPresent(Int.self,     forKey: .verifyIntervalDays) ?? cfg.verifyIntervalDays
        self = cfg
    }

    func save() throws {
        try FileManager.default.createDirectory(atPath: Paths.configDir,
                                                withIntermediateDirectories: true)
        // 1) GUI state as JSON
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try enc.encode(self)
        try json.write(to: URL(fileURLWithPath: Paths.guiState))
        setPerms(Paths.guiState, 0o600)
        // 2) Shell config for the engine
        try shellConfigText().write(toFile: Paths.shellConfig, atomically: true, encoding: .utf8)
        setPerms(Paths.shellConfig, 0o600)
    }

    // ---- shell generation --------------------------------------------------

    // Escape a value for a double-quoted shell context (the script `source`s it).
    private func esc(_ s: String) -> String {
        var r = s
        r = r.replacingOccurrences(of: "\\", with: "\\\\")   // backslash first
        r = r.replacingOccurrences(of: "\"", with: "\\\"")
        r = r.replacingOccurrences(of: "$",  with: "\\$")
        r = r.replacingOccurrences(of: "`",  with: "\\`")
        return r
    }

    // SOURCES is always emitted newline-separated (each entry on its own line,
    // trailing newline) so the engine's newline branch is taken and paths with
    // spaces are handled correctly.
    func shellConfigText() -> String {
        let srcBlock = sources.map { esc($0) }.joined(separator: "\n")
        var out = ""
        out += "# Generated by Drive Backup.app — do not edit (regenerated on save).\n"
        out += "SOURCES=\"\(srcBlock)\n\"\n"
        out += "INTERVAL_MINUTES=\(intervalMinutes)\n"
        out += "MAX_DELETE=\(maxDelete)\n"
        out += "RETENTION=\"\(esc(retention))\"\n"
        out += "SCHEDULE_ENABLED=\(scheduleEnabled ? 1 : 0)\n"
        out += "CHECKSUM=\(checksum ? 1 : 0)\n"
        if !bandwidthLimit.trimmingCharacters(in: .whitespaces).isEmpty {
            out += "BWLIMIT=\"\(esc(bandwidthLimit))\"\n"
        }
        out += "GUI_LANG=\"\(L10n.resolve(language).rawValue)\"\n"   // for rclone-setup.command
        return out
    }

    private func setPerms(_ path: String, _ perms: Int) {
        try? FileManager.default.setAttributes([.posixPermissions: perms], ofItemAtPath: path)
    }
}
