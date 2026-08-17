import Foundation

// Two-language support (Estonian + English). Rather than a key/value catalogue,
// each call site carries both forms via `T(et, en)` — the translation lives next
// to its use, so nothing can drift out of sync or go missing.
enum Lang: String { case et, en }

enum L10n {
    // Posted when the language changes at runtime so the UI can rebuild.
    static let changed = Notification.Name("L10n.changed")

    // Resolved current language — never "auto"; already mapped to et/en.
    static var current: Lang = resolve(BackupConfig.load().language)

    // Map a stored preference ("" = auto, "et", "en") to an actual language.
    // Auto follows the macOS preferred language (Estonian → et, else English).
    static func resolve(_ pref: String) -> Lang {
        switch pref.trimmingCharacters(in: .whitespaces).lowercased() {
        case "et": return .et
        case "en": return .en
        default:
            let sysEstonian = Locale.preferredLanguages.first?.lowercased().hasPrefix("et") ?? false
            return sysEstonian ? .et : .en
        }
    }

    // Apply a stored preference; notify listeners only if the language changed.
    static func apply(_ pref: String) {
        let new = resolve(pref)
        guard new != current else { return }
        current = new
        NotificationCenter.default.post(name: changed, object: nil)
    }
}

// Pick the string for the current language. Keeps both forms at the call site.
func T(_ et: String, _ en: String) -> String {
    L10n.current == .et ? et : en
}
