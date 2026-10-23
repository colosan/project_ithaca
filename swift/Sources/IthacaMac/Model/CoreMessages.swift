// The core reports open-time problems as English sentences (LibraryInfo.problems). The Korean UI shows its own sentence
// for each known one (ADR-0005: no raw English in the ko UI); the original stays available as a tooltip.
import Foundation
import IthacaDesign

enum CoreMessages {
    /// Known core sentences → a string key and the arguments pulled out of the sentence.
    private static let patterns: [(String, L10nKey, [String])] = [
        (#"^Another Ithaca has this library open"#, .problemLockedByOther, []),
        (#"^This folder does not support locking"#, .problemNoLocking, []),
        (#"^The projects folder could not be read"#, .problemProjectsUnreadable, []),
        (#"^Project (.+?) was skipped"#, .problemProjectSkipped, ["name"]),
        (#"library\.json is missing but the folder holds projects"#, .problemLibraryFileMissing, []),
        (#"^(The library needs an update|Could not back up before updating|Updating the library from format)"#, .problemUpdateFailed, []),
        (#"^The table of contents of "(.*)" is damaged"#, .problemTocDamaged, ["title"]),
        (#"^Sheet "(.*)" in "(.*)" is damaged"#, .problemSheetDamaged, ["name", "title"]),
        (#"^"(.*)" has \d+ change files that can't be read"#, .problemUnattributed, ["title"]),
        (#"^Removing old automatic backups failed"#, .problemBackupPrune, []),
    ]

    /// The problem in the UI language. English: the core's sentence as is.
    static func problem(_ message: String, locale: L10nLocale) -> String {
        guard locale == .ko else { return message }
        for (pattern, key, names) in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)) else { continue }
            var args: [String: String] = [:]
            for (i, name) in names.enumerated() where i + 1 < m.numberOfRanges {
                if let r = Range(m.range(at: i + 1), in: message) { args[name] = String(message[r]) }
            }
            return L10n.string(key, locale: locale, args)
        }
        return L10n.string(.problemOther, locale: locale)
    }
}

extension AppModel {
    func problemText(_ message: String) -> String { CoreMessages.problem(message, locale: locale) }
}
