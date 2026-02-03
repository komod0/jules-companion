import SwiftUI
import AppKit
import Combine

// MARK: - Sidebar Animation Notifications
extension Notification.Name {
    static let sidebarAnimationWillStart = Notification.Name("sidebarAnimationWillStart")
    static let sidebarAnimationDidEnd = Notification.Name("sidebarAnimationDidEnd")
    static let splitViewDividerDidResize = Notification.Name("splitViewDividerDidResize")
}

// Helper class to manage Tahoe state bridge, defined at module level
class TahoeState: ObservableObject {
    @Published var columnVisibility: NavigationSplitViewVisibility = .detailOnly

    func toggle() {
        if columnVisibility == .detailOnly {
            columnVisibility = .all
        } else {
            columnVisibility = .detailOnly
        }
    }
}

class SessionSelectionState: ObservableObject {
    @Published var selectedSessionId: String?
    @Published var isCreatingNewSession: Bool = false

    init(selectedSessionId: String?, isCreatingNewSession: Bool = false) {
        // Use underscored access to avoid triggering didSet during init
        _selectedSessionId = Published(initialValue: selectedSessionId)
        _isCreatingNewSession = Published(initialValue: isCreatingNewSession)
    }
}

struct SidebarWrapper: View {
    @ObservedObject var selectionState: SessionSelectionState
    @EnvironmentObject var dataManager: DataManager
    var onSessionSelected: (Session) -> Void

    var body: some View {
        SidebarView(
            selectedSessionId: $selectionState.selectedSessionId,
            onSessionSelected: onSessionSelected
        )
        .frame(minWidth: 250)
        .ignoresSafeArea()
        // Use sidebar-specific glass effect for proper edge-to-edge glass on macOS 26+
        .unifiedBackground(material: .underWindowBackground, blendingMode: .behindWindow, tintOverlayOpacity: 0.5, effectType: .sidebar)
    }
}

// MARK: - Deferred Loading Wrapper
/// Wrapper view that shows a loading placeholder, then loads the actual content
/// This enables the window to appear instantly while heavy views load in background
struct DeferredSessionContentView: View {
    let session: Session?
    @EnvironmentObject var dataManager: DataManager
    @State private var isLoaded = false
    @State private var viewAppearTime: CFAbsoluteTime?

    var body: some View {
        Group {
            if isLoaded {
                MainSessionView(session: session)
                    .onAppear {
                        // Track when the actual MainSessionView appears
                        LoadingProfiler.shared.checkpoint("View: MainSessionView appeared")
                        LoadingProfiler.shared.endSpan("View: DeferredSessionContentView loading")
                        LoadingProfiler.shared.endSession()
                    }
            } else {
                // Lightweight loading placeholder
                VStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.large)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            viewAppearTime = CFAbsoluteTimeGetCurrent()
            LoadingProfiler.shared.checkpoint("View: DeferredSessionContentView placeholder appeared")
            LoadingProfiler.shared.beginSpan("View: DeferredSessionContentView loading")
            // Load the real content on next run loop
            DispatchQueue.main.async {
                LoadingProfiler.shared.checkpoint("View: DeferredSessionContentView isLoaded = true")
                isLoaded = true

                // OPTIMIZATION: Pre-fetch activities immediately when content starts loading
                // This gives the API ~300ms more time compared to waiting for TrajectoryView.onAppear
                if let session = session {
                    LoadingProfiler.shared.checkpoint("Data: ensureActivities triggered early")
                    dataManager.ensureActivities(for: session)
                }
            }
        }
    }
}

/// Lightweight placeholder for sidebar - loads actual content when first expanded
struct DeferredSidebarWrapper: View {
    @ObservedObject var selectionState: SessionSelectionState
    @EnvironmentObject var dataManager: DataManager
    var onSessionSelected: (Session) -> Void
    @State private var isLoaded = false

