import SwiftUI

@main
struct ClaudeUsageApp: App {
    @StateObject private var service = UsageDataService()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(service: service)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "brain")
                if let limits = service.rateLimits {
                    Text("\(limits.fiveHour.usedPercentage)%")
                        .monospacedDigit()
                        .font(.caption)
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}
