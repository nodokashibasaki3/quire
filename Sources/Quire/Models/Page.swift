import Foundation
import GRDB

struct Page: Identifiable, Codable, Equatable, FetchableRecord, PersistableRecord {
    var date: String       // "YYYY-MM-DD" primary key
    var content: String    // outline text for this day
    var createdAt: Date

    var id: String { date }

    static let databaseTableName = "pages"
}