    var body: some View {
        Group {
            if isLoaded {
                SidebarView(
                    selectedSessionId: $selectionState.selectedSessionId,
                    onSessionSelected: onSessionSelected
                )
                .onAppear {
                    LoadingProfiler.shared.checkpoint("View: SidebarView appeared")
                    LoadingProfiler.shared.endSpan("View: DeferredSidebarWrapper loading")
                }
            } else {
                // Placeholder until first expanded
                VStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Spacer()
                }
            }
        }
        .frame(minWidth: 250)
        .ignoresSafeArea()
        // Use sidebar-specific glass effect for proper edge-to-edge glass on macOS 26+
        .unifiedBackground(material: .underWindowBackground, blendingMode: .behindWindow, tintOverlayOpacity: 0.5, effectType: .sidebar)
        .onAppear {
            // Load sidebar content when it becomes visible
            if !isLoaded {
                LoadingProfiler.shared.checkpoint("View: DeferredSidebarWrapper placeholder appeared")
                LoadingProfiler.shared.beginSpan("View: DeferredSidebarWrapper loading")
                DispatchQueue.main.async {
                    LoadingProfiler.shared.checkpoint("View: DeferredSidebarWrapper isLoaded = true")
                    isLoaded = true
                }
            }
        }
    }
}

/// Deferred loading wrapper for Tahoe window content
@available(macOS 13.0, *)
struct DeferredTahoeContentView: View {
    @ObservedObject var selectionState: SessionSelectionState
    let initialSession: Session?
    var onPreviousSession: (() -> Void)?
    var onNextSession: (() -> Void)?
    var onNewChat: (() -> Void)?
    @ObservedObject var tahoeState: TahoeState
    @State private var isLoaded = false

    var body: some View {
        Group {
            if isLoaded {
                TahoeSessionView(
                    selectionState: selectionState,
                    initialSession: initialSession,
                    onToggleSidebar: nil,
                    onPreviousSession: onPreviousSession,
                    onNextSession: onNextSession,
                    onNewChat: onNewChat,
                    tahoeState: tahoeState
                )
                .onAppear {
                    LoadingProfiler.shared.checkpoint("View: TahoeSessionView appeared")
                    LoadingProfiler.shared.endSpan("View: DeferredTahoeContentView loading")
                    LoadingProfiler.shared.endSession()
                }
            } else {
                // Lightweight loading placeholder
                VStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.large)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Use underWindow effect type for main content area
        .unifiedBackground(material: .underWindowBackground, blendingMode: .behindWindow, tintOverlayOpacity: 0.5, effectType: .underWindow)
        .onAppear {
            LoadingProfiler.shared.checkpoint("View: DeferredTahoeContentView placeholder appeared")
            LoadingProfiler.shared.beginSpan("View: DeferredTahoeContentView loading")
            // Load the real content on next run loop
            DispatchQueue.main.async {
                LoadingProfiler.shared.checkpoint("View: DeferredTahoeContentView isLoaded = true")
                isLoaded = true
            }
        }
    }
}

class SessionController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    private var dataManager: DataManager
    private var splitViewController: NSSplitViewController!
    private var mainContentHostingController: NSHostingController<AnyView>!
    private var selectionState: SessionSelectionState
    private var initialSession: Session?
    private var toolbarHostingView: NSHostingView<AnyView>?
    private var cancellables = Set<AnyCancellable>()

    // Task for loading more sessions during pagination - stored so it can be cancelled
    // when the user navigates away or creates a new session
    private var paginationTask: Task<Void, Never>?

    // For Tahoe
    private var tahoeState = TahoeState()

    // Merge Conflict Window is now in its own NSWindow
    // Use MergeConflictWindowManager.shared.openWindow() to open it

    // State restoration keys
    private static let sidebarWidthKey = "SessionController.sidebarWidth"
    private static let sidebarCollapsedKey = "SessionController.sidebarCollapsed"

