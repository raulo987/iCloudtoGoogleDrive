import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var statusLine: NSMenuItem!
    private var scheduleLine: NSMenuItem!
    private var prefs: PreferencesWindowController?
    private var output: OutputWindowController?
    private var help: OutputWindowController?
    private var about: AboutWindowController?
    private var running = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()
        buildMenu()
        menu.delegate = self
        statusItem.menu = menu
        // Rebuild everything in the new language when the user switches it.
        NotificationCenter.default.addObserver(self, selector: #selector(languageChanged),
                                               name: L10n.changed, object: nil)
        // Test/verification seam: open Preferences immediately for screenshotting.
        if CommandLine.arguments.contains("--open-prefs") { openPrefs() }
    }

    @objc private func languageChanged() {
        buildMenu()                                   // menu titles
        updateIcon()                                  // tooltip
        // Drop cached windows so each rebuilds its labels on next open. Deferred
        // to the next runloop so we never deallocate the controller whose Save
        // action is still executing (it posted this notification).
        DispatchQueue.main.async { [weak self] in
            self?.prefs = nil; self?.output = nil; self?.help = nil; self?.about = nil
        }
    }

    // ---- menu --------------------------------------------------------------

    private func item(_ title: String, _ sel: Selector?, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        it.target = self
        return it
    }

    private func buildMenu() {
        menu.removeAllItems()   // re-runnable so a language switch relabels it
        statusLine = NSMenuItem(title: T("Viimane backup: …", "Last backup: …"), action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        scheduleLine = NSMenuItem(title: T("Ajakava: …", "Schedule: …"), action: nil, keyEquivalent: "")
        scheduleLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(scheduleLine)
        menu.addItem(.separator())
        menu.addItem(item(T("Backup nüüd", "Back up now"), #selector(backupNow)))
        menu.addItem(item(T("Kuivkäik (dry-run)…", "Dry run…"), #selector(dryRun)))
        menu.addItem(item(T("Kontrolli (verify)…", "Verify…"), #selector(verify)))
        menu.addItem(.separator())
        menu.addItem(item(T("Seaded…", "Settings…"), #selector(openPrefs), key: ","))
        menu.addItem(item(T("Seadista Google Drive…", "Set up Google Drive…"), #selector(setupGDrive)))
        menu.addItem(item(T("Ava logi", "Open log"), #selector(openLog)))
        menu.addItem(.separator())
        menu.addItem(item(T("Kasutusjuhend", "User guide"), #selector(openHelp)))
        menu.addItem(item(T("Programmist…", "About…"), #selector(openAbout)))
        menu.addItem(.separator())
        menu.addItem(item(T("Välju", "Quit"), #selector(quit), key: "q"))
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        statusLine.title = T("Viimane backup: ", "Last backup: ") + lastSuccessDescription()
        let on = Schedule.isLoaded()
        scheduleLine.title = T("Ajakava: ", "Schedule: ") + (on ? T("sees", "on") : T("väljas", "off"))
    }

    // ---- actions -----------------------------------------------------------

    @objc private func backupNow() { runEngine([], label: T("Backup", "Backup"), showLogTail: false) }
    @objc private func dryRun()    { runEngine(["--dry-run"], label: T("Kuivkäik", "Dry run"), showLogTail: true) }
    @objc private func verify()    { runEngine(["--verify"], label: T("Kontroll", "Verify"), showLogTail: true) }

    private func runEngine(_ args: [String], label: String, showLogTail: Bool) {
        if running { NSSound.beep(); return }
        running = true; updateIcon()
        Runner.runEngine(args) { [weak self] status, _ in
            guard let self = self else { return }
            self.running = false; self.updateIcon()
            if showLogTail {
                let verdict = status == 0 ? "OK"
                    : (status == 2 ? T("leidis erinevusi", "differences found")
                                   : T("viga (kood \(status))", "error (code \(status))"))
                self.showOutput(title: "\(label): \(verdict)", text: self.logTail(400))
            } else if status == 0 {
                Runner.notify("Drive Backup", "\(label): " + T("valmis", "done"))
            }
            // On failure the engine already posts its own FAILED notification.
        }
    }

    @objc private func openPrefs() {
        if prefs == nil { prefs = PreferencesWindowController() }
        prefs?.reload()   // discard any abandoned edits; reflect current config
        NSApp.activate(ignoringOtherApps: true)
        prefs?.showWindow(nil)
        prefs?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func setupGDrive() {
        _ = Runner.shell("/usr/bin/open", ["-a", "Terminal", Paths.rcloneSetup])
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: Paths.log))
    }

    @objc private func openHelp() {
        if help == nil { help = OutputWindowController() }
        help?.show(title: T("Kasutusjuhend", "User guide"), text: Self.helpText)
    }

    @objc private func openAbout() {
        if about == nil { about = AboutWindowController() }
        about?.show()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // ---- usage guide -------------------------------------------------------

    static var helpText: String { T(helpET, helpEN) }

    private static let helpET = """
    DRIVE BACKUP — KASUTUSJUHEND
    ============================

    Mis see on
    ----------
    Ühesuunaline varukoopia sinu lokaalsetest kaustadest (Documents, Desktop, …)
    Google Drive'i. Töötab taustal ja käivitub valitud intervalliga.

    OHUTUS
    ------
    Sinu Maci ega iCloudi faile see tööriist EI KUSTUTA kunagi — sünkroniseerimine
    ainult loeb allikat ja kirjutab Google Drive'i. Drive'i poolel liiguvad
    kustutatud/muudetud failid prügikasti (vaikimisi 90 päeva alles), mitte kohe
    kaotsi. Mass-kustutamise kaitse peatab sünki, kui midagi on allikas valesti.

    ENNE ALUSTAMIST (OLULINE)
    -------------------------
    Macis lülita System Settings → Apple Account → iCloud → "Optimise Mac
    Storage" (Optimeeri Maci salvestusruumi) VÄLJA — muidu pole failid päriselt
    kettal olemas (need on 0-baidised iCloudi kohatäited) ja neid ei saa varundada.
    Anna backupile ka Full Disk Access: System Settings → Privacy & Security →
    Full Disk Access → lisa "Drive Backup" ja /bin/bash.

    ESMANE SEADISTUS
    ----------------
    1) Menüü → "Seadista Google Drive…"
       Terminalis: nimi = gdrive, tüüp = drive. SOOVITATAV: kasuta oma Google
       client_id't (jagatud aegub 2026); muidu jäta tühjaks (Enter). Seejärel
       logi brauseris Google'isse.
    2) Menüü → "Seaded…"
       - Vali kaustad (Documents, Desktop, "Lisa kaust…" suvalise jaoks)
       - Sünkimise intervall (minutites)
       - Prügikasti säilitus (nt 90d) või märgi "Hoia kõik alles"
       - Märgi "Ajakava sees" ja vajuta Salvesta
    3) Menüü → "Backup nüüd" — esimene täissünk (võib võtta aega).

    IGAPÄEVANE KASUTUS
    ------------------
    - Backup nüüd    — käivita sünk kohe
    - Kuivkäik       — näita, mida tehtaks, ilma midagi muutmata
    - Kontrolli      — võrdle checksummidega, kas kõik on backupis olemas ja terve
    - Ava logi       — vaata detailset tegevuslogi
    - Menüü ülaosa näitab, millal viimati õnnestus ja kas ajakava on sees

    SEADED
    ------
    - Intervall: kui tihti taustal sünkida (nt 60 min)
    - Max kustutamisi: kui sünk tahaks korraga rohkem faile kustutada, katkeb ta
      turvalisuse mõttes (vaikimisi 500)
    - Prügikasti säilitus: kui kaua hoitakse kustutatute koopiaid Drive'is; "Hoia
      kõik alles" = ei kustutata kunagi midagi

    TAASTAMINE
    ----------
    Failid on Google Drive'is loetavalt (Mac-Backup/…). Terminalist:
      rclone copy gdrive:Mac-Backup/Documents ~/Documents-restored -P

    Rohkem infot: menüü → "Programmist…" → GitHub.
    """

    private static let helpEN = """
    DRIVE BACKUP — USER GUIDE
    =========================

    What it is
    ----------
    A one-way backup of your local folders (Documents, Desktop, …) to Google
    Drive. Runs in the background and fires on the interval you choose.

    SAFETY
    ------
    This tool NEVER deletes files on your Mac or in iCloud — a sync only reads the
    source and writes to Google Drive. On the Drive side, deleted/changed files go
    to a trash folder (kept 90 days by default), not straight to oblivion. A
    mass-deletion guard halts the sync if something is wrong at the source.

    BEFORE YOU START (IMPORTANT)
    ----------------------------
    On the Mac, turn System Settings → Apple Account → iCloud → "Optimise Mac
    Storage" OFF — otherwise the files are not really on disk (they are 0-byte
    iCloud placeholders) and cannot be backed up. Also give the backup Full Disk
    Access: System Settings → Privacy & Security → Full Disk Access → add
    "Drive Backup" and /bin/bash.

    FIRST-TIME SETUP
    ----------------
    1) Menu → "Set up Google Drive…"
       In Terminal: name = gdrive, type = drive. RECOMMENDED: use your own Google
       client_id (the shared one retires in 2026); otherwise leave blank (Enter).
       Then sign in to Google in the browser.
    2) Menu → "Settings…"
       - Pick folders (Documents, Desktop, "Add folder…" for anything else)
       - Sync interval (in minutes)
       - Trash retention (e.g. 90d) or tick "Keep everything"
       - Tick "Schedule on" and click Save
    3) Menu → "Back up now" — the first full sync (may take a while).

    EVERYDAY USE
    ------------
    - Back up now  — run a sync immediately
    - Dry run      — show what would change, without changing anything
    - Verify       — checksum-compare that everything is present and intact
    - Open log     — view the detailed activity log
    - The top of the menu shows when the last success was and whether the
      schedule is on

    SETTINGS
    --------
    - Interval: how often to sync in the background (e.g. 60 min)
    - Max deletions: if a sync would delete more files than this at once, it
      aborts for safety (default 500)
    - Trash retention: how long deleted copies are kept on Drive; "Keep
      everything" = nothing is ever purged

    RESTORE
    -------
    Files are readable in Google Drive (Mac-Backup/…). From Terminal:
      rclone copy gdrive:Mac-Backup/Documents ~/Documents-restored -P

    More info: menu → "About…" → GitHub.
    """

    // ---- helpers -----------------------------------------------------------

    private func updateIcon() {
        guard let btn = statusItem.button else { return }
        let symbol = running ? "arrow.triangle.2.circlepath" : "externaldrive.badge.icloud"
        btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Drive Backup")
                    ?? NSImage(systemSymbolName: "externaldrive", accessibilityDescription: "Drive Backup")
        btn.image?.isTemplate = true   // adapt to the menu-bar colour (max contrast, light & dark)
        btn.appearsDisabled = false    // never dim — a faded icon is invisible on a busy wallpaper
        btn.toolTip = running ? T("Backup töötab…", "Backing up…") : "Drive Backup"
    }

    private func lastSuccessDescription() -> String {
        guard let s = try? String(contentsOfFile: Paths.lastSuccess, encoding: .utf8),
              let ts = TimeInterval(s.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return T("pole veel", "not yet") }
        let mins = Int((Date().timeIntervalSince1970 - ts) / 60)
        if mins < 1 { return T("äsja", "just now") }
        if mins < 60 { return T("\(mins) min tagasi", "\(mins) min ago") }
        let h = mins / 60
        return h < 24 ? T("\(h) h tagasi", "\(h) h ago")
                      : T("\(h/24) päeva tagasi", "\(h/24) d ago")
    }

    private func logTail(_ n: Int) -> String {
        guard let text = try? String(contentsOfFile: Paths.log, encoding: .utf8) else {
            return T("(logi puudub)", "(no log yet)")
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(n).joined(separator: "\n")
    }

    private func showOutput(title: String, text: String) {
        if output == nil { output = OutputWindowController() }
        output?.show(title: title, text: text)
    }
}
