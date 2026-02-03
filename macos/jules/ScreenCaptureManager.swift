//
//  ScreenCaptureManager.swift
//  jules
//
//  Interactive screen capture manager using native macOS screencapture
//

import AppKit
import Foundation
import CoreGraphics
import Combine

/// Manages interactive screen capture with region selection and permissions
/// Uses the native macOS screencapture tool for the familiar Cmd-Shift-4 experience
@MainActor
class ScreenCaptureManager: ObservableObject {
    static let shared = ScreenCaptureManager()

    /// Notification posted when a screenshot is captured successfully
    static let screenshotCapturedNotification = Notification.Name("ScreenCaptureManager.screenshotCaptured")

    /// Published property for screen capture permission status
    @Published private(set) var hasPermission: Bool = false

    /// Timer for periodic permission checks
    private var permissionCheckTimer: Timer?

    /// Track if we're waiting for permission to be granted
    @Published private(set) var isWaitingForPermission: Bool = false

    private init() {
        // Check initial permission status
        updatePermissionStatus()

        // Start observing app activation to refresh permission status
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updatePermissionStatus()
                // If we were waiting for permission and it's now granted, clear the waiting state
                if self?.hasPermission == true {
                    self?.isWaitingForPermission = false
                    self?.stopPermissionPolling()
                }
            }
        }
    }

    deinit {
        permissionCheckTimer?.invalidate()
    }

    /// Updates the permission status by checking with the system
    func updatePermissionStatus() {
        let newStatus = CGPreflightScreenCaptureAccess()
        if newStatus != hasPermission {
            hasPermission = newStatus
            if newStatus {
                isWaitingForPermission = false
                stopPermissionPolling()
            }
        }
    }

    /// Starts polling for permission changes (used when waiting for user to grant in System Settings)
    func startPermissionPolling() {
        guard permissionCheckTimer == nil else { return }
        isWaitingForPermission = true
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updatePermissionStatus()
            }
        }
    }

    /// Stops polling for permission changes
    func stopPermissionPolling() {
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = nil
    }

    /// Requests screen capture permission from the system
    /// Returns true if permission was granted (or was already granted)
    @discardableResult
    func requestPermission() -> Bool {
        // First check if already granted
        if CGPreflightScreenCaptureAccess() {
            hasPermission = true
            isWaitingForPermission = false
            return true
        }

        // Request permission - this shows the system dialog on first request
        // Note: CGRequestScreenCaptureAccess() returns false and shows dialog if not authorized,
        // or returns true if already authorized. After user grants in System Settings,
        // the app typically needs to restart for CGPreflightScreenCaptureAccess() to return true.
        let granted = CGRequestScreenCaptureAccess()

        if granted {
            hasPermission = true
            isWaitingForPermission = false
            return true
        }

        // Permission not yet granted - start polling and open System Settings
        isWaitingForPermission = true
        startPermissionPolling()
        openSystemSettings()
        return false
    }

    /// Opens System Settings to the Screen Recording privacy pane
    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Initiates an interactive screen region capture
    /// - Parameter completion: Called with the captured image, or nil if cancelled/failed
    func captureScreenRegion(completion: @escaping (NSImage?) -> Void) {
        // Always refresh permission status first
        updatePermissionStatus()

        // Check permission
        if !hasPermission {
            // Try requesting permission
            if !requestPermission() {
                // Permission not granted - requestPermission already handles
                // opening System Settings and starting polling
                completion(nil)
                return
            }
        }

        // Create a temporary file for the screenshot
        let tempDir = FileManager.default.temporaryDirectory
        let filename = "jules_screenshot_\(UUID().uuidString).png"
        let tempURL = tempDir.appendingPathComponent(filename)

        // Use screencapture with interactive mode (-i) for region selection
        // -x: no sound
        // -i: interactive mode (allows selection)
        // -r: no shadow on windows
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", "-r", tempURL.path]

        process.terminationHandler = { [tempURL] _ in
            DispatchQueue.main.async {
                // Check if file exists (user may have cancelled with Escape)
                guard FileManager.default.fileExists(atPath: tempURL.path) else {
                    completion(nil)
                    return
                }

                // Load the captured image
                guard let image = NSImage(contentsOf: tempURL) else {
                    // Clean up temp file
                    try? FileManager.default.removeItem(at: tempURL)
                    completion(nil)
                    return
                }

                // Clean up temp file
                try? FileManager.default.removeItem(at: tempURL)

                // Return the captured image
                completion(image)
            }
        }

        do {
            try process.run()
        } catch {
            print("[ScreenCaptureManager] Failed to start screencapture: \(error)")
            completion(nil)
        }
    }

    /// Initiates screen capture and posts a notification with the result
    /// This is useful for triggering from global hotkeys
    func captureAndNotify() {
        captureScreenRegion { image in
            guard let image = image else { return }

            NotificationCenter.default.post(
                name: Self.screenshotCapturedNotification,
                object: image
            )
        }
    }
}
