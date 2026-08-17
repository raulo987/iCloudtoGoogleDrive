import AppKit

// Programmatic AppKit preferences window (no xib / no Xcode).
final class PreferencesWindowController: NSWindowController {

    private var config = BackupConfig.load()
    private let commonNames = ["Documents", "Desktop", "Downloads"]
    private var commonChecks: [NSButton] = []
    private var extraSources: [String] = []
    private let extraStack = NSStackView()
    private let intervalField = NSTextField()
    private let intervalStepper = NSStepper()
    private let maxDeleteField = NSTextField()
    private let retentionField = NSTextField()
    private let keepForeverCheck = NSButton(checkboxWithTitle:
        T("Hoia kõik alles (ära kunagi prügikasti tühjenda)",
          "Keep everything (never empty the trash)"), target: nil, action: nil)
    private let scheduleCheck = NSButton(checkboxWithTitle:
        T("Ajakava sees (automaatne backup)", "Schedule on (automatic backup)"), target: nil, action: nil)
    private let checksumCheck = NSButton(checkboxWithTitle:
        T("Põhjalik võrdlus (kontrollsummad, aeglasem)", "Thorough compare (checksums, slower)"), target: nil, action: nil)
    private let verifyCheck = NSButton(checkboxWithTitle:
        T("Iganädalane terviklikkuse kontroll", "Weekly integrity check"), target: nil, action: nil)
    private let bwlimitField = NSTextField()
    private let langPopup = NSPopUpButton()

