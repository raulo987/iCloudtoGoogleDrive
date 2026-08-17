import AppKit

// A large, resizable window for showing command output / log tails. Replaces the
// cramped NSAlert accessory so long output (and long lines) stay readable.
final class OutputWindowController: NSWindowController {

    private let textView = NSTextView()

    convenience init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 580),
                           styleMask: [.titled, .closable, .resizable, .miniaturizable],
                           backing: .buffered, defer: false)
        win.title = "Drive Backup"
        win.minSize = NSSize(width: 520, height: 320)
        self.init(window: win)
        buildUI()
    }

    private func buildUI() {
        guard let win = window else { return }
        let content = NSView()
        win.contentView = content

        // Scrollable, non-wrapping text view (both scrollers → long lines survive).
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = false
        scroll.borderType = .bezelBorder

        textView.isEditable = false
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        let big = CGFloat.greatestFiniteMagnitude
        textView.textContainer?.containerSize = NSSize(width: big, height: big)
        textView.maxSize = NSSize(width: big, height: big)
        scroll.documentView = textView

        let openLog = NSButton(title: T("Ava logifail", "Open log file"), target: self, action: #selector(openLogFile))
        openLog.bezelStyle = .rounded
        let close = NSButton(title: T("Sulge", "Close"), target: self, action: #selector(closeWindow))
        close.bezelStyle = .rounded; close.keyEquivalent = "\r"

        let buttons = NSStackView(views: [openLog, close])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(scroll)
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
    }

    func show(title: String, text: String) {
        window?.title = title
        textView.string = text.isEmpty ? T("(tühi väljund)", "(empty output)") : text
        textView.scrollToEndOfDocument(nil)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func openLogFile() { NSWorkspace.shared.open(URL(fileURLWithPath: Paths.log)) }
    @objc private func closeWindow() { window?.close() }
}
