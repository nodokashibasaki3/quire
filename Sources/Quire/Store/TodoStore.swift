import Foundation
import GRDB
import Observation

@MainActor
@Observable
final class TodoStore {
    private(set) var currentDate: String = DateHelpers.today()
    private(set) var content: String = ""
    private(set) var loadError: String?

    @ObservationIgnored let dbQueue: DatabaseQueue
    @ObservationIgnored let pageStore: PageFileStore
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(pageStore: PageFileStore) throws {
        self.pageStore = pageStore

        let fm = FileManager.default
        let appSupport = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("Quire", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("quire.sqlite")

        var config = Configuration()
        config.label = "QuireDB"
        self.dbQueue = try DatabaseQueue(path: dbURL.path, configuration: config)

        try Self.migrate(dbQueue)
        loadOrCreatePage(for: currentDate, performCarryForward: true)
    }

    static func migrate(_ dbQueue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("createTodos") { db in
            try db.create(table: "todos") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("title", .text).notNull()
                t.column("isDone", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v2_pages") { db in
            try db.create(table: "pages") { t in
                t.column("date", .text).notNull().primaryKey()
                t.column("createdAt", .datetime).notNull()
            }

            try db.execute(sql: "ALTER TABLE todos ADD COLUMN pageDate TEXT NOT NULL DEFAULT ''")
            try db.execute(sql: "ALTER TABLE todos ADD COLUMN sortOrder INTEGER NOT NULL DEFAULT 0")
            try db.execute(sql: "ALTER TABLE todos ADD COLUMN carriedFromDate TEXT")

            let today = DateHelpers.today()
            try db.execute(
                sql: "UPDATE todos SET pageDate = ? WHERE pageDate = ''",
                arguments: [today]
            )

            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM todos") ?? 0
            if count > 0 {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO pages (date, createdAt) VALUES (?, ?)",
                    arguments: [today, Date()]
                )
            }
        }

        migrator.registerMigration("v3_blocks") { db in
            try db.execute(sql: "ALTER TABLE todos RENAME TO blocks")
            try db.execute(sql: "ALTER TABLE blocks RENAME COLUMN title TO content")
            try db.execute(sql: "ALTER TABLE blocks ADD COLUMN type TEXT NOT NULL DEFAULT 'todo'")
        }

        migrator.registerMigration("v4_pageContent") { db in
            try db.execute(sql: "ALTER TABLE pages ADD COLUMN content TEXT NOT NULL DEFAULT ''")

            let pageDates = try String.fetchAll(db, sql: "SELECT date FROM pages ORDER BY date ASC")
            for date in pageDates {
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT type, content, isDone FROM blocks WHERE pageDate = ? ORDER BY sortOrder ASC, id ASC",
                    arguments: [date]
                )
                if rows.isEmpty { continue }
                var lines: [String] = []
                for row in rows {
                    let type: String = row["type"] ?? "todo"
                    let body: String = row["content"] ?? ""
                    let isDone: Bool = row["isDone"] ?? false
                    let line: String
                    switch type {
                    case "todo":    line = "- \(isDone ? "DONE" : "TODO") \(body)"
                    case "heading": line = "- ## \(body)"
                    case "callout": line = "- > \(body)"
                    case "quote":   line = "- \"\(body)\""
                    case "divider": line = "---"
                    default:        line = "- \(body)"
                    }
                    lines.append(line)
                }
                let stitched = lines.joined(separator: "\n")
                try db.execute(
                    sql: "UPDATE pages SET content = ? WHERE date = ?",
                    arguments: [stitched, date]
                )
            }

            try db.execute(sql: "DROP TABLE IF EXISTS blocks")
        }

        migrator.registerMigration("v5_markdownChecklist") { db in
            let pages = try Page.fetchAll(db)
            for page in pages {
                var content = page.content
                content = content.replacingOccurrences(of: "- TODO ", with: "- [ ] ")
                content = content.replacingOccurrences(of: "- DONE ", with: "- [x] ")
                content = content.replacingOccurrences(of: "- WAITING ", with: "- [ ] ")
                content = content.replacingOccurrences(of: "- CANCELED ", with: "- [x] ")
                if content != page.content {
                    try db.execute(
                        sql: "UPDATE pages SET content = ? WHERE date = ?",
                        arguments: [content, page.date]
                    )
                }
            }
        }

        migrator.registerMigration("v6_stripDash") { db in
            let regex = try NSRegularExpression(pattern: #"^(\t*)- "#, options: .anchorsMatchLines)
            let pages = try Page.fetchAll(db)
            for page in pages {
                let nsContent = page.content as NSString
                let newContent = regex.stringByReplacingMatches(
                    in: page.content,
                    range: NSRange(location: 0, length: nsContent.length),
                    withTemplate: "$1"
                )
                if newContent != page.content {
                    try db.execute(
                        sql: "UPDATE pages SET content = ? WHERE date = ?",
                        arguments: [newContent, page.date]
                    )
                }
            }
        }

        migrator.registerMigration("v7_addDash") { db in
            let pages = try Page.fetchAll(db)
            for page in pages {
                let lines = page.content.components(separatedBy: "\n")
                let newLines: [String] = lines.map { line in
                    if line.trimmingCharacters(in: .whitespaces).isEmpty { return line }
                    var idx = line.startIndex
                    while idx < line.endIndex, line[idx] == "\t" {
                        idx = line.index(after: idx)
                    }
                    let indent = String(line[line.startIndex..<idx])
                    let body = String(line[idx...])
                    if body.hasPrefix("- ") || body == "-" { return line }
                    return indent + "- " + body
                }
                let newContent = newLines.joined(separator: "\n")
                if newContent != page.content {
                    try db.execute(
                        sql: "UPDATE pages SET content = ? WHERE date = ?",
                        arguments: [newContent, page.date]
                    )
                }
            }
        }

        migrator.registerMigration("v8_canvasSynced") { db in
            try db.create(table: "canvas_synced") { t in
                t.column("assignment_id", .text).notNull().primaryKey()
                t.column("course_name", .text)
                t.column("title", .text)
                t.column("due_at", .datetime)
                t.column("synced_at", .datetime).notNull()
                t.column("synced_to_date", .text).notNull()
            }
        }

        migrator.registerMigration("v9_timerSessions") { db in
            try db.create(table: "timer_sessions") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("page_date", .text).notNull()
                t.column("task_key", .text).notNull()
                t.column("started_at", .datetime).notNull()
                t.column("ended_at", .datetime)
            }
            try db.create(
                index: "idx_timer_sessions_page_task",
                on: "timer_sessions",
                columns: ["page_date", "task_key"]
            )
        }

        migrator.registerMigration("v10_pagesToFiles") { db in
            // Export every existing page out of the database into the user's chosen folder
            // as a plain `YYYY-MM-DD.md` file. The pages table is left in place as a backup
            // — future code reads files only, but the table can be inspected if needed.
            let folderURL = PageFileStore.resolveFolderURL()
            let pages = try Page.fetchAll(db)
            for page in pages {
                try? PageFileStore.writeFile(in: folderURL, date: page.date, content: page.content)
            }
        }

        try migrator.migrate(dbQueue)
    }

