import AppKit

// "Programmist" (About) window: creator, contact, and project link.
final class AboutWindowController: NSWindowController {

    private static let githubURL = "https://github.com/raulo987/iCloudtoGoogleDrive"
    private static let email = "raul@orav.me"
    private static let companyURL = "https://itteam.eu"

    convenience init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
                           styleMask: [.titled, .closable],
                           backing: .buffered, defer: false)
        win.title = T("Programmist", "About")
        self.init(window: win)
        buildUI()
    }

    func show() {
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildUI() {
        guard let win = window else { return }
        let content = NSView()
        win.contentView = content

        let title = NSTextField(labelWithString: "Drive Backup")
        title.font = .boldSystemFont(ofSize: 18)
        let version = NSTextField(labelWithString: T("Versioon 1.0  ·  iCloudtoGoogleDrive",
                                                     "Version 1.0  ·  iCloudtoGoogleDrive"))
        version.textColor = .secondaryLabelColor
        version.font = .systemFont(ofSize: 11)

        let desc = NSTextField(wrappingLabelWithString: T(
            "Ühesuunaline Mac → Google Drive varukoopia menüüribast. Vaba tarkvara (MIT litsents).",
            "One-way Mac → Google Drive backup from the menu bar. Free software (MIT licence)."))
        desc.font = .systemFont(ofSize: 12)

        let creator = NSTextField(labelWithString: T("Looja: Raul Orav", "Creator: Raul Orav"))
        creator.font = .systemFont(ofSize: 13, weight: .medium)

        let company = NSTextField(labelWithString: T("Arendaja: Visioline Infra Ltd",
                                                     "Developer: Visioline Infra Ltd"))
        company.font = .systemFont(ofSize: 13, weight: .medium)

        let mailBtn = NSButton(title: Self.email, target: self, action: #selector(sendEmail))
        mailBtn.bezelStyle = .rounded
        let githubBtn = NSButton(title: "GitHub", target: self, action: #selector(openGitHub))
        githubBtn.bezelStyle = .rounded
        let webBtn = NSButton(title: "itteam.eu", target: self, action: #selector(openCompany))
        webBtn.bezelStyle = .rounded
        let closeBtn = NSButton(title: T("Sulge", "Close"), target: self, action: #selector(closeWindow))
        closeBtn.bezelStyle = .rounded; closeBtn.keyEquivalent = "\r"

        let links = NSStackView(views: [mailBtn, githubBtn, webBtn])
        links.orientation = .horizontal; links.spacing = 8

        let root = NSStackView(views: [title, version, desc, creator, company, links, closeBtn])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            root.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
        ])
    }

    @objc private func sendEmail() {
        if let url = URL(string: "mailto:\(Self.email)") { NSWorkspace.shared.open(url) }
    }
    @objc private func openGitHub() {
        if let url = URL(string: Self.githubURL) { NSWorkspace.shared.open(url) }
    }
    @objc private func openCompany() {
        if let url = URL(string: Self.companyURL) { NSWorkspace.shared.open(url) }
    }
    @objc private func closeWindow() { window?.close() }
}
