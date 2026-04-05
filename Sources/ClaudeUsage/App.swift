import SwiftUI
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

@main
struct ClaudeUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var service = UsageDataService()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(service: service, openBrowser: {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "session-browser")
            })
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "brain")
                if let limits = service.rateLimits {
                    Text("\(limits.fiveHour.effectivePercentage)%")
                        .monospacedDigit()
                        .font(.caption)
                }
            }
        }
        .menuBarExtraStyle(.window)

        Window("Claude Sessions", id: "session-browser") {
            SessionBrowserView()
        }
        .defaultSize(width: 1100, height: 700)
    }
}