    // MARK: - Navigation

    var isToday: Bool { currentDate == DateHelpers.today() }

    func goTo(date: String) {
        flushPendingSave()
        currentDate = date
        loadOrCreatePage(for: date, performCarryForward: date == DateHelpers.today())
    }

    func goToPrev() { goTo(date: DateHelpers.addDays(-1, to: currentDate)) }
    func goToNext() { goTo(date: DateHelpers.addDays(1, to: currentDate)) }
    func goToToday() { goTo(date: DateHelpers.today()) }

    /// Re-loads the current page from disk. Call this when the storage folder changes so the
    /// editor reflects whatever's at the new location.
    func reloadCurrentPage() {
        flushPendingSave()
        loadOrCreatePage(for: currentDate, performCarryForward: currentDate == DateHelpers.today())
    }

    // MARK: - Page lifecycle

    private func loadOrCreatePage(for date: String, performCarryForward: Bool) {
        let existing = pageStore.loadContent(for: date) ?? ""

        if !existing.isEmpty {
            content = existing
            return
        }

        let seed: String = performCarryForward ? buildCarryForwardSeed(for: date) : ""

        if !seed.isEmpty {
            pageStore.saveContent(seed, for: date)
        }
        content = seed
    }

    private func buildCarryForwardSeed(for today: String) -> String {
        guard let prevDate = pageStore.mostRecentDate(before: today),
              let prevContent = pageStore.loadContent(for: prevDate)
        else { return "" }
        return Self.stripCompleted(from: prevContent)
    }

