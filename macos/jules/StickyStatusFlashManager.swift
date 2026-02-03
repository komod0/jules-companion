import SwiftUI
import Combine
import OSLog

/// Represents a flash message state for the StickyStatusView
struct StickyFlashMessage: Equatable {
    let text: String
    let isSuccess: Bool // true = green background, false = normal display

    static let none = StickyFlashMessage(text: "", isSuccess: false)
}

/// Manages flash messages for StickyStatusView in the SessionView.
/// Each session can have its own flash state, tracked by session ID.
@MainActor
class StickyStatusFlashManager: ObservableObject {

    static let shared = StickyStatusFlashManager()
    private init() {}

    /// Special key for flash messages on the new session form (when session is nil)
    static let newSessionKey = "__new_session__"

    /// Current flash message per session ID
    @Published private(set) var flashMessages: [String: StickyFlashMessage] = [:]

    /// Track dismissal tasks per session
    private var dismissalTasks: [String: Task<Void, Never>] = [:]

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.jules", category: "StickyStatusFlashManager")

    /// Shows a flash message for a specific session's StickyStatusView
    /// - Parameters:
    ///   - sessionId: The session ID to show the flash for
    ///   - message: The text to display
    ///   - isSuccess: Whether this is a success state (green background)
    ///   - duration: How long to show before reverting to normal
    func show(sessionId: String, message: String, isSuccess: Bool = false, duration: TimeInterval = 2.0) {
        logger.info("Showing sticky flash for session \(sessionId): '\(message)', isSuccess=\(isSuccess)")

        // Cancel any existing dismissal task for this session
        dismissalTasks[sessionId]?.cancel()
        dismissalTasks[sessionId] = nil

        // Set the flash message
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            flashMessages[sessionId] = StickyFlashMessage(text: message, isSuccess: isSuccess)
        }

        // Schedule dismissal
        dismissalTasks[sessionId] = Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                try Task.checkCancellation()

                logger.info("Auto-dismissing sticky flash for session \(sessionId)")
                withAnimation(.easeOut(duration: 0.3)) {
                    self.flashMessages.removeValue(forKey: sessionId)
                }
                self.dismissalTasks.removeValue(forKey: sessionId)
            } catch is CancellationError {
                logger.info("Sticky flash dismissal cancelled for session \(sessionId)")
            } catch {
                logger.error("Error in sticky flash dismissal: \(error)")
                self.flashMessages.removeValue(forKey: sessionId)
                self.dismissalTasks.removeValue(forKey: sessionId)
            }
        }
    }

    /// Shows a sequence of flash messages (e.g., "Waiting..." then "Task Created")
    /// - Parameters:
    ///   - sessionId: The session ID
    ///   - initialMessage: First message to show (not success state)
    ///   - successMessage: Second message to show (success state)
    ///   - initialDuration: How long to show the initial message
    ///   - successDuration: How long to show the success message
    func showSequence(
        sessionId: String,
        initialMessage: String,
        successMessage: String,
        initialDuration: TimeInterval = 1.0,
        successDuration: TimeInterval = 2.0
    ) {
        logger.info("Starting flash sequence for session \(sessionId): '\(initialMessage)' -> '\(successMessage)'")

        // Cancel any existing task
        dismissalTasks[sessionId]?.cancel()
        dismissalTasks[sessionId] = nil

        // Show initial message
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            flashMessages[sessionId] = StickyFlashMessage(text: initialMessage, isSuccess: false)
        }

        // Schedule sequence
        dismissalTasks[sessionId] = Task {
            do {
                // Wait for initial duration
                try await Task.sleep(nanoseconds: UInt64(initialDuration * 1_000_000_000))
                try Task.checkCancellation()

                // Show success message
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    self.flashMessages[sessionId] = StickyFlashMessage(text: successMessage, isSuccess: true)
                }

                // Wait for success duration
                try await Task.sleep(nanoseconds: UInt64(successDuration * 1_000_000_000))
                try Task.checkCancellation()

                // Dismiss
                logger.info("Completing flash sequence for session \(sessionId)")
                withAnimation(.easeOut(duration: 0.3)) {
                    self.flashMessages.removeValue(forKey: sessionId)
                }
                self.dismissalTasks.removeValue(forKey: sessionId)
            } catch is CancellationError {
                logger.info("Flash sequence cancelled for session \(sessionId)")
            } catch {
                logger.error("Error in flash sequence: \(error)")
                self.flashMessages.removeValue(forKey: sessionId)
                self.dismissalTasks.removeValue(forKey: sessionId)
            }
        }
    }

    /// Clears any flash message for a session
    func clear(sessionId: String) {
        dismissalTasks[sessionId]?.cancel()
        dismissalTasks.removeValue(forKey: sessionId)
        withAnimation(.easeOut(duration: 0.3)) {
            flashMessages.removeValue(forKey: sessionId)
        }
    }

    /// Gets the current flash message for a session (if any)
    func flashMessage(for sessionId: String) -> StickyFlashMessage? {
        flashMessages[sessionId]
    }
}
