import Foundation
import GRDB
import Observation

/// Tracks elapsed time per todo task (identified by line content within a page).
/// Only one timer can be active at a time. Active session is persisted to the database
/// so it survives app relaunches.
@MainActor
@Observable
final class TimerStore {
    struct ActiveSession: Equatable {
        let id: Int64
        let pageDate: String
        let taskKey: String
        let startedAt: Date
    }

    private(set) var active: ActiveSession?
    /// Bumped every second while a timer is active — exists purely so SwiftUI can observe
    /// it and trigger redraws of the editor's timer pills.
    private(set) var tick: Int = 0

    @ObservationIgnored private let dbQueue: DatabaseQueue
    @ObservationIgnored private var tickTask: Task<Void, Never>?

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
        loadActive()
        if active != nil {
            startTicker()
        }
    }

    // MARK: - Lifecycle

    private func loadActive() {
        let row = try? dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: """
                SELECT id, page_date, task_key, started_at
                FROM timer_sessions
                WHERE ended_at IS NULL
                ORDER BY started_at DESC
                LIMIT 1
                """
            )
        }
        if let row {
            active = ActiveSession(
                id: row["id"],
                pageDate: row["page_date"],
                taskKey: row["task_key"],
                startedAt: row["started_at"]
            )
        }
    }

    // MARK: - Public API

    /// Returns true if `taskKey` on `pageDate` currently has the active session.
    func isActive(taskKey: String, pageDate: String) -> Bool {
        guard let active else { return false }
        return active.taskKey == taskKey && active.pageDate == pageDate
    }

    /// Total accumulated seconds for a task on a given page, including any in-progress session.
    func totalSeconds(taskKey: String, pageDate: String) -> TimeInterval {
        let rows = (try? dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT started_at, ended_at FROM timer_sessions WHERE page_date = ? AND task_key = ?",
                arguments: [pageDate, taskKey]
            )
        }) ?? []

        let now = Date()
        var total: TimeInterval = 0
        for row in rows {
            let start: Date = row["started_at"]
            let end: Date = row["ended_at"] ?? now
            total += end.timeIntervalSince(start)
        }
        return total
    }

    /// Starts a timer for the given task. If another timer is active, it is stopped first.
    func start(taskKey: String, pageDate: String) {
        if active != nil {
            stop()
        }
        let now = Date()
        do {
            let id = try dbQueue.write { db -> Int64 in
                try db.execute(
                    sql: """
                    INSERT INTO timer_sessions (page_date, task_key, started_at)
                    VALUES (?, ?, ?)
                    """,
                    arguments: [pageDate, taskKey, now]
                )
                return db.lastInsertedRowID
            }
            active = ActiveSession(id: id, pageDate: pageDate, taskKey: taskKey, startedAt: now)
            startTicker()
        } catch {
            // Surface in the future via an error property; for now swallow.
        }
    }

    /// Stops the active timer (if any) and writes the end timestamp.
    func stop() {
        guard let session = active else { return }
        let now = Date()
        do {
            try dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE timer_sessions SET ended_at = ? WHERE id = ?",
                    arguments: [now, session.id]
                )
            }
        } catch {
            // Swallow; the in-memory active will still be cleared so user sees consistent state.
        }
        active = nil
        stopTicker()
    }

    /// If this task is currently active, stops it. Otherwise starts a new session for it.
    func toggle(taskKey: String, pageDate: String) {
        if isActive(taskKey: taskKey, pageDate: pageDate) {
            stop()
        } else {
            start(taskKey: taskKey, pageDate: pageDate)
        }
    }

    // MARK: - Ticker

    private func startTicker() {
        tickTask?.cancel()
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.tick &+= 1
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func stopTicker() {
        tickTask?.cancel()
        tickTask = nil
    }
}
