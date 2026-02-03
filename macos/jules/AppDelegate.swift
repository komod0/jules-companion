import SwiftUI
import AppKit
import Combine
import UserNotifications
import HotKey
import Sparkle
import FirebaseCore
import FirebaseAppCheck

// MARK: - Configuration
// Set these values to enable optional features.
// The app works without Firebase/Gemini - activity descriptions will use the original API values.

/// Set to true to enable Firebase and Gemini AI features (activity description generation).
/// Requires a valid GoogleService-Info.plist with your Firebase project configuration.
let ENABLE_FIREBASE = false

/// Your Sparkle appcast URL for automatic updates.
/// Set this to your own URL if you want to distribute updates, or leave empty to disable.
let SPARKLE_APPCAST_URL = ""

/// Custom NSPanel subclass that can become key and accept first responder
/// Required for text input focus in borderless panels
class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        // Handle ESC key to close the panel
        NotificationCenter.default.post(name: .closeCenteredMenu, object: nil)
    }

    override func keyDown(with event: NSEvent) {
        // ESC key code is 53
        if event.keyCode == 53 {
            cancelOperation(nil)
        } else {
            super.keyDown(with: event)
        }
    }

    /// Prevent Tab key from cycling through key views
    /// This allows Tab to reach the text view for autocomplete
    override func selectNextKeyView(_ sender: Any?) {
        #if DEBUG
        print("[KeyablePanel] selectNextKeyView called - blocking to allow Tab for autocomplete")
        #endif
        // Don't call super - this prevents Tab from cycling views
        // The Tab key will instead be handled by the first responder (SimpleTextView)
    }

    /// Prevent Shift+Tab from cycling through key views
    override func selectPreviousKeyView(_ sender: Any?) {
        #if DEBUG
        print("[KeyablePanel] selectPreviousKeyView called - blocking")
        #endif
        // Don't call super
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSMenuItemValidation {

    private var hotKey: HotKey?
    private var screenshotHotKey: HotKey?
    private var voiceInputHotKey: HotKey?
    private var statusItem: NSStatusItem!
    var dataManager = DataManager()
    private var cancellables = Set<AnyCancellable>()
    private var cachedPopoverContentSize: NSSize!
    private var lastStatusIconState: SessionState?
    private var lastUnviewedCompleted: Bool = false
    private var sessionController: SessionController?
    private var settingsWindowController: SettingsWindowController?
    private var feedbackWindowController: NSWindowController?

    // Centered menu panel
    private var centeredMenuPanel: NSPanel?
    private var centeredMenuHostingController: NSHostingController<AnyView>?
    private var isCenteredMenuIntentionallyOpen: Bool = false
    private var centeredMenuClickMonitor: Any?

    // Menu bar panel (replaces popover for menu bar position)
    private var menuBarPanel: NSPanel?
    private var menuBarPanelHostingController: NSHostingController<AnyView>?
    private var isMenuBarPanelOpen: Bool = false
    private var menuBarPanelClickMonitor: Any?

    // Sparkle updater controller
    private var updaterController: SPUStandardUpdaterController!
    
    // --- Animation Properties ---
    private var startingAnimationTimer: Timer?
    private var runningAnimationTimer: Timer?
    private var currentStartingFrameIndex: Int = 0
    private var currentRunningFrameIndex: Int = 0

    private let startingImageNames = [
          "jules-menu-load-1", "jules-menu-load-2", "jules-menu-load-3",
          "jules-menu-load-4", "jules-menu-load-5", "jules-menu-load-4",
          "jules-menu-load-3", "jules-menu-load-2", "jules-menu-load-1"
      ]
      private let runningImageNames = [
          "jules-menu-running-1", "jules-menu-running-2", "jules-menu-running-3",
          "jules-menu-running-4", "jules-menu-running-5", "jules-menu-running-6",
          "jules-menu-running-6", "jules-menu-running-6",  "jules-menu-running-6",
          "jules-menu-running-6",  "jules-menu-running-6",  "jules-menu-running-6"
      ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Pre-warm databases on background thread before any data access
        // This prevents blocking the main thread when DataManager first accesses the database
        AppDatabase.preWarm()
        DiffDatabase.preWarm()

        // Log database diagnostics and perform maintenance on startup (async to not block launch)
        // Uses .userInitiated priority to match database pool QoS and avoid priority inversion
        // warnings when GRDB's internal dispatch queue synchronization interacts with other threads
        Task.detached(priority: .userInitiated) {
            // Small delay to ensure databases are initialized
            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
            AppDatabase.logDiagnostics()
            DiffDatabase.logDiagnostics()

            // Auto-vacuum if database has significant bloat (>3x expected size)
            // This reclaims wasted space from deleted/updated records
            AppDatabase.vacuumIfNeeded(threshold: 3.0)
        }

        ScrollProfiler.shared.enabled = false
        LoadingProfiler.shared.isEnabled = false
        LoadingProfiler.shared.printLiveUpdates = false // See output as it happens
        LoadingProfiler.memoryProfilingEnabled = false // Enable to see [Memory], [MemoryFix], [HeavyData], [DiffCache] logs
        LoadingProfiler.memoryLogFilter = .flaggedOnly

        ScrollDiagnostics.shared.isEnabled = false
        ScrollDiagnostics.shared.verboseMode = false

        // Initialize Firebase if enabled
        if ENABLE_FIREBASE {
            #if DEBUG
            let providerFactory = AppCheckDebugProviderFactory()
            print("🛡️ Firebase App Check: Using Debug Provider")
            #else
            let providerFactory = DeviceCheckProviderFactory()
            #endif

            AppCheck.setAppCheckProviderFactory(providerFactory)
            FirebaseApp.configure()
            #if DEBUG
            print("✅ Firebase initialized")
            #endif
        }

        // Initialize launch at login manager to update its status
        Task { @MainActor in
            LaunchAtLoginManager.shared.updateStatus()
        }

        // Initialize Sparkle updater
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

        // Register global hotkeys from user preferences
        registerHotkeys()

        // Re-register hotkeys when user changes shortcuts in settings
        KeyboardShortcutsManager.shared.shortcutsChanged
            .sink { [weak self] in
                self?.registerHotkeys()
            }
            .store(in: &cancellables)

        // Listen for screenshot captured notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenshotCaptured(_:)),
            name: ScreenCaptureManager.screenshotCapturedNotification,
            object: nil
        )

        // Setup application main menu with View menu for font size controls
        setupMainMenu()

        // Set initial popover size based on saved preference
        let isExpanded = dataManager.isPopoverExpanded
        let width = isExpanded ? AppConstants.Popover.expandedWidth : AppConstants.Popover.minimizedWidth
        let height = isExpanded ? AppConstants.Popover.expandedHeight : AppConstants.Popover.minimizedHeight
        cachedPopoverContentSize = NSSize(width: width, height: height)

        // Setup notification center and request authorization via NotificationManager
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        Task { @MainActor in
            NotificationManager.shared.requestAuthorization()
        }

        // Listen for new notifications from DataManager
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleNewNotifications(_:)),
            name: .didReceiveNewApiNotifications,
            object: dataManager
        )

        // Listen for check for updates notification from SettingsView
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCheckForUpdates),
            name: .checkForUpdates,
            object: nil
        )

        // Listen for open settings notification
        NotificationCenter.default.addObserver(forName: .openSettings, object: nil, queue: .main) { [weak self] _ in
            // Must use Task to properly dispatch to MainActor since handleOpenSettings is @MainActor
            Task { @MainActor in
                self?.handleOpenSettings()
            }
        }

        // Listen for settings window close notification
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsWindowWillClose),
            name: .settingsWindowWillClose,
            object: nil
        )

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            updateStatusIcon(state: .unspecified) // Initial state
            button.action = #selector(handleStatusBarClick(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Initialize voice input panel controller (macOS 26.0+ only)
        if #available(macOS 26.0, *) {
            VoiceInputPanelController.shared.dataManager = dataManager
            VoiceInputPanelController.shared.statusBarButton = statusItem.button
        }

        // Observe most recent session's state for the icon and dock badge
        dataManager.$sessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                if let firstSession = sessions.first {
                    self?.updateStatusIcon(state: firstSession.state, isUnviewedCompleted: firstSession.isUnviewedCompleted)
                } else {
                    self?.updateStatusIcon(state: .unspecified, isUnviewedCompleted: false)
                }

                // Update dock badge with count of unviewed completed sessions
                let unviewedCount = sessions.filter { $0.isUnviewedCompleted }.count
                self?.updateDockBadge(count: unviewedCount)
            }
            .store(in: &cancellables)

        // Start polling if API key is present
        if !dataManager.apiKey.isEmpty {
             dataManager.startPolling()
        }

        // Add observer for popover resize
        NotificationCenter.default.addObserver(self, selector: #selector(togglePopoverSize(_:)), name: .togglePopoverSize, object: nil)

        // Add observer for opening chat window
        NotificationCenter.default.addObserver(self, selector: #selector(showChatWindow(_:)), name: .showChatWindow, object: nil)

        // Add observer for closing centered menu
        NotificationCenter.default.addObserver(self, selector: #selector(handleCloseCenteredMenu), name: .closeCenteredMenu, object: nil)
    }

    @objc func handleCheckForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    @MainActor @objc func handleScreenshotCaptured(_ notification: Notification) {
        guard let image = notification.object as? NSImage else { return }

        // Set the captured image as the draft attachment
        dataManager.setDraftImageAttachment(image: image)

        // Show the appropriate menu based on user preference
        if dataManager.menuLaunchPosition == .centerScreen {
            if centeredMenuPanel?.isVisible != true {
                showCenteredMenu()
            }
        } else {
            if !isMenuBarPanelOpen {
                if let button = statusItem.button {
                    showMenuBarPanel(relativeTo: button)
                }
            }
        }
    }

    @MainActor @objc func handleOpenSettings() {
        // Open settings via SwiftUI Settings scene
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Trigger the SwiftUI Settings scene
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @MainActor @objc func settingsWindowWillClose() {
        settingsWindowController = nil
        // Only return to accessory mode if no other windows are open
        if sessionController == nil {
            NSApp.setActivationPolicy(.accessory)
            // Transition to menubar-only mode - reduce memory footprint
            transitionToMenubarOnlyMode()
        }
    }

    @MainActor @objc func showChatWindow(_ notification: Notification) {
        guard let session = notification.object as? Session else { return }
        openSessionInWindow(session)
    }

    @MainActor
    private func openSessionInWindow(_ session: Session) {
        // Close menu bar panel and centered menu before opening session window
        // This ensures a clean state transition for the menu bar to appear
        if isMenuBarPanelOpen {
            closeMenuBarPanel()
        }
        if isCenteredMenuIntentionallyOpen {
            closeCenteredMenu()
        }

        // Prepare resources for window mode (re-enables Metal if it was released)
        prepareForWindowMode()

        NSApp.setActivationPolicy(.regular)
        dataManager.activeSessionId = session.id

        if let sessionController = sessionController {
            sessionController.update(session: session)
            sessionController.window?.makeKeyAndOrderFront(nil)
        } else {
            sessionController = SessionController(session: session, dataManager: dataManager)
            sessionController?.showWindow(nil)

            // Observe window closing to remove from dictionary
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(chatWindowWillClose(_:)),
                name: NSWindow.willCloseNotification,
                object: sessionController?.window
            )
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor @objc func chatWindowWillClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.willCloseNotification,
            object: sessionController?.window
        )
        sessionController = nil
        dataManager.activeSessionId = nil
        // Only return to accessory mode if settings window is also closed
        if settingsWindowController == nil {
            NSApp.setActivationPolicy(.accessory)
            // Transition to menubar-only mode - reduce memory footprint
            transitionToMenubarOnlyMode()
        }
    }

    // MARK: - Status Bar Click Handling

    @MainActor @objc func handleStatusBarClick(_ sender: Any?) {
        guard let event = NSApp.currentEvent else { return }

        // Handle right-click
        if event.type == .rightMouseUp {
            showStatusItemMenu()
            return
        }

        // Handle left click
        if event.type == .leftMouseUp {
            togglePopover(sender)
        }
    }

    @MainActor @objc func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }

        // Check if this is a right-click
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            showStatusItemMenu()
            return
        }

        // Check the menu launch position setting
        if dataManager.menuLaunchPosition == .centerScreen {
            toggleCenteredMenu()
        } else {
            toggleMenuBarPopover(button: button, sender: sender)
        }
    }

    // MARK: - Voice Input

    @MainActor func toggleVoiceInput() {
        if #available(macOS 26.0, *) {
            VoiceInputPanelController.shared.toggle()
        }
    }

    private func toggleMenuBarPopover(button: NSStatusBarButton, sender: Any?) {
        // Close centered menu if open
        if centeredMenuPanel?.isVisible == true {
            closeCenteredMenu()
        }

        if isMenuBarPanelOpen {
            closeMenuBarPanel()
        } else {
            #if DEBUG
            print("[AppDelegate] Showing menu bar panel at \(CFAbsoluteTimeGetCurrent())")
            #endif
            showMenuBarPanel(relativeTo: button)
        }
    }

    @MainActor private func toggleCenteredMenu() {
        // Close menu bar panel if open
        if isMenuBarPanelOpen {
            closeMenuBarPanel()
        }

        // Use our own tracking flag instead of isVisible to handle edge cases
        // where the panel auto-shows on app activation
        if isCenteredMenuIntentionallyOpen {
            closeCenteredMenu()
        } else {
            showCenteredMenu()
        }
    }

    @MainActor private func showCenteredMenu() {
        // Track if this is the first time showing the panel (needs layout time)
        let isFirstShow = centeredMenuPanel == nil

        // Create the panel if it doesn't exist
        if centeredMenuPanel == nil {
            createCenteredMenuPanel()
        }

        guard let panel = centeredMenuPanel else { return }

        // Position in the lower-center of the main screen
        // Add padding for shadow to render (shadow radius 10 + offset 8 = ~18, use 25 for safety)
        let shadowPadding: CGFloat = 25
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let panelSize = NSSize(
                width: AppConstants.CenteredMenu.width + shadowPadding * 2,
                height: AppConstants.CenteredMenu.height + shadowPadding * 2
            )

            // Position horizontally centered, vertically in the lower-middle area
            // Adjust for shadow padding so the visual content appears in the same place
            let x = screenFrame.origin.x + (screenFrame.width - panelSize.width) / 2
            let y = screenFrame.origin.y + (screenFrame.height - panelSize.height) / 3  // Lower third

            // Use display: false to position without forcing immediate display
            // This prevents the panel from flashing before content is ready
            panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: panelSize), display: false)
        }

        // Mark as open synchronously to prevent race conditions on quick toggle
        isCenteredMenuIntentionallyOpen = true

        if isFirstShow {
            // On first show, the SwiftUI content needs time to lay out.
            // Start with alpha 0, let layout happen, then fade in.
            panel.alphaValue = 0
            panel.orderFront(nil)  // Show but invisible for layout

            // Give SwiftUI one run loop cycle to perform initial layout
            DispatchQueue.main.async { [weak panel] in
                guard let panel = panel else { return }
                panel.alphaValue = 1
                panel.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        } else {
            // Subsequent shows don't need the delay - content is already laid out
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        // Notify SwiftUI view that menu opened so it can clear selection state
        NotificationCenter.default.post(name: .menuDidOpen, object: nil)

        // Add global click monitor to detect clicks outside the panel
        if centeredMenuClickMonitor == nil {
            centeredMenuClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self = self, let panel = self.centeredMenuPanel, panel.isVisible else { return }

                // Check if click is outside the panel
                let clickLocation = event.locationInWindow
                let panelFrame = panel.frame

                // Convert screen coordinates - event.locationInWindow for global events is in screen coordinates
                if !panelFrame.contains(clickLocation) {
                    DispatchQueue.main.async {
                        self.closeCenteredMenu()
                    }
                }
            }
        }

        // Refresh data
        Task {
            await dataManager.fetchSessions()
            await dataManager.offlineSyncManager.syncPendingSessions()
        }
    }

    private func closeCenteredMenu() {
        centeredMenuPanel?.orderOut(nil)
        isCenteredMenuIntentionallyOpen = false

        // Remove the global click monitor
        if let monitor = centeredMenuClickMonitor {
            NSEvent.removeMonitor(monitor)
            centeredMenuClickMonitor = nil
        }
    }

    @MainActor @objc func handleCloseCenteredMenu() {
        closeCenteredMenu()
    }

    private func createCenteredMenuPanel() {
        let panel = KeyablePanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: AppConstants.CenteredMenu.width,
                height: AppConstants.CenteredMenu.height
            ),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false  // Shadow is handled by SwiftUI
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden

        // Allow the panel to become key for text input focus
        panel.becomesKeyOnlyIfNeeded = false
        // Don't use hidesOnDeactivate as it auto-shows on activation, causing toggle issues
        panel.hidesOnDeactivate = false

        // Create the centered menu view
        let centeredMenuView = CenteredMenuView().environmentObject(dataManager)
        centeredMenuHostingController = NSHostingController(rootView: AnyView(centeredMenuView))

        if let hostingController = centeredMenuHostingController {
            hostingController.view.translatesAutoresizingMaskIntoConstraints = false

            // Disable safe area insets to prevent extra top spacing for non-existent titlebar
            if #available(macOS 13.3, *) {
                hostingController.safeAreaRegions = []
            }

            // Configure layer but DON'T clip - let SwiftUI handle content clipping via .clipShape()
            // This allows shadows to render outside the content bounds
            hostingController.view.wantsLayer = true
            hostingController.view.layer?.masksToBounds = false

            panel.contentView?.addSubview(hostingController.view)

            if let contentView = panel.contentView {
                // Don't clip the content view - shadows need to extend beyond
                contentView.wantsLayer = true
                contentView.layer?.masksToBounds = false

                // Add padding to center content with room for shadow (matches shadowPadding in showCenteredMenu)
                let shadowPadding: CGFloat = 25
                NSLayoutConstraint.activate([
                    hostingController.view.topAnchor.constraint(equalTo: contentView.topAnchor, constant: shadowPadding),
                    hostingController.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: shadowPadding),
                    hostingController.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -shadowPadding),
                    hostingController.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -shadowPadding)
                ])
            }
        }

        centeredMenuPanel = panel

        // Close the panel when it loses key window status (user clicks outside)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(centeredMenuDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: panel
        )
    }

    @MainActor @objc private func centeredMenuDidResignKey(_ notification: Notification) {
        // Only close if the panel is the one that resigned key
        guard notification.object as? NSPanel === centeredMenuPanel else { return }
        closeCenteredMenu()
    }

    // MARK: - Menu Bar Panel (NSPanel positioned under status bar button)

    private func createMenuBarPanel() {
        let panel = KeyablePanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: cachedPopoverContentSize.width,
                height: cachedPopoverContentSize.height
            ),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden

        // Allow the panel to become key for text input focus
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false

        // Create the menu view (same as what was used in the popover)
        let menuView = MenuView().environmentObject(dataManager)
        menuBarPanelHostingController = NSHostingController(rootView: AnyView(menuView))

        if let hostingController = menuBarPanelHostingController {
            hostingController.view.translatesAutoresizingMaskIntoConstraints = false

            // Disable safe area insets
            if #available(macOS 13.3, *) {
                hostingController.safeAreaRegions = []
            }

            // Configure layer for proper rendering
            hostingController.view.wantsLayer = true
            hostingController.view.layer?.cornerRadius = 10
            hostingController.view.layer?.masksToBounds = true

            panel.contentView?.addSubview(hostingController.view)

            if let contentView = panel.contentView {
                contentView.wantsLayer = true

                NSLayoutConstraint.activate([
                    hostingController.view.topAnchor.constraint(equalTo: contentView.topAnchor),
                    hostingController.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                    hostingController.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                    hostingController.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
                ])
            }
        }

        menuBarPanel = panel

        // Close the panel when it loses key window status
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuBarPanelDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: panel
        )
    }

    @MainActor @objc private func menuBarPanelDidResignKey(_ notification: Notification) {
        guard notification.object as? NSPanel === menuBarPanel else { return }
        closeMenuBarPanel()
    }

    @MainActor private func showMenuBarPanel(relativeTo button: NSStatusBarButton) {
        // Track if this is the first time showing the panel (needs layout time)
        let isFirstShow = menuBarPanel == nil

        // Create the panel if it doesn't exist
        if menuBarPanel == nil {
            createMenuBarPanel()
        }

        guard let panel = menuBarPanel else { return }

        // Calculate position: top of panel at bottom of menu bar, aligned to button's left edge
        if let buttonWindow = button.window,
           let screen = buttonWindow.screen ?? NSScreen.main {
            let buttonFrameInScreen = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))

            // Position panel so its top aligns with bottom of menu bar (top of visible screen area)
            // and left edge aligns with button's left edge
            var panelX = buttonFrameInScreen.minX
            let panelY = screen.visibleFrame.maxY - cachedPopoverContentSize.height

            // Prevent panel from overflowing the right edge of the screen
            let screenMaxX = screen.visibleFrame.maxX
            let panelRightEdge = panelX + cachedPopoverContentSize.width
            if panelRightEdge > screenMaxX {
                panelX = screenMaxX - cachedPopoverContentSize.width
            }

            // Ensure we don't go past the left edge either
            let screenMinX = screen.visibleFrame.minX
            if panelX < screenMinX {
                panelX = screenMinX
            }

            // Use setFrame with display: false to set both size and position atomically
            // This prevents visual glitches from separate size/position updates
            let panelFrame = NSRect(
                x: panelX,
                y: panelY,
                width: cachedPopoverContentSize.width,
                height: cachedPopoverContentSize.height
            )
            panel.setFrame(panelFrame, display: false)
        }

        isMenuBarPanelOpen = true

        if isFirstShow {
            // On first show, SwiftUI content needs time to lay out.
            // Start with alpha 0, let layout happen, then fade in.
            panel.alphaValue = 0
            panel.orderFront(nil)  // Show but invisible for layout

            // Give SwiftUI one run loop cycle to perform initial layout
            DispatchQueue.main.async { [weak panel] in
                guard let panel = panel else { return }
                panel.alphaValue = 1
                panel.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        } else {
            // Subsequent shows don't need the delay - content is already laid out
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        // Notify SwiftUI view that menu opened
        NotificationCenter.default.post(name: .menuDidOpen, object: nil)

        // Add global click monitor for click-outside-to-close
        if menuBarPanelClickMonitor == nil {
            menuBarPanelClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self = self, let panel = self.menuBarPanel, panel.isVisible else { return }

                let clickLocation = event.locationInWindow
                let panelFrame = panel.frame

                if !panelFrame.contains(clickLocation) {
                    DispatchQueue.main.async {
                        self.closeMenuBarPanel()
                    }
                }
            }
        }

        // Refresh data
        Task {
            await dataManager.fetchSessions()
            await dataManager.offlineSyncManager.syncPendingSessions()
        }
    }

    private func closeMenuBarPanel() {
        menuBarPanel?.orderOut(nil)
        isMenuBarPanelOpen = false

        // Remove the global click monitor
        if let monitor = menuBarPanelClickMonitor {
            NSEvent.removeMonitor(monitor)
            menuBarPanelClickMonitor = nil
        }
    }

    private func showStatusItemMenu() {
        let menu = NSMenu()

        // Voice input option (macOS 26.0+ only)
        if #available(macOS 26.0, *) {
            let voiceInputItem = NSMenuItem(title: "Voice Input…", action: #selector(showVoiceInput), keyEquivalent: "")
            voiceInputItem.target = self
            menu.addItem(voiceInputItem)

            menu.addItem(NSMenuItem.separator())
        }

        let checkUpdatesItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        checkUpdatesItem.target = self
        menu.addItem(checkUpdatesItem)

        #if DEBUG
        menu.addItem(NSMenuItem.separator())

        let mergeConflictItem = NSMenuItem(title: "Test Merge Conflict View", action: #selector(showMergeConflictTest), keyEquivalent: "")
        mergeConflictItem.target = self
        menu.addItem(mergeConflictItem)
        #endif

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func showVoiceInput() {
        toggleVoiceInput()
    }

    @objc func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    @objc func togglePopoverSize(_ notification: Notification) {
        if let isExpanded = notification.object as? Bool {
            let newWidth = isExpanded ? AppConstants.Popover.expandedWidth : AppConstants.Popover.minimizedWidth
            let newHeight = isExpanded ? AppConstants.Popover.expandedHeight : AppConstants.Popover.minimizedHeight
            let newSize = NSSize(width: newWidth, height: newHeight)
            cachedPopoverContentSize = newSize
            // Defer panel resize to next run loop to avoid reentrant layout warning
            // when this notification is triggered from SwiftUI's onAppear
            Task { @MainActor [weak self] in
                guard let self = self, let panel = self.menuBarPanel else { return }

                // Get current frame and screen
                let currentFrame = panel.frame
                guard let screen = panel.screen ?? NSScreen.main else {
                    panel.setContentSize(newSize)
                    return
                }

                // Calculate new frame with adjusted position to prevent right-edge overflow
                var newX = currentFrame.origin.x
                let screenMaxX = screen.visibleFrame.maxX
                let newRightEdge = newX + newWidth

                // If the new right edge would overflow the screen, shift left
                if newRightEdge > screenMaxX {
                    newX = screenMaxX - newWidth
                }

                // Ensure we don't go past the left edge either
                let screenMinX = screen.visibleFrame.minX
                if newX < screenMinX {
                    newX = screenMinX
                }

                let newFrame = NSRect(
                    x: newX,
                    y: currentFrame.origin.y,
                    width: newWidth,
                    height: newHeight
                )
                panel.setFrame(newFrame, display: true)
            }
        }
    }

 // Animation Logic adapted for SessionState
   private func startStartingAnimation() {
       guard startingAnimationTimer == nil, !startingImageNames.isEmpty else { return }
       currentStartingFrameIndex = 0
       startingAnimationTimer = Timer.scheduledTimer(timeInterval: 0.2, target: self, selector: #selector(animateStartingIcon), userInfo: nil, repeats: true)
       if let timer = startingAnimationTimer { RunLoop.current.add(timer, forMode: .default) }
   }

   private func stopStartingAnimation() {
       guard startingAnimationTimer != nil else { return }
       startingAnimationTimer?.invalidate(); startingAnimationTimer = nil; currentStartingFrameIndex = 0
   }

   @objc private func animateStartingIcon() {
       currentStartingFrameIndex = (currentStartingFrameIndex + 1) % startingImageNames.count
       let currentFrameAssetName = startingImageNames[currentStartingFrameIndex]
       setStatusBarButtonImage(assetName: currentFrameAssetName)
   }

   private func startRunningAnimation() {
       guard runningAnimationTimer == nil, !runningImageNames.isEmpty else { return }
       currentRunningFrameIndex = 0
       runningAnimationTimer = Timer.scheduledTimer(timeInterval: 0.30, target: self, selector: #selector(animateRunningIcon), userInfo: nil, repeats: true)
       if let timer = runningAnimationTimer { RunLoop.current.add(timer, forMode: .default) }
   }

   private func stopRunningAnimation() {
       guard runningAnimationTimer != nil else { return }
       runningAnimationTimer?.invalidate(); runningAnimationTimer = nil; currentRunningFrameIndex = 0
   }

   @objc private func animateRunningIcon() {
       currentRunningFrameIndex = (currentRunningFrameIndex + 1) % runningImageNames.count
       let currentFrameAssetName = runningImageNames[currentRunningFrameIndex]
       setStatusBarButtonImage(assetName: currentFrameAssetName)
   }

    private func setStatusBarButtonImage(assetName: String) {
        guard let button = statusItem.button else { return }

        if let image = NSImage(named: assetName) {
            button.image = image
            image.size = NSSize(width: 26, height: 22)
        } else {
            button.title = "?"
            button.image = nil
        }
    }

    /// Updates the dock icon badge with the count of unviewed sessions
    /// - Parameter count: The number of unviewed completed sessions
    func updateDockBadge(count: Int) {
        if count > 0 {
            NSApp.dockTile.badgeLabel = String(count)
        } else {
            NSApp.dockTile.badgeLabel = nil
        }
    }

    func updateStatusIcon(state: SessionState, isUnviewedCompleted: Bool = false) {
        // Skip update if nothing has changed
        guard state != lastStatusIconState || isUnviewedCompleted != lastUnviewedCompleted else { return }

        if state != .queued && state != .planning {
            stopStartingAnimation()
        }
        if state != .inProgress {
            stopRunningAnimation()
        }

        // Use review icon for unviewed completed sessions
        let iconAssetName: String
        if isUnviewedCompleted {
            iconAssetName = "jules-menu-review"
        } else {
            iconAssetName = state.menuIconName
        }

        setStatusBarButtonImage(assetName: iconAssetName)

        lastStatusIconState = state
        lastUnviewedCompleted = isUnviewedCompleted

        switch state {
        case .queued, .planning:
            startStartingAnimation()
        case .inProgress:
            startRunningAnimation()
        default:
            break
        }
    }

    nonisolated deinit {
        NotificationCenter.default.removeObserver(self)
        // Can't call main actor methods from deinit
        // Animation timers will be invalidated when deallocated
        cancellables.forEach { $0.cancel() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopRunningAnimation()
        stopStartingAnimation()
        cancellables.forEach { $0.cancel() }

        // Clean up notifications on termination
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            center.removeAllDeliveredNotifications()
            center.removeAllPendingNotificationRequests()
        }
    }

    // --- Notification Handling ---

    @objc func handleNewNotifications(_ notification: Notification) {
        guard let fetchedNotifications = notification.userInfo?["notifications"] as? [AppNotification] else {
            return
        }
        Task { @MainActor in
            for appNotification in fetchedNotifications {
                displaySystemNotification(for: appNotification)
            }
        }
    }

    @MainActor
    func displaySystemNotification(for appNotification: AppNotification) {
        var userInfo: [String: String] = [
            "notificationId": appNotification.id,
            "sessionId": appNotification.sessionId
        ]
        if let url = appNotification.relatedUrl {
            userInfo["relatedUrl"] = url
        }

        NotificationManager.shared.displayNotification(
            title: appNotification.title,
            subtitle: appNotification.subtitle,
            body: appNotification.body,
            identifier: appNotification.id,
            userInfo: userInfo
        )
    }

    // UNUserNotificationCenterDelegate methods
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo

        // Prioritize opening the session in-app
        Task { @MainActor in
            if let sessionId = userInfo["sessionId"] as? String,
               let session = dataManager.sessionsById[sessionId] {
                self.openSessionInWindow(session)
            } else if let urlString = userInfo["relatedUrl"] as? String, let url = URL(string: urlString) {
                // Fallback to opening the URL if session isn't found locally
                NSWorkspace.shared.open(url)
            }
            completionHandler()
        }
    }

    // MARK: - Menu Validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        // All menu items in our app menu should be enabled
        return true
    }

    // MARK: - Hotkey Registration

    /// Registers global hotkeys based on user preferences from KeyboardShortcutsManager
    /// Called on app launch and whenever user changes shortcuts in settings
    private func registerHotkeys() {
        let shortcuts = KeyboardShortcutsManager.shared

        // Clear existing hotkeys before re-registering
        hotKey = nil
        screenshotHotKey = nil
        voiceInputHotKey = nil

        // Toggle Jules hotkey (Control+Option+[user key])
        hotKey = HotKey(key: shortcuts.toggleJulesKey, modifiers: [.control, .option])
        hotKey?.keyDownHandler = { [weak self] in
            self?.togglePopover(nil)
        }

        // Screenshot hotkey (Control+Option+[user key]) for interactive screen capture
        screenshotHotKey = HotKey(key: shortcuts.screenshotKey, modifiers: [.control, .option])
        screenshotHotKey?.keyDownHandler = {
            Task { @MainActor in
                ScreenCaptureManager.shared.captureAndNotify()
            }
        }

        // Voice input hotkey (Control+Option+[user key]) for voice-to-text session creation
        // Only available on macOS 26.0+ where SpeechTranscriptionManager is supported
        if #available(macOS 26.0, *) {
            voiceInputHotKey = HotKey(key: shortcuts.voiceInputKey, modifiers: [.control, .option])
            voiceInputHotKey?.keyDownHandler = { [weak self] in
                Task { @MainActor in
                    self?.toggleVoiceInput()
                }
            }
        }
    }

    // MARK: - Main Menu Setup

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // Application Menu (Jules)
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "About Jules", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())

        // Use SwiftUI Settings scene - trigger via standard settings action
        let settingsItem = NSMenuItem(title: "Settings...", action: Selector(("showSettingsWindow:")), keyEquivalent: ",")
        settingsItem.keyEquivalentModifierMask = .command
        // No target - uses responder chain to find SwiftUI's Settings scene handler
        appMenu.addItem(settingsItem)

        appMenu.addItem(NSMenuItem.separator())
        let checkUpdatesItem = NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: "")
        checkUpdatesItem.target = self
        appMenu.addItem(checkUpdatesItem)

        let sendFeedbackItem = NSMenuItem(title: "Send Feedback...", action: #selector(showFeedbackWindow), keyEquivalent: "")
        sendFeedbackItem.target = self
        appMenu.addItem(sendFeedbackItem)

        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Jules", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // View Menu
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")

        let makeBiggerItem = NSMenuItem(title: "Make Text Bigger", action: #selector(increaseFontSize), keyEquivalent: "+")
        makeBiggerItem.keyEquivalentModifierMask = .command
        makeBiggerItem.target = self
        viewMenu.addItem(makeBiggerItem)

        let makeSmallerItem = NSMenuItem(title: "Make Text Smaller", action: #selector(decreaseFontSize), keyEquivalent: "-")
        makeSmallerItem.keyEquivalentModifierMask = .command
        makeSmallerItem.target = self
        viewMenu.addItem(makeSmallerItem)

        let resetSizeItem = NSMenuItem(title: "Reset Text Size", action: #selector(resetFontSize), keyEquivalent: "0")
        resetSizeItem.keyEquivalentModifierMask = .command
        resetSizeItem.target = self
        viewMenu.addItem(resetSizeItem)

        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // Debug Menu (only in DEBUG builds)
        #if DEBUG
        let debugMenuItem = NSMenuItem()
        let debugMenu = NSMenu(title: "Debug")

        let mergeConflictTestItem = NSMenuItem(title: "Test Merge Conflict View", action: #selector(showMergeConflictTest), keyEquivalent: "M")
        mergeConflictTestItem.keyEquivalentModifierMask = [.command, .shift]
        mergeConflictTestItem.target = self
        debugMenu.addItem(mergeConflictTestItem)

        debugMenuItem.submenu = debugMenu
        mainMenu.addItem(debugMenuItem)
        #endif

        // Window Menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: ""))
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
    }

    @objc private func increaseFontSize() {
        Task { @MainActor in
            FontSizeManager.shared.increaseFontSize()
        }
    }

    @objc private func decreaseFontSize() {
        Task { @MainActor in
            FontSizeManager.shared.decreaseFontSize()
        }
    }

    @objc private func resetFontSize() {
        Task { @MainActor in
            FontSizeManager.shared.resetToDefaults()
        }
    }

    @MainActor @objc func openSettings() {
        handleOpenSettings()
    }

    @MainActor @objc private func showMergeConflictTest() {
        // Ensure a session window is open first
        NSApp.setActivationPolicy(.regular)

        if sessionController == nil {
            // Open a new session window with the test view
            sessionController = SessionController(session: dataManager.recentSessions.first, dataManager: dataManager)
            sessionController?.showWindow(nil)

            // Observe window closing
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(chatWindowWillClose(_:)),
                name: NSWindow.willCloseNotification,
                object: sessionController?.window
            )
        }

        // Open the merge conflict test view
        // Note: MergeConflictWindowManager handles window focus internally
        sessionController?.toggleMergeConflictTest()
    }

    // MARK: - Public Actions for SwiftUI Commands

    func increaseFontSizeAction() {
        increaseFontSize()
    }

    func decreaseFontSizeAction() {
        decreaseFontSize()
    }

    func resetFontSizeAction() {
        resetFontSize()
    }

    @MainActor func showMergeConflictTestAction() {
        showMergeConflictTest()
    }

    // MARK: - Feedback Window

    @MainActor @objc func showFeedbackWindow() {
        // Bring app to foreground
        NSApp.setActivationPolicy(.regular)

        if let existingController = feedbackWindowController {
            existingController.window?.makeKeyAndOrderFront(nil)
        } else {
            // Create the feedback window
            let feedbackView = FeedbackView()
            let hostingController = NSHostingController(rootView: feedbackView)

            let window = NSWindow(contentViewController: hostingController)
            window.title = "Send Feedback"
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 400, height: 420))
            window.center()
            window.isReleasedWhenClosed = false

            let windowController = NSWindowController(window: window)
            feedbackWindowController = windowController

            // Observe window closing
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(feedbackWindowWillClose(_:)),
                name: NSWindow.willCloseNotification,
                object: window
            )

            windowController.showWindow(nil)
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor @objc private func feedbackWindowWillClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.willCloseNotification,
            object: feedbackWindowController?.window
        )
        feedbackWindowController = nil

        // Only return to accessory mode if no other windows are open
        if sessionController == nil && settingsWindowController == nil {
            NSApp.setActivationPolicy(.accessory)
            // Transition to menubar-only mode - reduce memory footprint
            transitionToMenubarOnlyMode()
        }
    }

    // MARK: - Memory Management for Menubar-Only Mode

    /// Called when transitioning to menubar-only mode (all windows closed).
    /// Releases heavy resources to reduce memory footprint.
    @MainActor private func transitionToMenubarOnlyMode() {
        #if DEBUG
        print("[AppDelegate] Transitioning to menubar-only mode - releasing resources")
        #endif

        // Delay cleanup slightly to ensure window close animations complete
        // and avoid releasing resources that might still be referenced
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms

            // Double-check we're still in menubar-only mode
            guard self.sessionController == nil && self.settingsWindowController == nil && self.feedbackWindowController == nil else {
                #if DEBUG
                print("[AppDelegate] Window opened during cleanup delay - aborting")
                #endif
                return
            }

            // Release Metal/GPU resources (saves ~50-100MB)
            SharedMetalResourcesManager.shared.releaseResources()

            // Trim session data (clear activities from memory)
            self.dataManager.trimSessionDataForMenubarMode()

            // Clear TileHeightCalculator cache
            TileHeightCalculator.shared.clearCache()

            // Clear SharedSyntaxCache (saves ~30-45MB)
            // This cache holds parsed syntax tokens for diff view highlighting.
            // It's populated when viewing sessions and never cleared otherwise.
            SharedSyntaxCache.shared.clear()

            // Clear URLSession cache (saves variable memory)
            // API responses can accumulate in the shared URL cache
            URLCache.shared.removeAllCachedResponses()

            // Stop FSEvents file watchers (reduces CPU/memory usage)
            FilenameAutocompleteManager.shared.stopAllWatchers()

            // Release centered menu panel and hosting controller
            // This prevents ViewBridge memory issues when the system disconnects
            // remote view services for hidden panels
            if let panel = self.centeredMenuPanel {
                NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: panel)
                panel.contentView?.subviews.forEach { $0.removeFromSuperview() }
                panel.orderOut(nil)
            }
            self.centeredMenuHostingController = nil
            self.centeredMenuPanel = nil
            if let monitor = self.centeredMenuClickMonitor {
                NSEvent.removeMonitor(monitor)
                self.centeredMenuClickMonitor = nil
            }

            // Release menu bar panel and hosting controller
            if let panel = self.menuBarPanel {
                NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: panel)
                panel.contentView?.subviews.forEach { $0.removeFromSuperview() }
                panel.orderOut(nil)
            }
            self.menuBarPanelHostingController = nil
            self.menuBarPanel = nil
            if let monitor = self.menuBarPanelClickMonitor {
                NSEvent.removeMonitor(monitor)
                self.menuBarPanelClickMonitor = nil
            }

            #if DEBUG
            print("[AppDelegate] Menubar-only mode transition complete")
            #endif
        }
    }

    /// Called when opening a window that needs full resources.
    /// Prepares Metal resources for use and resumes file watchers.
    @MainActor private func prepareForWindowMode() {
        SharedMetalResourcesManager.shared.prepareForUse()
        FilenameAutocompleteManager.shared.resumeAllWatchers()
    }

}

