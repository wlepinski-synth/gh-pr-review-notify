import AppKit
import SwiftUI

@main
struct PRReviewsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let store = ReviewStore.shared
    private let myStore = MyPRsStore.shared

    var body: some Scene {
        MenuBarExtra {
            ReviewsView(store: store, myStore: myStore)
        } label: {
            // Values are read here so the scene body observes them; the
            // menu bar label view doesn't reliably re-render on its own.
            MenuBarLabel(
                direct: store.direct.count,
                team: store.team.count,
                mine: myStore.openCount,
                hasError: store.errorMessage != nil || myStore.errorMessage != nil
            )
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: store, myStore: myStore)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Notifier.shared.setUp()
        ReviewStore.shared.start()
        MyPRsStore.shared.start()
        ActivityMonitor.shared.start { isAway in
            if isAway {
                ReviewStore.shared.pause()
                MyPRsStore.shared.pause()
            } else {
                ReviewStore.shared.resume()
                MyPRsStore.shared.resume()
            }
        }
    }
}
