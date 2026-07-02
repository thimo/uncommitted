import AppKit
import Combine
import UserNotifications
import UncommittedCore

/// End-of-day reminder: one notification at the configured time when any
/// repo still has uncommitted or unpushed work. Nothing pending → silent.
/// The app is otherwise purely pull-based (the user has to look); this is
/// the single moment push genuinely earns its keep.
///
/// Lives in the app target, not Core: UserNotifications needs a real app
/// bundle, which the headless test runner doesn't have. The date math is
/// in Core (`DailyReminder`) where the tests can reach it.
final class ReminderScheduler: NSObject, UNUserNotificationCenterDelegate {
    private let configStore: ConfigStore
    private let repoStore: RepoStore
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

    init(configStore: ConfigStore, repoStore: RepoStore) {
        self.configStore = configStore
        self.repoStore = repoStore
        super.init()

        UNUserNotificationCenter.current().delegate = self

        configStore.$config
            .map { ($0.dailyReminderEnabled, $0.dailyReminderMinutes) }
            .removeDuplicates(by: ==)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled, _ in
                if enabled { self?.requestAuthorization() }
                self?.reschedule()
            }
            .store(in: &cancellables)

        // Timers don't tick during sleep; an overdue one fires right after
        // wake, which is the behaviour we want ("remind me at 17:30" on a
        // sleeping Mac becomes "remind me when I'm back"). Rescheduling on
        // wake just keeps the *next* fire date honest after long sleeps.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    deinit {
        timer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func handleWake() {
        reschedule()
    }

    /// Idempotent: macOS shows the permission prompt only on the first
    /// call, every later one resolves silently against the stored choice.
    /// Called when the toggle is (or loads as) enabled — that's the moment
    /// the prompt is expected instead of suspicious.
    private func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge]) { granted, _ in
            if !granted {
                DiagnosticsLog.shared.warning("reminder", "notification permission not granted — daily reminder stays silent")
            }
        }
    }

    private func reschedule() {
        timer?.invalidate()
        timer = nil
        guard configStore.config.dailyReminderEnabled,
              let fireDate = DailyReminder.nextFireDate(
                after: Date(),
                minutesOfDay: configStore.config.dailyReminderMinutes
              ) else { return }

        let t = Timer(fire: fireDate, interval: 0, repeats: false) { [weak self] _ in
            self?.fire()
        }
        // A minute of tolerance is fine for an end-of-day nudge and lets
        // the system coalesce wakeups.
        t.tolerance = 60
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func fire() {
        defer { reschedule() }
        guard configStore.config.dailyReminderEnabled else { return }

        let dirty = repoStore.repos.filter { !($0.status?.isClean ?? true) }
        guard !dirty.isEmpty else { return }

        let content = UNMutableNotificationContent()
        content.title = "Uncommitted work"
        content.body = DailyReminder.notificationBody(count: dirty.count, names: dirty.map(\.name))
        // No sound — it's a nudge, not an alarm.

        let request = UNNotificationRequest(
            identifier: "nl.defrog.uncommitted.daily-reminder",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                DiagnosticsLog.shared.warning("reminder", "failed to post daily reminder: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show the banner even if the app counts as foreground — an
    /// LSUIElement app is never visibly "in front", so suppressing would
    /// read as the notification silently not working.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }

    /// Clicking the notification opens the popup — the list of what's
    /// pending is exactly what the notification promised.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        DispatchQueue.main.async {
            AppDelegate.shared?.showPopupFromNotification()
            completionHandler()
        }
    }
}
