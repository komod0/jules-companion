import SwiftUI
import AppKit
import Combine

/// Notification names for voice input events
extension Notification.Name {
    static let showVoiceInputPanel = Notification.Name("showVoiceInputPanel")
    static let hideVoiceInputPanel = Notification.Name("hideVoiceInputPanel")
    static let voiceInputRecordingStateChanged = Notification.Name("voiceInputRecordingStateChanged")
    static let closeVoiceInputPanel = Notification.Name("closeVoiceInputPanel")
}

/// Custom NSPanel that handles ESC key to close voice input
@available(macOS 26.0, *)
class VoiceInputPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        // Handle ESC key to close the panel
        NotificationCenter.default.post(name: .closeVoiceInputPanel, object: nil)
    }

    override func keyDown(with event: NSEvent) {
        // ESC key code is 53
        if event.keyCode == 53 {
            cancelOperation(nil)
        } else {
            super.keyDown(with: event)
        }
    }
}

/// Controller for the voice input floating panel
@available(macOS 26.0, *)
@MainActor
final class VoiceInputPanelController {

    // MARK: - Singleton

    static let shared = VoiceInputPanelController()

    // MARK: - Properties

    /// The floating panel
    private var panel: NSPanel?

    /// Hosting controller for SwiftUI content
    private var hostingController: NSHostingController<AnyView>?

    /// Reference to data manager (set from AppDelegate)
    weak var dataManager: DataManager?

    /// Reference to status bar button for positioning (set from AppDelegate)
    weak var statusBarButton: NSStatusBarButton?

    /// Whether the panel is currently visible
    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    /// Publisher for recording state changes
    let recordingStatePublisher = PassthroughSubject<Bool, Never>()

    // MARK: - Private Properties

    private var cancellables = Set<AnyCancellable>()

    /// Global click monitor for detecting clicks outside panel
    private var globalClickMonitor: Any?

    /// Whether we've set up the speech manager subscription (lazy initialization)
    private var hasSpeechManagerSubscription = false

    /// Notification observers for explicit cleanup (prevents observer accumulation)
    private var resignKeyObserver: NSObjectProtocol?
    private var willCloseObserver: NSObjectProtocol?

    // MARK: - Initialization

    private init() {
        setupNotificationSubscriptions()
    }

    // MARK: - Panel Management

    /// Show the voice input panel
    func show() {
        guard let dataManager = dataManager else {
            print("[VoiceInputPanelController] DataManager not set")
            return
        }

        // Set up speech manager subscription lazily on first use
        // This avoids loading the Speech framework at app startup
        setupSpeechManagerSubscriptionIfNeeded()

        // Create panel if needed
        if panel == nil {
            createPanel(dataManager: dataManager)
        }

        guard let panel = panel else { return }

        // Position at top below menubar (centered horizontally)
        positionPanel(panel)

        // Show panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Add global click monitor to detect clicks outside the panel
        if globalClickMonitor == nil {
            globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self = self, let panel = self.panel, panel.isVisible else { return }

                // Check if click is outside the panel
                let clickLocation = event.locationInWindow
                let panelFrame = panel.frame

                // For global events, locationInWindow is in screen coordinates
                if !panelFrame.contains(clickLocation) {
                    DispatchQueue.main.async {
                        self.hide()
                    }
                }
            }
        }

