import AppKit
import UserNotifications

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private static let summaryThreshold = 5
    private let center = UNUserNotificationCenter.current()
    private let stateURL: URL
    private let myPRsStateURL: URL

    override init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PRReviews", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        stateURL = dir.appendingPathComponent("notified.json")
        myPRsStateURL = dir.appendingPathComponent("myprs.json")
        super.init()
    }

    func setUp() {
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Banners for PRs that are new or changed since the last run.
    func process(_ prs: [PullRequest]) {
        let current = Dictionary(
            prs.map { ($0.url.absoluteString, Self.stamp($0.updatedAt)) },
            uniquingKeysWith: { first, _ in first }
        )
        defer { save(current) }

        // First run only records a baseline, so existing PRs don't all fire at once.
        guard let previous = load() else { return }

        let fresh = prs.filter { previous[$0.url.absoluteString] != Self.stamp($0.updatedAt) }
        if fresh.count > Self.summaryThreshold {
            post(
                id: "summary",
                title: "PR reviews requested",
                subtitle: "",
                body: "\(fresh.count) PRs awaiting your review",
                url: ReviewTab.direct.queueURL
            )
        } else {
            for pr in fresh {
                var subtitle = pr.shortRepo
                if !pr.author.isEmpty { subtitle += " — @\(pr.author)" }
                subtitle += " · \(Age.short(since: pr.createdAt))"
                post(id: pr.url.absoluteString, title: "PR review requested", subtitle: subtitle, body: pr.title, url: pr.url)
            }
        }
    }

    /// Banners when one of your PRs changes status since the last run.
    func processMyPRs(_ prs: [MyPullRequest], notify: Bool) {
        let current = Dictionary(
            prs.map { ($0.url.absoluteString, $0.snapshot) },
            uniquingKeysWith: { first, _ in first }
        )
        defer { save(current, to: myPRsStateURL) }

        guard notify, let previous: [String: PRSnapshot] = load(from: myPRsStateURL) else { return }

        for pr in prs {
            guard let old = previous[pr.url.absoluteString],
                  let transition = PRStatus.transition(old: old, new: pr.snapshot) else { continue }
            post(
                id: "\(pr.url.absoluteString)#\(transition.rawValue)",
                title: transition.title,
                subtitle: "\(pr.shortRepo)#\(pr.number)",
                body: pr.title,
                url: pr.url
            )
        }
    }

    func storedMyPRSnapshots() -> [String: PRSnapshot] {
        load(from: myPRsStateURL) ?? [:]
    }

    private func post(id: String, title: String, subtitle: String, body: String, url: URL) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.sound = .default
        content.userInfo = ["url": url.absoluteString]
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    private func load() -> [String: String]? {
        load(from: stateURL)
    }

    private func save(_ state: [String: String]) {
        save(state, to: stateURL)
    }

    private func load<T: Decodable>(from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func save<T: Encodable>(_ state: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func stamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let link = response.notification.request.content.userInfo["url"] as? String, let url = URL(string: link) {
            NSWorkspace.shared.open(url)
        }
        completionHandler()
    }
}

enum Age {
    static func short(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }
}
