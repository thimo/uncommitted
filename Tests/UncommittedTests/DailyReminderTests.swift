import Foundation
import UncommittedCore

enum DailyReminderTests {
    /// Fixed UTC calendar so results don't depend on the machine's timezone.
    private static var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// 2026-06-15 12:00:00 UTC.
    private static let noonJune15 = Date(timeIntervalSince1970: 1_781_524_800)

    static func register() {
        // MARK: - nextFireDate

        test("DailyReminder/timeStillAhead_firesToday") {
            let fire = try requireNotNil(DailyReminder.nextFireDate(
                after: noonJune15, minutesOfDay: 17 * 60 + 30, calendar: utcCalendar))
            let parts = utcCalendar.dateComponents([.day, .hour, .minute], from: fire)
            try expectEqual(parts.day, 15)
            try expectEqual(parts.hour, 17)
            try expectEqual(parts.minute, 30)
        }

        test("DailyReminder/timeAlreadyPassed_firesTomorrow") {
            let fire = try requireNotNil(DailyReminder.nextFireDate(
                after: noonJune15, minutesOfDay: 9 * 60, calendar: utcCalendar))
            let parts = utcCalendar.dateComponents([.day, .hour, .minute], from: fire)
            try expectEqual(parts.day, 16)
            try expectEqual(parts.hour, 9)
            try expectEqual(parts.minute, 0)
        }

        test("DailyReminder/exactlyAtFireTime_schedulesNextDay") {
            // now == 12:00:00 sharp, reminder at 12:00 → strictly after,
            // so tomorrow. Prevents a fire → reschedule loop from firing
            // twice in the same minute.
            let fire = try requireNotNil(DailyReminder.nextFireDate(
                after: noonJune15, minutesOfDay: 12 * 60, calendar: utcCalendar))
            let parts = utcCalendar.dateComponents([.day, .hour], from: fire)
            try expectEqual(parts.day, 16)
            try expectEqual(parts.hour, 12)
        }

        test("DailyReminder/outOfRangeMinutes_returnsNil") {
            try expectNil(DailyReminder.nextFireDate(after: noonJune15, minutesOfDay: -1, calendar: utcCalendar))
            try expectNil(DailyReminder.nextFireDate(after: noonJune15, minutesOfDay: 24 * 60, calendar: utcCalendar))
        }

        // MARK: - notification body

        test("DailyReminder/body_singleRepo_namesIt") {
            let body = DailyReminder.notificationBody(count: 1, names: ["uncommitted"])
            try expectEqual(body, "uncommitted has uncommitted or unpushed work.")
        }

        test("DailyReminder/body_fewRepos_listsAll") {
            let body = DailyReminder.notificationBody(count: 2, names: ["alpha", "beta"])
            try expectEqual(body, "2 repositories have uncommitted or unpushed work: alpha, beta.")
        }

        test("DailyReminder/body_manyRepos_capsAtThreeNames") {
            let body = DailyReminder.notificationBody(count: 5, names: ["a", "b", "c", "d", "e"])
            try expectEqual(body, "5 repositories have uncommitted or unpushed work: a, b, c +2 more.")
        }

        // MARK: - config

        test("Config/dailyReminder_defaultsOffAt1730") {
            let config = Config()
            try expect(!config.dailyReminderEnabled)
            try expectEqual(config.dailyReminderMinutes, 17 * 60 + 30)
        }

        test("Config/dailyReminder_roundTrips") {
            var config = Config()
            config.dailyReminderEnabled = true
            config.dailyReminderMinutes = 9 * 60 + 15
            let data = try JSONEncoder().encode(config)
            let decoded = try JSONDecoder().decode(Config.self, from: data)
            try expect(decoded.dailyReminderEnabled)
            try expectEqual(decoded.dailyReminderMinutes, 9 * 60 + 15)
        }

        test("Config/legacyConfig_withoutReminderKeys_decodesAsDefaults") {
            let decoded = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
            try expect(!decoded.dailyReminderEnabled)
            try expectEqual(decoded.dailyReminderMinutes, 17 * 60 + 30)
        }
    }
}
