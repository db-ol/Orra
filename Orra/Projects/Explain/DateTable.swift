import Foundation

/// A small table of dates for the explanation prompt: today, and this week and next week by
/// weekday, so the model never works out what "next Monday" or 下周三 is on its own. Part of
/// code step 3 of phase 0, where relative dates and weekdays were 5 of the 32 wrong facts of
/// the 4B.
///
/// Weeks start on Monday, as in China and in ISO 8601, and the table says so. Dates are
/// written in full, 2026-10-19, so a week across a month or a year end stays clear.
nonisolated struct DateTable: Sendable, Equatable {
    nonisolated struct Day: Sendable, Equatable {
        var year: Int
        var month: Int
        var day: Int
        /// 1 for Monday to 7 for Sunday.
        var weekday: Int

        /// The date as 2026-10-19.
        var text: String {
            String(format: "%04d-%02d-%02d", year, month, day)
        }
    }

    let today: Day
    /// Monday to Sunday of the week that holds today.
    let thisWeek: [Day]
    /// Monday to Sunday of the week after.
    let nextWeek: [Day]

    /// The table for the day that holds `today` in `timeZone`, the user's time zone.
    init(today: Date, timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var noon = calendar.dateComponents([.year, .month, .day], from: today)
        noon.hour = 12
        let middayToday = calendar.date(from: noon) ?? today
        func day(_ offset: Int) -> Day {
            let date = calendar.date(byAdding: .day, value: offset, to: middayToday) ?? middayToday
            let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
            // Calendar counts 1 for Sunday to 7 for Saturday.
            let weekday = ((parts.weekday ?? 2) + 5) % 7 + 1
            return Day(year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0, weekday: weekday)
        }
        let current = day(0)
        let monday = 1 - current.weekday
        self.today = current
        thisWeek = (0..<7).map { day(monday + $0) }
        nextWeek = (7..<14).map { day(monday + $0) }
    }

    /// The table as lines for the prompt, in Chinese or in English.
    func text(_ language: ProjectsLanguage) -> String {
        func week(_ days: [Day], separator: String) -> String {
            days.map { Self.weekdayName($0.weekday, language) + " " + $0.text }.joined(separator: separator)
        }
        if language == .zh {
            return """
                日期表（每周从星期一开始）：
                今天：\(today.text) \(Self.weekdayName(today.weekday, .zh))
                本周：\(week(thisWeek, separator: "，"))
                下周：\(week(nextWeek, separator: "，"))
                """
        }
        return """
            Dates (weeks start on Monday):
            Today: \(Self.weekdayName(today.weekday, .en)) \(today.text)
            This week: \(week(thisWeek, separator: ", "))
            Next week: \(week(nextWeek, separator: ", "))
            """
    }

    /// The name of a weekday, 1 for Monday to 7 for Sunday: 星期一 or Monday.
    static func weekdayName(_ weekday: Int, _ language: ProjectsLanguage) -> String {
        let index = min(max(weekday, 1), 7) - 1
        if language == .zh {
            return ["星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日"][index]
        }
        return ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"][index]
    }
}
