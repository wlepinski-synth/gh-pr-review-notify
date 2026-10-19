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
            MenuBarLabel(store: store, myStore: myStore)
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