    // Observer for split view resize notifications
    private var splitViewResizeObserver: Any?

    // Toolbar item identifier for our custom view
    private static let customToolbarItemIdentifier = NSToolbarItem.Identifier("CustomToolbarItem")

    init(session: Session?, dataManager: DataManager) {
        let profiler = LoadingProfiler.shared
        profiler.startSession(label: "SessionController Load (session: \(session?.id ?? "new"))")
        profiler.beginSpan("Init: SessionController.init")

        self.dataManager = dataManager
        self.initialSession = session
        self.selectionState = SessionSelectionState(
            selectedSessionId: session?.id,
            isCreatingNewSession: session == nil
        )
        profiler.checkpoint("Init: Properties assigned")

        // PERFORMANCE: Start preloading diffs immediately in background
        // This runs in parallel with window setup so diffs are ready when view renders
        if let sessionId = session?.id {
            DiffStorageManager.shared.preloadDiffs(forSession: sessionId)
        }

        super.init(window: nil)
        profiler.checkpoint("Init: super.init completed")

        // Subscribe to session creation events
        profiler.beginSpan("Setup: SessionCreationSubscription")
        setupSessionCreationSubscription()
        profiler.endSpan("Setup: SessionCreationSubscription")

        // Tahoe macOS 26 Check
        if #available(macOS 26.0, *) {
            // New Tahoe Implementation
            profiler.beginSpan("Setup: TahoeWindow")
            setupTahoeWindow(session: session)
            profiler.endSpan("Setup: TahoeWindow")
        } else {
            // Legacy Implementation
            profiler.beginSpan("Setup: LegacyWindow")
            setupLegacyWindow(session: session)
            profiler.endSpan("Setup: LegacyWindow")
        }

