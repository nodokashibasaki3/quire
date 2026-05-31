import Foundation

enum DateHelpers {
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        f.timeZone = .current
        return f
    }()

    private static let longDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM d, yyyy"
        f.timeZone = .current
        return f
    }()

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        f.timeZone = .current
        return f
    }()

    static func today() -> String {
        dayFormatter.string(from: Date())
    }

    static func parseDay(_ s: String) -> Date? {
        dayFormatter.date(from: s)
    }

    static func formatDay(_ d: Date) -> String {
        dayFormatter.string(from: d)
    }

    static func addDays(_ days: Int, to dayString: String) -> String {
        guard let date = parseDay(dayString) else { return dayString }
        let calendar = Calendar.current
        guard let newDate = calendar.date(byAdding: .day, value: days, to: date) else { return dayString }
        return formatDay(newDate)
    }

    static func weekday(for dayString: String) -> String {
        guard let date = parseDay(dayString) else { return "" }
        return weekdayFormatter.string(from: date)
    }

    static func longLabel(for dayString: String) -> String {
        guard let date = parseDay(dayString) else { return dayString }
        return longDateFormatter.string(from: date)
    }

    static func shortLabel(for dayString: String) -> String {
        guard let date = parseDay(dayString) else { return dayString }
        return shortDateFormatter.string(from: date)
    }

    static func relativeLabel(for dayString: String) -> String? {
        let today = today()
        if dayString == today { return "Today" }
        let yesterday = addDays(-1, to: today)
        if dayString == yesterday { return "Yesterday" }
        let tomorrow = addDays(1, to: today)
        if dayString == tomorrow { return "Tomorrow" }
        return nil
    }
}