    /// Remove lines that are completed (`[x]`/`[X]` after optional `- ` bullet markers).
    static func stripCompleted(from text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let kept = lines.filter { !isCompleted($0) }
        return kept.joined(separator: "\n")
    }

    private static func isCompleted(_ line: String) -> Bool {
        var idx = line.startIndex
        while idx < line.endIndex, line[idx].isWhitespace { idx = line.index(after: idx) }
        guard idx < line.endIndex else { return false }
        var rest = line[idx...]
        if rest.hasPrefix("- ") {
            rest = rest.dropFirst(2)
        }
        return rest.hasPrefix("[x]") || rest.hasPrefix("[X]")
    }

    // MARK: - Saving

    func updateContent(_ newContent: String) {
        guard newContent != content else { return }
        content = newContent
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let date = currentDate
        let snapshot = content
        let store = pageStore
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000) // 250ms debounce
            guard !Task.isCancelled else { return }
            await MainActor.run {
                store.saveContent(snapshot, for: date)
                _ = self // keep self alive long enough for the closure to fire
            }
        }
    }

    private func flushPendingSave() {
        saveTask?.cancel()
        let date = currentDate
        let snapshot = content
        pageStore.saveContent(snapshot, for: date)
    }

    // MARK: - Canvas sync

    /// Merges new Canvas items into today's page. Already-synced items (by Canvas assignment ID)
    /// are skipped, so calling this repeatedly is idempotent. Returns the number of items added.
    @discardableResult
    func applyCanvasItems(_ items: [CanvasItem]) -> Int {
        guard !items.isEmpty else { return 0 }
        let today = DateHelpers.today()

        do {
            let alreadySynced: Set<String> = try dbQueue.read { db in
                let ids = try String.fetchAll(db, sql: "SELECT assignment_id FROM canvas_synced")
                return Set(ids)
            }

            let fresh = items.filter { !alreadySynced.contains($0.id) }
            guard !fresh.isEmpty else { return 0 }

            if currentDate == today { flushPendingSave() }

            let priorContent: String
            if currentDate == today {
                priorContent = content
            } else {
                priorContent = pageStore.loadContent(for: today) ?? ""
            }

            let merged = Self.mergeCanvasItems(into: priorContent, items: fresh)
            pageStore.saveContent(merged, for: today)

            try dbQueue.write { db in
                for item in fresh {
                    try db.execute(
                        sql: """
                        INSERT INTO canvas_synced
                            (assignment_id, course_name, title, due_at, synced_at, synced_to_date)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [item.id, item.courseName, item.title, item.dueAt, Date(), today]
                    )
                }
            }

            if currentDate == today {
                content = merged
            }
            return fresh.count
        } catch {
            loadError = error.localizedDescription
            return 0
        }
    }

    private static func mergeCanvasItems(into priorContent: String, items: [CanvasItem]) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "MMM d"
        dateFormatter.timeZone = .current

        let newLines: [String] = items.map { item in
            let dueStr = item.dueAt.map { " · due " + dateFormatter.string(from: $0) } ?? ""
            let title = item.title
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let course = item.courseName
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let label = course.isEmpty ? title : "\(course) — \(title)"
            return "\t- [ ] \(label)\(dueStr)"
        }

        let lines = priorContent.components(separatedBy: "\n")
        if let canvasIdx = lines.firstIndex(where: { $0 == "- ## Canvas" }) {
            var insertIdx = canvasIdx + 1
            while insertIdx < lines.count, lines[insertIdx].hasPrefix("\t") {
                insertIdx += 1
            }
            var merged = lines
            merged.insert(contentsOf: newLines, at: insertIdx)
            return merged.joined(separator: "\n")
        }

        let separator = priorContent.isEmpty ? "" : "\n"
        return priorContent + separator + "- ## Canvas\n" + newLines.joined(separator: "\n")
    }
}