        profiler.endSpan("Init: SessionController.init")
    }

    private func setupSessionCreationSubscription() {
        // Listen for session creation to update the view when a new session is created
        // CRITICAL: Do NOT use .receive(on: DispatchQueue.main) here!
        // The publisher is sent from DataManager (which is @MainActor), so we're already
        // on the main thread. Using .receive(on:) would schedule the handler for the NEXT
        // run loop, causing a race condition where:
        // 1. recentSessions is updated (triggers objectWillChange, queues view re-render)
        // 2. sessionCreatedPublisher.send() is called
        // 3. Handler is scheduled for next run loop (due to .receive(on:))
        // 4. SwiftUI re-renders BEFORE handler runs, showing old selectedSessionId
        // 5. Handler finally runs and updates selectedSessionId (too late!)
        // By removing .receive(on:), the handler runs synchronously when send() is called,
        // ensuring selectedSessionId is updated BEFORE SwiftUI re-renders.
        dataManager.sessionCreatedPublisher
            .sink { [weak self] newSession in
                // NOTE: We intentionally don't check isCreatingNewSession here.
                // NewTaskFormView calls dataManager.createSession() directly without
                // going through SessionController.createNewSession(), so isCreatingNewSession
                // may not be set. We should always navigate to a newly created session.
                guard let self = self,
                      let newSession = newSession else { return }

                // update() handles all state changes: initialSession, selectedSessionId,
                // isCreatingNewSession, plus preloading, activity loading, etc.
                self.update(session: newSession)
            }
            .store(in: &cancellables)
    }

    // MARK: - Tahoe Implementation

    private func setupTahoeWindow(session: Session?) {
        // Create Tahoe View with deferred loading for faster window appearance
        // The actual TahoeSessionView is loaded on the next run loop after window appears
        if #available(macOS 13.0, *) {
            let deferredView = DeferredTahoeContentView(
                selectionState: selectionState,
                initialSession: session,
                onPreviousSession: { [weak self] in self?.goToPreviousSession() },
                onNextSession: { [weak self] in self?.goToNextSession() },
                onNewChat: { [weak self] in self?.createNewSession() },
                tahoeState: tahoeState
            )

            let hostingController = NSHostingController(rootView: AnyView(deferredView.environmentObject(dataManager)))

            let window = NSWindow(contentViewController: hostingController)
            window.setContentSize(NSSize(width: 1200, height: 800))
            window.center()

            // Tahoe style - configure for glass effect toolbar
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = false
            
            // Create an invisible NSToolbar to enable toolbar area glass effect
            // This is necessary for SwiftUI's toolbar to have a visible glass background
            let toolbar = NSToolbar(identifier: NSToolbar.Identifier("TahoeToolbar"))
            toolbar.displayMode = .iconOnly
            toolbar.showsBaselineSeparator = false
            window.toolbar = toolbar
            window.toolbarStyle = .unified

            self.window = window
            window.delegate = self
        }
    }                                     

    // MARK: - Legacy Implementation

    private func setupLegacyWindow(session: Session?) {
        let profiler = LoadingProfiler.shared

        // Main content view - Use deferred loading wrapper to show window instantly
        // The actual MainSessionView is loaded on the next run loop after window appears
        profiler.beginSpan("Setup: CreateDeferredContentView")
        let contentView = AnyView(DeferredSessionContentView(session: session).environmentObject(dataManager))
        self.mainContentHostingController = NSHostingController(rootView: contentView)
        profiler.endSpan("Setup: CreateDeferredContentView")

        // Sidebar view - Use deferred loading since sidebar starts collapsed
        // The actual SidebarView is loaded when sidebar becomes visible
        profiler.beginSpan("Setup: CreateDeferredSidebarWrapper")
        let sidebarWrapper = DeferredSidebarWrapper(
            selectionState: self.selectionState,
            onSessionSelected: { [weak self] selectedSession in
                self?.selectionState.isCreatingNewSession = false
                self?.update(session: selectedSession)
            }
        ).environmentObject(dataManager)

        let sidebarHostingController = NSHostingController(rootView: AnyView(sidebarWrapper))
        profiler.endSpan("Setup: CreateDeferredSidebarWrapper")

        // Phase 1: Split view controller with optimized configuration
        // Design principle: "The Sidebar holds its ground; the DiffView yields."
        profiler.beginSpan("Setup: ConfigureSplitViewController")
        self.splitViewController = NSSplitViewController()

        // Configure sidebar item with proper behavior and constraints
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHostingController)
        sidebarItem.isCollapsed = true

        // Phase 1: Holding Priority - Sidebar (200) holds ground, Content (199) yields
        // This minimizes constraint churn during resize operations
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(200)

        // Define sidebar size limits via thickness (replaces legacy delegate methods)
        sidebarItem.minimumThickness = 250
        sidebarItem.maximumThickness = 400

        // Allow collapse via divider drag or toggle action
        sidebarItem.canCollapse = true

        // Configure content item with lower holding priority to absorb resize changes
        let contentItem = NSSplitViewItem(viewController: mainContentHostingController)
        contentItem.holdingPriority = NSLayoutConstraint.Priority(199)

        self.splitViewController.addSplitViewItem(sidebarItem)
        self.splitViewController.addSplitViewItem(contentItem)

        // Enable layer-backed views for GPU-accelerated animation
        // This offloads sidebar toggle animation to Core Animation
        // NOTE: Using .center placement to prevent visual "sliding" artifacts when views
        // re-render (e.g., when markSessionAsViewed triggers a session state update).
        // The .scaleProportionallyToFill placement caused cached content to animate/slide
        // during re-renders because it tries to maintain aspect ratio during scaling.
        sidebarHostingController.view.wantsLayer = true
        sidebarHostingController.view.layerContentsRedrawPolicy = .duringViewResize
        sidebarHostingController.view.layerContentsPlacement = .center
        mainContentHostingController.view.wantsLayer = true
        mainContentHostingController.view.layerContentsRedrawPolicy = .duringViewResize
        mainContentHostingController.view.layerContentsPlacement = .center
        profiler.endSpan("Setup: ConfigureSplitViewController")

        // Create a root view controller
        profiler.beginSpan("Setup: CreateVisualEffectView")
        let rootViewController = NSViewController()

        // Create the visual effect view for the entire window
        // Uses adaptive glass effects: NSGlassEffectView on macOS 26+, NSVisualEffectView on earlier versions
        let effectView = createAdaptiveEffectView(effectType: .underWindow)
        rootViewController.view = effectView

        // Add tint overlay for unified background styling (only needed on macOS < 26)
        // On macOS 26+, the glass effect provides proper visual treatment automatically
        if #unavailable(macOS 26.0) {
            let tintOverlay = NSHostingView(rootView:
                AppColors.background
                    .opacity(0.5)
                    .blendMode(.overlay)
                    .ignoresSafeArea()
            )
            tintOverlay.translatesAutoresizingMaskIntoConstraints = false
            effectView.addSubview(tintOverlay)
            NSLayoutConstraint.activate([
                tintOverlay.topAnchor.constraint(equalTo: effectView.topAnchor),
                tintOverlay.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
                tintOverlay.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
                tintOverlay.trailingAnchor.constraint(equalTo: effectView.trailingAnchor)
            ])
        }
        profiler.endSpan("Setup: CreateVisualEffectView")

        // Create the window
        profiler.beginSpan("Setup: CreateWindow")
        let window = NSWindow(contentViewController: rootViewController)
        window.setContentSize(NSSize(width: 1200, height: 800))
        window.center()
        window.title = ""

        // Window style configuration
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true

        self.window = window
        profiler.endSpan("Setup: CreateWindow")

        // Setup custom toolbar view BEFORE creating toolbar (delegate needs the view)
        profiler.beginSpan("Setup: ToolbarView")
        setupToolbarView()
        profiler.endSpan("Setup: ToolbarView")

        // Create and configure toolbar with unified style for proper stoplight spacing
        profiler.beginSpan("Setup: ConfigureToolbar")
        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        profiler.endSpan("Setup: ConfigureToolbar")


        self.window = window

        // Add splitViewController as a child
        profiler.beginSpan("Setup: ConfigureLayoutConstraints")
        rootViewController.addChild(self.splitViewController)
        let splitView = self.splitViewController.view
        splitView.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(splitView)

        // Add constraints for the split view (fills the content area below titlebar)
        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: effectView.topAnchor, constant: CustomToolbarView.toolbarHeight + 10),
            splitView.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: effectView.trailingAnchor)
        ])

        // Enable layer-backing on split view itself for smooth divider animations
        splitView.wantsLayer = true
        profiler.endSpan("Setup: ConfigureLayoutConstraints")

        // Setup sidebar state persistence (saves width on resize)
        profiler.beginSpan("Setup: SidebarStateObserver")
        setupSidebarStateObserver()
        profiler.endSpan("Setup: SidebarStateObserver")

        // Restore saved sidebar state after layout is established
        profiler.beginSpan("Setup: RestoreSidebarState")
        restoreSidebarState()
        profiler.endSpan("Setup: RestoreSidebarState")

        // Restore delegate assignment for legacy window
        window.delegate = self
        profiler.checkpoint("Setup: LegacyWindow complete")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupToolbarView() {
        let toolbarView = CustomToolbarView(
            selectionState: selectionState,
            initialSession: initialSession,
            onToggleSidebar: { [weak self] in
                self?.toggleSidebar(nil)
            },
            onPreviousSession: { [weak self] in
                self?.goToPreviousSession()
            },
            onNextSession: { [weak self] in
                self?.goToNextSession()
            },
            onNewSession: { [weak self] in
                self?.createNewSession()
            }
        ).environmentObject(dataManager)

        let hostingView = NSHostingView(rootView: AnyView(toolbarView))
        hostingView.frame = NSRect(x: 0, y: 0, width: 800, height: CustomToolbarView.toolbarHeight)
        self.toolbarHostingView = hostingView
    }

    private func updateToolbarView() {
        let toolbarView = CustomToolbarView(
            selectionState: selectionState,
            initialSession: initialSession,
            onToggleSidebar: { [weak self] in
                self?.toggleSidebar(nil)
            },
            onPreviousSession: { [weak self] in
                self?.goToPreviousSession()
            },
            onNextSession: { [weak self] in
                self?.goToNextSession()
            },
            onNewSession: { [weak self] in
                self?.createNewSession()
            }
        ).environmentObject(dataManager)

        toolbarHostingView?.rootView = AnyView(toolbarView)
    }

    // MARK: - NSToolbarDelegate

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if itemIdentifier == Self.customToolbarItemIdentifier {
            let toolbarItem = NSToolbarItem(itemIdentifier: itemIdentifier)
            if let hostingView = toolbarHostingView {
                toolbarItem.view = hostingView
                // Note: minSize/maxSize are deprecated but still required for custom toolbar views
                // that need to expand to fill available space. The replacement (constraints) doesn't
                // work well with NSToolbar's layout system.
                 toolbarItem.minSize = NSSize(width: 200, height: CustomToolbarView.toolbarHeight)
                 toolbarItem.maxSize = NSSize(width: 10000, height: CustomToolbarView.toolbarHeight)
            }
            return toolbarItem
        }
        return nil
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [Self.customToolbarItemIdentifier]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [Self.customToolbarItemIdentifier]
    }

    func update(session: Session) {
        // Cancel any pending pagination task since user is navigating to a specific session
        // This prevents stale pagination from navigating away after session indices shift
        paginationTask?.cancel()
        paginationTask = nil

        self.initialSession = session
        self.selectionState.selectedSessionId = session.id
        self.selectionState.isCreatingNewSession = false

        // Update active session ID for polling - ensures this session is polled
        // even if completed, since it's actively being viewed
        dataManager.activeSessionId = session.id

        // PERFORMANCE: Preload diffs in background before view renders
        // This ensures diffs are in memory cache when the view accesses them
        DiffStorageManager.shared.preloadDiffs(forSession: session.id)

        if #available(macOS 26.0, *) {
             // For Tahoe, the View observes selectionState, so we might just need to ensure data is fresh.
             // No need to swap rootView.
        } else {
             let newView = AnyView(MainSessionView(session: session).environmentObject(dataManager))
             mainContentHostingController.rootView = newView
             updateToolbarView()
        }

        // Mark session as viewed when navigating to it
        dataManager.markSessionAsViewed(session)

        // Force load activities for this session if not already loaded
        dataManager.ensureActivities(for: session)
    }

    @objc func toggleSidebar(_ sender: Any?) {
        // Notify that sidebar animation is about to start - allows views to pause expensive work
        NotificationCenter.default.post(name: .sidebarAnimationWillStart, object: nil)

        if #available(macOS 26.0, *) {
            // Toggle state via the helper class
            tahoeState.toggle()
            // SwiftUI handles animation internally; post end notification after typical animation duration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                NotificationCenter.default.post(name: .sidebarAnimationDidEnd, object: nil)
            }
        } else {
            guard let firstItem = splitViewController.splitViewItems.first else {
                NotificationCenter.default.post(name: .sidebarAnimationDidEnd, object: nil)
                return
            }

            // Phase 1: Use NSAnimationContext with interruptible animation
            // This allows users to interrupt and reverse the animation mid-way
            NSAnimationContext.runAnimationGroup({ context in
                // Animation timing
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

                // CRITICAL: Allow user interaction during animation
                // This is essential for perceived responsiveness
                context.allowsImplicitAnimation = true

                // Toggle the collapsed state with animation
                firstItem.animator().isCollapsed.toggle()
            }, completionHandler: { [weak self] in
                // Persist collapsed state after animation completes
                self?.saveSidebarState()
                NotificationCenter.default.post(name: .sidebarAnimationDidEnd, object: nil)
            })
        }
    }

    func goToPreviousSession() {
        guard let currentSessionId = selectionState.selectedSessionId ?? initialSession?.id else { return }
        guard let currentIndex = dataManager.recentSessions.firstIndex(where: { $0.id == currentSessionId }),
              currentIndex > 0 else { return }

        let previousSession = dataManager.recentSessions[currentIndex - 1]

        // PERFORMANCE: Pre-warm adjacent sessions for smooth pagination
        preloadAdjacentSessionDiffs(around: currentIndex - 1)

        update(session: previousSession)
    }

    func goToNextSession() {
        // When creating a new session, navigate to the first existing session
        if selectionState.isCreatingNewSession {
            guard let firstSession = dataManager.recentSessions.first else { return }
            preloadAdjacentSessionDiffs(around: 0)
            update(session: firstSession)
            return
        }

        guard let currentSessionId = selectionState.selectedSessionId ?? initialSession?.id else { return }
        guard let currentIndex = dataManager.recentSessions.firstIndex(where: { $0.id == currentSessionId }) else { return }

        // If there's a next session in the loaded list, navigate to it
        if currentIndex < dataManager.recentSessions.count - 1 {
            let nextSession = dataManager.recentSessions[currentIndex + 1]

            // PERFORMANCE: Pre-warm adjacent sessions for smooth pagination
            preloadAdjacentSessionDiffs(around: currentIndex + 1)

            update(session: nextSession)
            return
        }

        // At the end of loaded sessions - check if more are available
        if dataManager.hasMoreSessions && !dataManager.isLoadingMoreForPagination {
            // Load more sessions and then navigate
            loadMoreSessionsAndNavigate(fromIndex: currentIndex, currentSessionId: currentSessionId)
        }
    }

    /// Loads more sessions from the API and navigates to the next one after loading
    private func loadMoreSessionsAndNavigate(fromIndex currentIndex: Int, currentSessionId: String) {
        // Cancel any existing pagination task to prevent stale navigation
        paginationTask?.cancel()

        dataManager.isLoadingMoreForPagination = true

        paginationTask = Task {
            await dataManager.loadMoreData()

            // Check if task was cancelled (user navigated away or created new session)
            guard !Task.isCancelled else {
                await MainActor.run {
                    dataManager.isLoadingMoreForPagination = false
                }
                return
            }

            await MainActor.run {
                dataManager.isLoadingMoreForPagination = false

                // Verify the user is still viewing the same session before auto-navigating
                // This prevents navigating away from a newly created session
                guard selectionState.selectedSessionId == currentSessionId else {
                    return
                }

                // After loading, find the current session's NEW index (may have shifted)
                let sessions = dataManager.recentSessions
                guard let newCurrentIndex = sessions.firstIndex(where: { $0.id == currentSessionId }) else {
                    return
                }

                // Navigate to the next session after the current one
                if newCurrentIndex < sessions.count - 1 {
                    let nextSession = sessions[newCurrentIndex + 1]

                    // PERFORMANCE: Pre-warm adjacent sessions for smooth pagination
                    preloadAdjacentSessionDiffs(around: newCurrentIndex + 1)

                    update(session: nextSession)
                }
            }
        }
    }

    /// Preload diffs for sessions adjacent to the given index for smoother pagination
    private func preloadAdjacentSessionDiffs(around index: Int) {
        var adjacentIds: [String] = []
        let sessions = dataManager.recentSessions

        // Preload 2 sessions before and after for smooth navigation
        for offset in -2...2 {
            let adjacentIndex = index + offset
            if adjacentIndex >= 0 && adjacentIndex < sessions.count && offset != 0 {
                adjacentIds.append(sessions[adjacentIndex].id)
            }
        }

        if !adjacentIds.isEmpty {
            DiffStorageManager.shared.preloadDiffs(forSessions: adjacentIds)
        }
    }

    func createNewSession() {
        // Cancel any pending pagination task to prevent it from navigating away
        // after the new session is created
        paginationTask?.cancel()
        paginationTask = nil
        dataManager.isLoadingMoreForPagination = false

        // Set state to creating new session
        selectionState.selectedSessionId = nil
        selectionState.isCreatingNewSession = true
        initialSession = nil

        if #available(macOS 26.0, *) {
            // For Tahoe, the View observes selectionState and will react
        } else {
            // Update the main content to show the new session form
            // MainSessionView handles nil session by showing the creation form
            let newSessionView = AnyView(
                MainSessionView(session: nil)
                    .environmentObject(dataManager)
            )
            mainContentHostingController.rootView = newSessionView
            updateToolbarView()
        }
    }

    // MARK: - Merge Conflict Window

    /// Opens the merge conflict resolution window
    /// The merge conflict view now lives in its own dedicated NSWindow with sidebar, toolbar,
    /// and pagination controls for navigating between conflicts across multiple files.
    @objc func openMergeConflictWindow() {
        if #available(macOS 14.0, *) {
            MergeConflictWindowManager.shared.openWindow(
                store: nil, // Uses test data
                onMergeComplete: { [weak self] in
                    // Handle merge completion - could refresh session or show success message
                    print("Merge completed successfully")
                }
            )
        }
    }

    /// Legacy method name for backwards compatibility
    @objc func toggleMergeConflictTest() {
        openMergeConflictWindow()
    }

    // MARK: - Sidebar State Restoration

    /// Sets up observer to save sidebar width when user resizes via divider drag
    private func setupSidebarStateObserver() {
        splitViewResizeObserver = NotificationCenter.default.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification,
            object: splitViewController.splitView,
            queue: .main
        ) { [weak self] _ in
            self?.saveSidebarState()
        }
    }

    /// Saves sidebar width and collapsed state to UserDefaults
    private func saveSidebarState() {
        guard let sidebarItem = splitViewController.splitViewItems.first else { return }

        // Only save width when sidebar is expanded
        if !sidebarItem.isCollapsed {
            let sidebarWidth = splitViewController.splitView.subviews.first?.frame.width ?? 0
            if sidebarWidth > 0 {
                UserDefaults.standard.set(Float(sidebarWidth), forKey: Self.sidebarWidthKey)
            }
        }
        UserDefaults.standard.set(sidebarItem.isCollapsed, forKey: Self.sidebarCollapsedKey)
    }

    /// Restores sidebar width from UserDefaults using constraint-compatible approach
    private func restoreSidebarState() {
        guard let sidebarItem = splitViewController.splitViewItems.first else { return }

        // Restore collapsed state
        let wasCollapsed = UserDefaults.standard.bool(forKey: Self.sidebarCollapsedKey)
        sidebarItem.isCollapsed = wasCollapsed

        // Restore width if we have a saved value and sidebar is expanded
        let savedWidth = UserDefaults.standard.float(forKey: Self.sidebarWidthKey)
        if savedWidth > 0 && !wasCollapsed {
            // Use setPosition to set initial sidebar width (Auto Layout compatible)
            // This respects min/max thickness constraints set on the item
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let clampedWidth = max(
                    sidebarItem.minimumThickness,
                    min(CGFloat(savedWidth), sidebarItem.maximumThickness)
                )
                self.splitViewController.splitView.setPosition(clampedWidth, ofDividerAt: 0)
            }
        }
    }

    // MARK: - NSWindowDelegate

    /// Ensures menu bar appears when window becomes main
    /// This is more reliable than setting activation policy before showWindow()
    func windowDidBecomeMain(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    deinit {
        // Clean up observer to prevent memory leaks
        if let observer = splitViewResizeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

}
