import Foundation
import Testing
@testable import Orra

struct DateTableTests {
    static let shanghai = TimeZone(identifier: "Asia/Shanghai")!

    private func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    private func days(_ days: [DateTable.Day]) -> [String] {
        days.map(\.text)
    }

    @Test func aSundayEndsItsWeek() {
        let table = DateTable(today: date("2026-10-18T10:00:00+08:00"), timeZone: Self.shanghai)
        #expect(table.today == DateTable.Day(year: 2026, month: 10, day: 18, weekday: 7))
        #expect(days(table.thisWeek) == ["2026-10-12", "2026-10-13", "2026-10-14", "2026-10-15", "2026-10-16", "2026-10-17", "2026-10-18"])
        #expect(days(table.nextWeek) == ["2026-10-19", "2026-10-20", "2026-10-21", "2026-10-22", "2026-10-23", "2026-10-24", "2026-10-25"])
        #expect(table.thisWeek.map(\.weekday) == Array(1...7))
    }

    @Test func weeksRunAcrossAMonthEnd() {
        let table = DateTable(today: date("2026-10-29T23:30:00+08:00"), timeZone: Self.shanghai)
        #expect(table.today.weekday == 4)
        #expect(days(table.thisWeek).last == "2026-11-01")
        #expect(days(table.nextWeek) == ["2026-11-02", "2026-11-03", "2026-11-04", "2026-11-05", "2026-11-06", "2026-11-07", "2026-11-08"])
    }

    @Test func weeksRunAcrossAYearEnd() {
        let table = DateTable(today: date("2026-12-31T09:00:00+08:00"), timeZone: Self.shanghai)
        #expect(days(table.thisWeek) == ["2026-12-28", "2026-12-29", "2026-12-30", "2026-12-31", "2027-01-01", "2027-01-02", "2027-01-03"])
        #expect(days(table.nextWeek).first == "2027-01-04")
    }

    @Test func todayIsTheDayInTheUsersTimeZone() {
        let instant = date("2026-10-18T20:00:00Z")
        #expect(DateTable(today: instant, timeZone: Self.shanghai).today.text == "2026-10-19")
        #expect(DateTable(today: instant, timeZone: Self.shanghai).today.weekday == 1)
        #expect(DateTable(today: instant, timeZone: TimeZone(identifier: "UTC")!).today.text == "2026-10-18")
        #expect(DateTable(today: instant, timeZone: TimeZone(identifier: "America/Los_Angeles")!).thisWeek.first?.text == "2026-10-12")
    }

    @Test func theTableReadsInChineseAndInEnglish() {
        let table = DateTable(today: date("2026-10-30T09:00:00+08:00"), timeZone: Self.shanghai)
        #expect(table.text(.zh) == """
            日期表（每周从星期一开始）：
            今天：2026-10-30 星期五
            本周：星期一 2026-10-26，星期二 2026-10-27，星期三 2026-10-28，星期四 2026-10-29，星期五 2026-10-30，星期六 2026-10-31，星期日 2026-11-01
            下周：星期一 2026-11-02，星期二 2026-11-03，星期三 2026-11-04，星期四 2026-11-05，星期五 2026-11-06，星期六 2026-11-07，星期日 2026-11-08
            """)
        #expect(table.text(.en) == """
            Dates (weeks start on Monday):
            Today: Friday 2026-10-30
            This week: Monday 2026-10-26, Tuesday 2026-10-27, Wednesday 2026-10-28, Thursday 2026-10-29, Friday 2026-10-30, Saturday 2026-10-31, Sunday 2026-11-01
            Next week: Monday 2026-11-02, Tuesday 2026-11-03, Wednesday 2026-11-04, Thursday 2026-11-05, Friday 2026-11-06, Saturday 2026-11-07, Sunday 2026-11-08
            """)
        #expect(table.text(.other) == table.text(.en))
    }

    @Test func weekdayNames() {
        #expect(DateTable.weekdayName(1, .zh) == "星期一")
        #expect(DateTable.weekdayName(7, .zh) == "星期日")
        #expect(DateTable.weekdayName(3, .en) == "Wednesday")
    }
}
