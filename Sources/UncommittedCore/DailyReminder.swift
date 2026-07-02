import Foundation

/// Pure date math for the end-of-day reminder, kept in Core so the test
/// runner can exercise it. The actual scheduling and notification posting
/// live in the app target (`ReminderScheduler`) — UserNotifications needs
/// a real app bundle and can't run under the headless test binary.
public enum DailyReminder {
    /// The next moment the reminder should fire: the first occurrence of
    /// `minutesOfDay` (minutes since local midnight) strictly after `now`.
    /// Today if the time hasn't passed yet, tomorrow otherwise. Returns
    /// nil only for out-of-range input (minutes outside 0..<1440).
    public static func nextFireDate(
        after now: Date,
        minutesOfDay: Int,
        calendar: Calendar = .current
    ) -> Date? {
        guard (0..<24 * 60).contains(minutesOfDay) else { return nil }
        var components = DateComponents()
        components.hour = minutesOfDay / 60
        components.minute = minutesOfDay % 60
        components.second = 0
        return calendar.nextDate(
            after: now,
            matching: components,
            matchingPolicy: .nextTime
        )
    }

    /// Notification body for `count` repos with pending work, naming the
    /// first few. Callers guarantee `count >= 1` and `names` non-empty.
    public static func notificationBody(count: Int, names: [String]) -> String {
        let shown = names.prefix(3).joined(separator: ", ")
        let more = count > 3 ? " +\(count - 3) more" : ""
        if count == 1 {
            return "\(shown) has uncommitted or unpushed work."
        }
        return "\(count) repositories have uncommitted or unpushed work: \(shown)\(more)."
    }
}
