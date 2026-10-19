import AppKit
import OSLog

/// Reasons the user can't be looking at the app. Polling only runs while there are none.
struct AwayReasons {
    enum Reason: String {
        case screenLocked, systemAsleep, displayAsleep, sessionInactive
    }

    private(set) var active: Set<Reason> = []
    var isAway: Bool { !active.isEmpty }

    /// Returns true when this flips the overall away state.
    mutating func set(_ reason: Reason, _ on: Bool) -> Bool {
        let wasAway = isAway
        if on { active.insert(reason) } else { active.remove(reason) }
        return wasAway != isAway
    }
}

/// Watches lock, sleep, display and fast-user-switching events and reports when you leave or come back.
@MainActor
final class ActivityMonitor {
    static let shared = ActivityMonitor()

    private let log = Logger(subsystem: "io.github.wlepinski-synth.pr-reviews", category: "activity")
    private var reasons = AwayReasons()
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var onChange: ((_ isAway: Bool) -> Void)?

    func start(onChange: @escaping (_ isAway: Bool) -> Void) {
        guard observers.isEmpty else { return }
        self.onChange = onChange

        let workspace = NSWorkspace.shared.notificationCenter
        watch(workspace, NSWorkspace.willSleepNotification, .systemAsleep, on: true)
        watch(workspace, NSWorkspace.didWakeNotification, .systemAsleep, on: false)
        watch(workspace, NSWorkspace.screensDidSleepNotification, .displayAsleep, on: true)
        watch(workspace, NSWorkspace.screensDidWakeNotification, .displayAsleep, on: false)
        watch(workspace, NSWorkspace.sessionDidResignActiveNotification, .sessionInactive, on: true)
        watch(workspace, NSWorkspace.sessionDidBecomeActiveNotification, .sessionInactive, on: false)

        // macOS has no public API for lock state; these distributed notifications are what it posts.
        let distributed = DistributedNotificationCenter.default()
        watch(distributed, Notification.Name("com.apple.screenIsLocked"), .screenLocked, on: true)
        watch(distributed, Notification.Name("com.apple.screenIsUnlocked"), .screenLocked, on: false)
    }

    private func watch(_ center: NotificationCenter, _ name: Notification.Name, _ reason: AwayReasons.Reason, on: Bool) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update(reason, on) }
        }
        observers.append((center, token))
    }

    private func update(_ reason: AwayReasons.Reason, _ on: Bool) {
        guard reasons.set(reason, on) else { return }
        log.notice("\(self.reasons.isAway ? "Pausing" : "Resuming", privacy: .public) polling (\(reason.rawValue, privacy: .public) \(on ? "on" : "off", privacy: .public))")
        onChange?(reasons.isAway)
    }
}
