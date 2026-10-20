import Foundation
import Testing
@testable import Orra

/// The checks on model output: date and weekday pairs, and amounts that no source holds.
/// Today is pinned to Sunday 18 October 2026, the day the phase 0 labels hold for.
struct OutputChecksTests {
    static let calendar = Calendar(identifier: .gregorian)
    static let today = day(2026, 10, 18)

    static func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private func findings(_ text: String, sources: [String] = [], today: Date = OutputChecksTests.today) -> [OutputChecks.Finding] {
        OutputChecks.findings(in: text, sources: sources, today: today, calendar: Self.calendar)
    }

    // MARK: Dates and weekdays

    @Test(arguments: [
        "请在10月20日（周二）前确认。",
        "请在 10 月 22 日星期四之前回复。",
        "周一（10月19日）上午见。",
        "We can meet on Monday, 19 October.",
        "Tue 17 Nov works, or Tuesday, November 17, 2026.",
        "下周一（10月26日）交付。",
        "2026-10-23 (Fri) is the last day.",
        "十月十九日（周一）开会。",
    ])
    func rightPairsPass(_ text: String) {
        #expect(findings(text).isEmpty)
    }

    @Test(arguments: [
        ("请在10月20日（周一）前确认。", "10月20日（周一）"),
        ("We can meet on Tuesday, 19 October.", "Tuesday, 19 October"),
        ("Nov 17 (Wed) is the talk.", "Nov 17 (Wed)"),
        ("2026年10月23日 周四", "2026年10月23日 周四"),
        // Chinese numerals are read as digits
        ("十月十九日（周二）开会。", "10月19日（周二）"),
        // A date that does not exist
        ("11月31日（周二）", "11月31日（周二）"),
    ])
    func wrongPairsAreFlagged(_ text: String, _ flagged: String) {
        #expect(findings(text) == [.init(kind: .dateWeekdayMismatch, text: flagged)])
    }

    /// In a list each weekday pairs with the date next to it, never with the one after.
    @Test func eachWeekdayPairsWithItsOwnDate() {
        #expect(findings("周一 10月19日、周三 10月21日").isEmpty)
        #expect(findings("10月19日（周一）和10月21日（周三）").isEmpty)
        #expect(findings("10月19日（周一）和10月21日（周四）") == [.init(kind: .dateWeekdayMismatch, text: "10月21日（周四）")])
    }

    /// A weekday that stands apart from the date is not paired with it.
    @Test func looseWeekdaysAreNotChecked() {
        #expect(findings("10月19日开会，周五交稿。").isEmpty)
        #expect(findings("On 19 October we talk, and on Friday we ship.").isEmpty)
    }

    /// Sun before a capitalized word other than a month is a surname, not Sunday.
    @Test func sunBeforeANameIsNoWeekday() {
        #expect(findings("10月20日 Sun Wei 会来现场。").isEmpty)
        #expect(findings("Sun 18 Oct and Sun Oct 18 work.").isEmpty)
        #expect(findings("10月20日 Sun.") == [.init(kind: .dateWeekdayMismatch, text: "10月20日 Sun.")])
    }

    /// Dates with dots or slashes may put the day first, so their weekday is not checked,
    /// and they are no amounts.
    @Test func numericDatesAreNoAmounts() {
        #expect(findings("19.10.2026 (Monday) and 19/10/2026 (Tuesday) and 3.11.26.").isEmpty)
    }

    /// A date without a year falls in the year that puts it closest to today, so early
    /// January dates in late December belong to the next year.
    @Test func aDateWithoutAYearTakesTheClosestYear() {
        let lateDecember = Self.day(2026, 12, 28)
        #expect(findings("1月4日（周一）开工。", today: lateDecember).isEmpty)
        #expect(findings("1月4日（周日）开工。", today: lateDecember) == [.init(kind: .dateWeekdayMismatch, text: "1月4日（周日）")])
        #expect(findings("1月5日（周一）开工。", today: Self.day(2026, 1, 2)).isEmpty)
    }

    // MARK: Amounts

    static let sources = [
        "报价：单价 18.40 元，2,500 份，总价 46,000 元。定金 5.86万元。",
        "Contract summary: total CNY 64,000, paid in three parts.",
        "尾款五万八千六百元，于交货后付清。电话 138 0013 8000。",
    ]

