import SwiftUI
import AppKit

class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private var dataManager: DataManager

    init(dataManager: DataManager) {
        self.dataManager = dataManager
        super.init(window: nil)
        setupWindow()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupWindow() {
        let settingsView = SettingsWindowView()
            .environmentObject(dataManager)

        let hostingController = NSHostingController(rootView: settingsView)

        // Don't use sizingOptions - let the window control the size
        // This matches the working FeedbackView window pattern

        let window = NSWindow(contentViewController: hostingController)

        window.title = "Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]

        let contentSize = NSSize(
            width: AppConstants.SettingsWindow.width,
            height: AppConstants.SettingsWindow.height
        )
        window.setContentSize(contentSize)
        window.minSize = contentSize
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self

        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.post(name: .settingsWindowWillClose, object: nil)
    }
}

extension NSNotification.Name {
    static let settingsWindowWillClose = NSNotification.Name("settingsWindowWillClose")
}
