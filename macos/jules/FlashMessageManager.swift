import SwiftUI
import Combine
import OSLog // Use OSLog for better logging

/// Style options for flash messages
enum FlashMessageStyle {
    case standard  // Original rounded rectangle style
    case wave      // New wave animation style with fluid bottom border
}

@MainActor // Ensure UI updates happen on the main thread
class FlashMessageManager: ObservableObject {
    // --- Published Properties for UI Binding ---
    @Published var isShowing: Bool = false
    @Published var message: String = ""
    @Published var type: FlashMessageType = .success
    @Published var style: FlashMessageStyle = .wave
    @Published var showBoids: Bool = false
    @Published var waveConfiguration: WaveConfiguration = .default

    /// Callback when wash-away animation completes
    var onWashAwayComplete: (() -> Void)?

    // --- Singleton Access ---
    static let shared = FlashMessageManager()
    private init() {} // Private init for singleton

    // --- Internal State ---
    private var dismissalTask: Task<Void, Never>? // Task handle for auto-dismissal

    // Logger
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.yourapp", category: "FlashMessageManager")


    /// Shows a flash message.
    /// - Parameters:
    ///   - message: The text to display.
    ///   - type: The type of message (success, error, etc.), determines style.
    ///   - duration: How long the message should stay visible (in seconds). Set to 0 for no auto-dismiss.
    ///   - style: Visual style of the flash message (standard or wave).
    ///   - showBoids: Whether to show the boids animation background (wave style only).
    ///   - waveConfig: Configuration for wave animation (wave style only).
    func show(
        message: String,
        type: FlashMessageType = .success,
        duration: TimeInterval = 3.0,
        style: FlashMessageStyle = .wave,
        showBoids: Bool = false,
        waveConfig: WaveConfiguration = .default
    ) {
        logger.info("Showing flash message: type=\(String(describing: type)), style=\(String(describing: style)), message='\(message)', duration=\(duration)")

        // Ensure Metal resources are available for wave-style flash messages.
        // This is needed because Metal resources may have been released when in menubar-only mode.
        if style == .wave {
            SharedMetalResourcesManager.shared.prepareForUse()
        }

        // Cancel any previous dismissal task to prevent premature dismissal
        dismissalTask?.cancel()

        // Update properties (will trigger UI update)
        self.message = message
        self.type = type
        self.style = style
        self.showBoids = showBoids
        self.waveConfiguration = waveConfig

        // Ensure it becomes visible immediately
        // Use withAnimation for the *appearance* if the view uses .transition
        withAnimation(.spring()) { // Or .easeInOut etc.
             self.isShowing = true
        }


        // Schedule dismissal task (skip if duration is 0 for manual control)
        guard duration > 0 else { return }

        dismissalTask = Task {
            do {
                // Convert duration to nanoseconds for Task.sleep
                let nanoDuration = UInt64(duration * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanoDuration)

                // Check for cancellation before dismissing
                try Task.checkCancellation()

                // Dismiss with animation
                 logger.info("Auto-dismissing flash message.")
                 withAnimation(.easeOut(duration: 0.3)) { // Or .spring()
                      self.isShowing = false
                 }
                 self.onWashAwayComplete?()
                 self.dismissalTask = nil // Clear task handle

            } catch is CancellationError {
                // Task was cancelled (e.g., by a new message being shown)
                logger.info("Flash message dismissal cancelled.")
            } catch {
                 // Handle other potential errors from sleep (unlikely)
                 logger.error("Error during flash message sleep/dismissal: \(error)")
                 // Force dismiss without animation in case of error
                 self.isShowing = false
                 self.dismissalTask = nil
            }
        }
    }

    // Optional: Allow manual dismissal
    func hide() {
        logger.info("Manually hiding flash message.")
        dismissalTask?.cancel() // Cancel auto-dismiss task
        dismissalTask = nil
        withAnimation(.easeOut(duration: 0.3)) {
            self.isShowing = false
        }
    }
}