    @Test(arguments: [
        "单价 18.4 元，共 2500 份，总价 ¥46,000。",
        "The total is 64,000 yuan.",
        "定金 58,600 元，尾款 5.86万。",
        "Call me at 13800138000.",
        "The deposit is 30% as agreed in 2026.",
    ])
    func amountsFromTheSourcesPass(_ text: String) {
        #expect(findings(text, sources: Self.sources + ["The deposit is 30%."]).isEmpty)
    }

    @Test func amountsInNoSourceAreFlagged() {
        #expect(findings("合计 ¥110,000，另加 1,200 元运费。", sources: Self.sources) == [
            .init(kind: .amountWithoutSource, text: "¥110,000"),
            .init(kind: .amountWithoutSource, text: "1,200 元"),
        ])
        #expect(findings("Each part is CNY 21,333.33.", sources: Self.sources) == [
            .init(kind: .amountWithoutSource, text: "CNY 21,333.33"),
        ])
        #expect(findings("尾款六万元。", sources: Self.sources) == [
            .init(kind: .amountWithoutSource, text: "6万元"),
        ])
    }

    /// Dates, times, years, small counts and codes are no amounts.
    @Test func otherNumbersAreNoAmounts() {
        let text = "On 2026-11-17 at 14:30, 3 people meet in room B12 for the 2027 calendar, booking BK-730415."
        #expect(findings(text).isEmpty)
    }

    @Test func eachFindingComesOnceInTheOrderOfTheText() {
        let text = "¥500 and 10月20日（周一）, then ¥500 again."
        #expect(findings(text) == [
            .init(kind: .amountWithoutSource, text: "¥500"),
            .init(kind: .dateWeekdayMismatch, text: "10月20日（周一）"),
        ])
    }

    // MARK: Numbers and codes

    @Test func numbersCarryOneValueForEveryForm() {
        let values = OutputChecks.numbers(in: "¥58,600、58600元、5.86万、58.6k、5.86万元、０．５").map(\.value)
        #expect(values == ["58600", "58600", "58600", "58600", "58600", "0.5"])
    }

    @Test func numbersTellAmountsAndScores() {
        let numbers = OutputChecks.numbers(in: "scores 4.4 and 8/10, 85分, 15分钟, 3 copies, 803 room, 2026 plan, 99%")
        #expect(numbers.map(\.value) == ["4.4", "8", "85", "15", "3", "803", "2026", "99"])
        #expect(numbers.map(\.isScore) == [true, true, true, false, false, false, false, false])
        #expect(numbers.map(\.isAmount) == [true, false, false, false, false, true, false, true])
    }

    @Test func accountNumbersInGroupsAreOneNumber() {
        #expect(OutputChecks.numbers(in: "账户 6217 0000 0000 0005").map(\.value) == ["6217000000000005"])
        #expect(OutputChecks.numbers(in: "phone 138-2019-2048 or 400-123-4567").map(\.value) == ["13820192048", "4001234567"])
        #expect(OutputChecks.numbers(in: "the 2026-2027 season").map(\.value) == ["2026", "2027"])
    }

    @Test func codesHoldLettersAndDigits() {
        let text = "Booking R4T8WX, flight LM627, hotel BK-730415, 航班LM628起飞, not 21st, 10am, 100kg, 1080p, v12, A4 or F1."
        #expect(OutputChecks.codes(in: text).map { String(text[$0]) } == ["R4T8WX", "LM627", "BK-730415", "LM628"])
        #expect(OutputChecks.codeValue("bk-730415") == "BK730415")
    }

    @Test func datesComeInEveryForm() {
        let text = "2026-10-19, 2026年10月20日, 10月21日, 22 October, 23rd of Oct 2026, November 17 and Oct. 19, 2026"
        let dates = OutputChecks.dates(in: text).map { [$0.year ?? 0, $0.month, $0.day] }
        #expect(dates == [[2026, 10, 19], [2026, 10, 20], [0, 10, 21], [0, 10, 22], [2026, 10, 23], [0, 11, 17], [2026, 10, 19]])
    }
}
