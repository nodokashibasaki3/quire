import Foundation
import Observation

/// Stores each day's outline as a plain markdown file (`YYYY-MM-DD.md`) in a user-configurable
/// folder. The folder path is persisted in UserDefaults; if unset, defaults to
/// `~/Documents/Quire`. Other internal state (timer history, Canvas sync dedup) remains in
/// SQLite under Application Support — only the user's actual content lives here.
@MainActor
@Observable
final class PageFileStore {
    private(set) var folderURL: URL

    nonisolated static let storageFolderKey = "storageFolderPath"

    init() {
        self.folderURL = Self.resolveFolderURL()
        try? FileManager.default.createDirectory(at: self.folderURL, withIntermediateDirectories: true)
    }

    func setFolderURL(_ url: URL) {
        folderURL = url
        UserDefaults.standard.set(url.path, forKey: Self.storageFolderKey)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func fileURL(for date: String) -> URL {
        folderURL.appendingPathComponent("\(date).md")
    }

    func loadContent(for date: String) -> String? {
        Self.readFile(in: folderURL, date: date)
    }

    func saveContent(_ content: String, for date: String) {
        try? Self.writeFile(in: folderURL, date: date, content: content)
    }

    func mostRecentDate(before date: String) -> String? {
        Self.mostRecentDate(in: folderURL, before: date)
    }

    // MARK: - Nonisolated helpers (safe to call from migration / background queues)

    nonisolated static func resolveFolderURL() -> URL {
        if let saved = UserDefaults.standard.string(forKey: storageFolderKey), !saved.isEmpty {
            return URL(fileURLWithPath: (saved as NSString).expandingTildeInPath)
        }
        return defaultFolderURL
    }

    nonisolated static var defaultFolderURL: URL {
        let documents = (try? FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )) ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        return documents.appendingPathComponent("Quire", isDirectory: true)
    }

    nonisolated static func writeFile(in folder: URL, date: String, content: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(date).md")
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    nonisolated static func readFile(in folder: URL, date: String) -> String? {
        let url = folder.appendingPathComponent("\(date).md")
        return try? String(contentsOf: url, encoding: .utf8)
    }

    nonisolated static func mostRecentDate(in folder: URL, before date: String) -> String? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil
        ) else { return nil }
        let dates = entries
            .filter { $0.pathExtension == "md" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .filter { isValidDateFormat($0) && $0 < date }
            .sorted()
        return dates.last
    }

    nonisolated static let datePattern: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}$"#)
    }()

    nonisolated static func isValidDateFormat(_ s: String) -> Bool {
        let range = NSRange(location: 0, length: (s as NSString).length)
        return datePattern.firstMatch(in: s, range: range) != nil
    }
}