        // Notify that recording is starting
        recordingStatePublisher.send(true)
        NotificationCenter.default.post(name: .voiceInputRecordingStateChanged, object: true)
    }

    /// Hide the voice input panel
    func hide() {
        // Perform cleanup first to ensure all resources are released
        performCleanup()

        // Destroy panel to ensure fresh state on next open
        // This ensures onAppear is called each time
        panel?.orderOut(nil)
        panel = nil
        hostingController = nil
    }

    /// Perform cleanup of audio resources and reset menu icon
    /// Called when panel is hidden or closed by any means
    private func performCleanup() {
        // Force reset speech manager to ensure clean state even if audio system had errors
        SpeechTranscriptionManager.shared.forceReset()

        // Remove global click monitor
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }

        // Explicitly remove notification observers to prevent accumulation
        if let observer = resignKeyObserver {
            NotificationCenter.default.removeObserver(observer)
            resignKeyObserver = nil
        }
        if let observer = willCloseObserver {
            NotificationCenter.default.removeObserver(observer)
            willCloseObserver = nil
        }

        // Release NLEmbedding from SourceMatcher to free memory when voice input is not in use
        // The embedding will be lazy-loaded again if voice input is used later
        SourceMatcher.shared.releaseEmbedding()

        // Always notify that recording/transcription has stopped
        // This ensures the menu icon is reset to default state
        recordingStatePublisher.send(false)
        NotificationCenter.default.post(name: .voiceInputRecordingStateChanged, object: false)
    }

    /// Toggle the voice input panel visibility
    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    // MARK: - Private Methods

    /// Set up notification subscriptions (lightweight, no framework loading)
    private func setupNotificationSubscriptions() {
        // Listen for show/hide notifications
        NotificationCenter.default.publisher(for: .showVoiceInputPanel)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.show()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .hideVoiceInputPanel)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.hide()
            }
            .store(in: &cancellables)

        // Listen for close notification (from ESC key)
        NotificationCenter.default.publisher(for: .closeVoiceInputPanel)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.hide()
            }
            .store(in: &cancellables)
    }

    /// Set up speech manager subscription lazily (loads Speech framework)
    /// Only called when voice input is first used
    private func setupSpeechManagerSubscriptionIfNeeded() {
        guard !hasSpeechManagerSubscription else { return }
        hasSpeechManagerSubscription = true

        // Listen for recording state from speech manager
        // This is deferred until first use to avoid loading Speech framework at startup
        SpeechTranscriptionManager.shared.$isRecording
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording in
                self?.recordingStatePublisher.send(isRecording)
                NotificationCenter.default.post(name: .voiceInputRecordingStateChanged, object: isRecording)
            }
            .store(in: &cancellables)
    }

    private func createPanel(dataManager: DataManager) {
        // Create panel using custom VoiceInputPanel that handles ESC key
        let panel = VoiceInputPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 160),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // Shadow handled by SwiftUI
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false

        // Create SwiftUI view
        let voiceInputView = VoiceInputView(
            onClose: { [weak self] in
                self?.hide()
            },
            onPost: { [weak self, weak dataManager] prompt, source in
                self?.handlePost(prompt: prompt, source: source, dataManager: dataManager)
            }
        )
        .environmentObject(dataManager)

        let hostingController = NSHostingController(rootView: AnyView(voiceInputView))
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false

        // Configure hosting controller
        if #available(macOS 13.3, *) {
            hostingController.safeAreaRegions = []
        }

        // Enable automatic sizing based on SwiftUI content
        if #available(macOS 13.0, *) {
            hostingController.sizingOptions = [.preferredContentSize, .intrinsicContentSize]
        }

        hostingController.view.wantsLayer = true
        hostingController.view.layer?.masksToBounds = false

        panel.contentView?.addSubview(hostingController.view)

        if let contentView = panel.contentView {
            contentView.wantsLayer = true
            contentView.layer?.masksToBounds = false

            NSLayoutConstraint.activate([
                hostingController.view.topAnchor.constraint(equalTo: contentView.topAnchor),
                hostingController.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                hostingController.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                hostingController.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
            ])
        }

        self.panel = panel
        self.hostingController = hostingController

        // Close panel when it loses key status (e.g., clicking outside on macOS native elements)
        // Store reference for explicit cleanup to prevent observer accumulation
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            self?.hide()
        }

        // Also observe willClose to ensure cleanup happens even if panel is closed by the system
        // Store reference for explicit cleanup to prevent observer accumulation
        willCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            self?.performCleanup()
        }
    }

    private func positionPanel(_ panel: NSPanel) {
        // Position panel under the menu bar icon, like MenuView
        if let button = statusBarButton,
           let buttonWindow = button.window,
           let screen = buttonWindow.screen ?? NSScreen.main {
            let buttonFrameInScreen = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            let panelSize = panel.frame.size

            // Position panel so its top aligns with bottom of menu bar (top of visible screen area)
            // and left edge aligns with button's left edge
            let panelX = buttonFrameInScreen.minX
            let panelY = screen.visibleFrame.maxY - panelSize.height

            panel.setFrameOrigin(NSPoint(x: panelX, y: panelY))
        } else {
            // Fallback to centered positioning if button reference not available
            guard let screen = NSScreen.main else { return }

            let screenFrame = screen.visibleFrame
            let panelSize = panel.frame.size

            let x = screenFrame.origin.x + (screenFrame.width - panelSize.width) / 2
            let y = screenFrame.maxY - panelSize.height

            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    private func handlePost(prompt: String, source: Source?, dataManager: DataManager?) {
        guard let dataManager = dataManager else { return }

        // If we matched a source, select it
        if let source = source {
            dataManager.selectedSourceId = source.id
        }

        // Set prompt and create session
        dataManager.promptText = prompt

        // Close panel first
        hide()

        // Create session after a brief delay to ensure UI is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            dataManager.createSession()
        }
    }

    // MARK: - Cleanup

    deinit {
        // Remove global click monitor to prevent resource leak
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
        }

        // Remove notification observers to prevent leaks
        if let observer = resignKeyObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = willCloseObserver {
            NotificationCenter.default.removeObserver(observer)
        }

        // Cancel all Combine subscriptions
        cancellables.forEach { $0.cancel() }

        // Note: releaseEmbedding() is called in performCleanup() when the panel is hidden
        // We cannot call it here because deinit cannot be isolated to the main actor,
        // and SourceMatcher.shared.releaseEmbedding() requires main actor isolation.
        // Since this is a singleton, deinit will likely never be called anyway.
    }
}