    convenience init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 600),
                           styleMask: [.titled, .closable],
                           backing: .buffered, defer: false)
        win.title = T("Drive Backup — seaded", "Drive Backup — Settings")
        self.init(window: win)
        buildUI()
        loadValues()
        win.center()
    }

    // ---- UI construction ---------------------------------------------------

    private func header(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = NSFont.boldSystemFont(ofSize: 13)
        return l
    }
    private func row(_ views: [NSView]) -> NSStackView {
        let r = NSStackView(views: views)
        r.orientation = .horizontal
        r.spacing = 8
        r.alignment = .firstBaseline
        return r
    }

    private func buildUI() {
        guard let win = window else { return }
        let content = NSView()
        win.contentView = content

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            root.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
        ])

        // Language
        langPopup.addItems(withTitles: [T("Automaatne (süsteem)", "Automatic (system)"), "Eesti", "English"])
        root.addArrangedSubview(row([NSTextField(labelWithString: T("Keel:", "Language:")), langPopup]))
        root.addArrangedSubview(NSBox.separator())

        // Folders
        root.addArrangedSubview(header(T("Kaustad, mida backup'ida", "Folders to back up")))
        for name in commonNames {
            let cb = NSButton(checkboxWithTitle: name, target: nil, action: nil)
            commonChecks.append(cb)
            root.addArrangedSubview(cb)
        }

        root.addArrangedSubview(header(T("Lisatud kaustad", "Added folders")))
        extraStack.orientation = .vertical
        extraStack.alignment = .leading
        extraStack.spacing = 4
        root.addArrangedSubview(extraStack)
        let addBtn = NSButton(title: T("Lisa kaust…", "Add folder…"), target: self, action: #selector(addFolder))
        addBtn.bezelStyle = .rounded
        root.addArrangedSubview(addBtn)

        root.addArrangedSubview(NSBox.separator())

        // Numbers
        intervalField.formatter = intFormatter()
        intervalField.preferredMaxLayoutWidth = 60
        intervalField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        intervalStepper.minValue = 5; intervalStepper.maxValue = 1440; intervalStepper.increment = 5
        intervalStepper.target = self; intervalStepper.action = #selector(stepInterval)
        root.addArrangedSubview(row([NSTextField(labelWithString: T("Sünkimise intervall (min):", "Sync interval (min):")),
                                     intervalField, intervalStepper]))

        maxDeleteField.formatter = intFormatter()
        maxDeleteField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        root.addArrangedSubview(row([NSTextField(labelWithString: T("Max kustutamisi enne katkestust:", "Max deletions before aborting:")),
                                     maxDeleteField]))

        retentionField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        root.addArrangedSubview(row([NSTextField(labelWithString: T("Prügikasti säilitus (nt 90d):", "Trash retention (e.g. 90d):")),
                                     retentionField]))
        keepForeverCheck.target = self
        keepForeverCheck.action = #selector(toggleKeepForever)
        root.addArrangedSubview(keepForeverCheck)

        bwlimitField.widthAnchor.constraint(equalToConstant: 100).isActive = true
        bwlimitField.placeholderString = T("nt 10M / tühi", "e.g. 10M / blank")
        root.addArrangedSubview(row([NSTextField(labelWithString: T("Ribalaiuse piir:", "Bandwidth limit:")),
                                     bwlimitField]))

        root.addArrangedSubview(scheduleCheck)
        root.addArrangedSubview(checksumCheck)
        root.addArrangedSubview(verifyCheck)

        root.addArrangedSubview(NSBox.separator())

        // Buttons
        let save = NSButton(title: T("Salvesta", "Save"), target: self, action: #selector(saveClicked))
        save.bezelStyle = .rounded; save.keyEquivalent = "\r"
        let cancel = NSButton(title: T("Tühista", "Cancel"), target: self, action: #selector(cancelClicked))
        cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"
        let btnRow = row([cancel, save])
        btnRow.alignment = .centerY
        root.addArrangedSubview(btnRow)
    }

    private func intFormatter() -> NumberFormatter {
        let f = NumberFormatter(); f.numberStyle = .none; f.minimum = 0; f.allowsFloats = false
        return f
    }

    // ---- state <-> UI ------------------------------------------------------

    // Re-read config into the fields. Called on every reopen so Cancel discards
    // edits and external changes are reflected.
    func reload() { loadValues() }

    private func loadValues() {
        config = BackupConfig.load()
        switch config.language.lowercased() {
        case "et": langPopup.selectItem(at: 1)
        case "en": langPopup.selectItem(at: 2)
        default:   langPopup.selectItem(at: 0)   // auto
        }
        for (i, name) in commonNames.enumerated() {
            commonChecks[i].state = config.sources.contains(name) ? .on : .off
        }
        extraSources = config.sources.filter { !commonNames.contains($0) }
        rebuildExtra()
        intervalField.integerValue = config.intervalMinutes
        intervalStepper.integerValue = config.intervalMinutes
        maxDeleteField.integerValue = config.maxDelete
        if isNever(config.retention) {
            keepForeverCheck.state = .on
            retentionField.stringValue = "90d"   // sensible value if they later uncheck
            retentionField.isEnabled = false
        } else {
            keepForeverCheck.state = .off
            retentionField.stringValue = config.retention
            retentionField.isEnabled = true
        }
        scheduleCheck.state = config.scheduleEnabled ? .on : .off
        checksumCheck.state = config.checksum ? .on : .off
        verifyCheck.state = config.verifyEnabled ? .on : .off
        bwlimitField.stringValue = config.bandwidthLimit
    }

    private func isNever(_ s: String) -> Bool {
        ["never", "forever", "off", "0", ""].contains(
            s.trimmingCharacters(in: .whitespaces).lowercased())
    }

    private func rebuildExtra() {
        extraStack.arrangedSubviews.forEach { extraStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        if extraSources.isEmpty {
            let l = NSTextField(labelWithString: T("(puuduvad)", "(none)"))
            l.textColor = .secondaryLabelColor
            extraStack.addArrangedSubview(l)
            return
        }
        for (i, path) in extraSources.enumerated() {
            let label = NSTextField(labelWithString: path)
            label.lineBreakMode = .byTruncatingMiddle
            let rm = NSButton(title: T("Eemalda", "Remove"), target: self, action: #selector(removeFolder(_:)))
            rm.bezelStyle = .rounded; rm.tag = i
            let r = row([rm, label])
            extraStack.addArrangedSubview(r)
        }
    }

    // ---- actions -----------------------------------------------------------

    @objc private func stepInterval() { intervalField.integerValue = intervalStepper.integerValue }

    // Selected language string for the current popup choice ("" = auto).
    private func selectedLanguage() -> String {
        switch langPopup.indexOfSelectedItem {
        case 1:  return "et"
        case 2:  return "en"
        default: return ""
        }
    }


    @objc private func toggleKeepForever() {
        retentionField.isEnabled = (keepForeverCheck.state == .off)
    }

    @objc private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = T("Lisa", "Add")
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK {
            for url in panel.urls where !extraSources.contains(url.path) {
                extraSources.append(url.path)
            }
            rebuildExtra()
        }
    }

    @objc private func removeFolder(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < extraSources.count else { return }
        extraSources.remove(at: sender.tag)
        rebuildExtra()
    }

    @objc private func cancelClicked() { window?.close() }

    @objc private func saveClicked() {
        var sources: [String] = []
        for (i, name) in commonNames.enumerated() where commonChecks[i].state == .on {
            sources.append(name)
        }
        sources.append(contentsOf: extraSources)
        if sources.isEmpty {
            alert(T("Vali vähemalt üks kaust", "Pick at least one folder"), style: .warning); return
        }
        config.language = selectedLanguage()
        config.sources = sources
        config.intervalMinutes = max(5, intervalField.integerValue)
        config.maxDelete = max(1, maxDeleteField.integerValue)
        if keepForeverCheck.state == .on {
            config.retention = "never"
        } else {
            config.retention = retentionField.stringValue.isEmpty ? "90d" : retentionField.stringValue
        }
        config.scheduleEnabled = (scheduleCheck.state == .on)
        config.checksum = (checksumCheck.state == .on)
        config.verifyEnabled = (verifyCheck.state == .on)
        config.bandwidthLimit = bwlimitField.stringValue.trimmingCharacters(in: .whitespaces)

        do {
            try config.save()
            if config.scheduleEnabled {
                try Schedule.enable(intervalMinutes: config.intervalMinutes)
            } else {
                Schedule.disable()
            }
            if config.verifyEnabled {
                try Schedule.enableVerify(intervalDays: config.verifyIntervalDays)
            } else {
                Schedule.disableVerify()
            }
        } catch {
            alert(T("Salvestamine ebaõnnestus: ", "Saving failed: ") + error.localizedDescription, style: .critical); return
        }
        window?.close()
        L10n.apply(config.language)   // relabel menu + windows if the language changed
    }

    private func alert(_ msg: String, style: NSAlert.Style) {
        let a = NSAlert(); a.messageText = msg; a.alertStyle = style
        a.addButton(withTitle: "OK")
        a.runModal()
    }
}

private extension NSBox {
    static func separator() -> NSBox {
        let b = NSBox(); b.boxType = .separator
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: 380).isActive = true
        return b
    }
}
