import SwiftUI
import UserNotifications
import Carbon.HIToolbox

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var hotkeyRef: EventHotKeyRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        registerGlobalHotkey()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // MARK: - Global Hotkey (Cmd+Shift+C)

    private func registerGlobalHotkey() {
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(0x434C5553) // "CLUS"
        hotKeyID.id = 1

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        let handler: EventHandlerUPP = { _, event, _ -> OSStatus in
            NSApp.activate(ignoringOtherApps: true)
            // Post notification to open session browser
            NotificationCenter.default.post(name: .openSessionBrowser, object: nil)
            return noErr
        }

        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType, nil, nil)

        // Cmd+Shift+C: keyCode 8 = C
        RegisterEventHotKey(UInt32(kVK_ANSI_C), UInt32(cmdKey | shiftKey), hotKeyID, GetApplicationEventTarget(), 0, &hotkeyRef)
    }
}

extension Notification.Name {
    static let openSessionBrowser = Notification.Name("openSessionBrowser")
}

@main
struct ClaudeUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var service = UsageDataService()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(service: service, openBrowser: { openBrowser() })
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "brain")
                if let limits = service.rateLimits {
                    let pct = limits.fiveHour.effectivePercentage
                    Text("\(pct)%")
                        .monospacedDigit()
                        .font(.caption)
                        .foregroundStyle(menuBarColor(pct))
                }
            }
        }
        .menuBarExtraStyle(.window)

        Window("Claude Sessions", id: "session-browser") {
            SessionBrowserView()
                .onReceive(NotificationCenter.default.publisher(for: .openSessionBrowser)) { _ in
                    // Window is already open via the notification
                }
        }
        .defaultSize(width: 1100, height: 700)
        .keyboardShortcut("o", modifiers: [.command, .shift])
    }

    private func openBrowser() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "session-browser")
    }

    private func menuBarColor(_ pct: Int) -> Color {
        if pct >= 80 { return .red }
        if pct >= 60 { return .orange }
        return .primary
    }
}
