import Foundation
import ServiceManagement
import Combine

@MainActor
class LaunchAtLoginManager: ObservableObject {
    static let shared = LaunchAtLoginManager()

    @Published var isEnabled: Bool = false

    private init() {
        // Check current status on initialization
        updateStatus()
    }

    /// Update the current launch at login status
    func updateStatus() {
        if #available(macOS 13.0, *) {
            isEnabled = SMAppService.mainApp.status == .enabled
        } else {
            isEnabled = false
        }
    }

    /// Enable launch at login
    func enable() async throws {
        guard #available(macOS 13.0, *) else {
            throw LaunchAtLoginError.unsupportedOS
        }

        do {
            try SMAppService.mainApp.register()
            updateStatus()
        } catch {
            throw LaunchAtLoginError.registrationFailed(error)
        }
    }

    /// Disable launch at login
    func disable() async throws {
        guard #available(macOS 13.0, *) else {
            throw LaunchAtLoginError.unsupportedOS
        }

        do {
            try await SMAppService.mainApp.unregister()
            updateStatus()
        } catch {
            throw LaunchAtLoginError.unregistrationFailed(error)
        }
    }

    /// Toggle launch at login
    func toggle() async {
        do {
            if isEnabled {
                try await disable()
            } else {
                try await enable()
            }
        } catch {
            print("❌ Failed to toggle launch at login: \(error.localizedDescription)")
        }
    }
}

enum LaunchAtLoginError: LocalizedError {
    case unsupportedOS
    case registrationFailed(Error)
    case unregistrationFailed(Error)

    var errorDescription: String? {
        switch self {
        case .unsupportedOS:
            return "Launch at login requires macOS 13.0 or later"
        case .registrationFailed(let error):
            return "Failed to enable launch at login: \(error.localizedDescription)"
        case .unregistrationFailed(let error):
            return "Failed to disable launch at login: \(error.localizedDescription)"
        }
    }
}
