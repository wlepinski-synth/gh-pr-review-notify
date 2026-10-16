import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let store: ReviewStore

    @AppStorage(Prefs.pollMinutesKey) private var pollMinutes = 1
    @AppStorage(Prefs.includeDraftsKey) private var includeDrafts = false
    @AppStorage(Prefs.excludeTitleKey) private var excludeTitle = Prefs.defaultExcludeTitle
    @AppStorage(Prefs.ghPathKey) private var ghPath = ""
    @StateObject private var loginItem = LoginItem()

    var body: some View {
        Form {
            Stepper("Check every \(pollMinutes) min", value: $pollMinutes, in: 1...60)
            Toggle("Include draft PRs", isOn: $includeDrafts)
            TextField("Skip titles matching (regex)", text: $excludeTitle)
            TextField("gh path", text: $ghPath, prompt: Text(GitHubClient.resolvedGHPath ?? "not found"))
            Toggle("Open at login", isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.set($0) }))
            if let error = loginItem.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .onDisappear {
            Task { await store.refresh() }
        }
    }
}

private final class LoginItem: ObservableObject {
    @Published private(set) var isEnabled = SMAppService.mainApp.status == .enabled
    @Published private(set) var error: String?

    func set(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled { try service.register() } else { try service.unregister() }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        isEnabled = service.status == .enabled
    }
}
