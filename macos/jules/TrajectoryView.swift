import SwiftUI

// MARK: - Deferred Activity View Wrapper
/// Wrapper that shows a lightweight placeholder, then loads ActivityView on next run loop
/// This reduces the initial view hierarchy creation time
struct DeferredActivityView: View {
    let session: Session?
    @State private var isLoaded = false
    @Environment(\.glassToolbarEnabled) private var glassToolbarEnabled

    var body: some View {
        Group {
            if isLoaded {
                ActivityView(session: session)
            } else {
                // Lightweight skeleton placeholder with progress in top right
                VStack {
                    HStack {
                        Spacer()
                        StyledProgressIndicator()
                            .padding(.trailing, 16)
                            .padding(.top, 12)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(glassToolbarEnabled ? Color.clear : AppColors.background)
            }
        }
        .onAppear {
            if !isLoaded {
                LoadingProfiler.shared.checkpoint("View: DeferredActivityView placeholder appeared")
                DispatchQueue.main.async {
                    LoadingProfiler.shared.checkpoint("View: DeferredActivityView isLoaded = true")
                    isLoaded = true
                }
            }
        }
    }
}

struct TrajectoryView: View {
    @EnvironmentObject var dataManager: DataManager
    @Environment(\.glassToolbarEnabled) private var glassToolbarEnabled

    /// The session to display. If nil, shows a new session creation view.
    let session: Session?

    // Add state to track if we should show the loader and if it's closing
    @State private var isLoaderClosing: Bool = false
    @State private var showLoader: Bool = false

    /// Token to track which closing animation is current, preventing stale callbacks
    @State private var loaderClosingToken: UUID?

    /// Incremented when diffs finish loading to trigger view refresh
    /// NOTE: This is accessed in diffPanelView to create a SwiftUI dependency without using .id()
    /// which would destroy and recreate the entire Metal diff panel
    @State private var diffsLoadedTrigger: Int = 0

    /// Tracks session IDs that have already shown the loader intro animation.
    /// When a user paginates away and back, we skip the intro (sky/sun/waves descent)
    /// and jump directly to the underwater scene with bubbles and fish.
    @State private var sessionsWithLoaderIntroShown: Set<String> = []

    /// PAGINATION FIX: Tracks the session ID that content was last rendered for.
    /// When this differs from the current session, we know we're in a pagination transition
    /// and should hide stale content immediately.
    @State private var lastRenderedSessionId: String?

    /// PAGINATION FIX: When true, indicates we're in a pagination transition and stale content
    /// should be hidden. This is set to true immediately when session changes and cleared
    /// once content for the new session is ready.
    private var isPaginationTransition: Bool {
        guard let session = session else { return false }
        return lastRenderedSessionId != nil && lastRenderedSessionId != session.id
    }

    // DEBUG: Track state update frequency
    private static var debugStateUpdateCount = 0
    private static var debugLastLogTime: CFTimeInterval = 0

    /// Whether the loader should actually be displayed.
    /// This is a computed property that checks both the showLoader state AND whether
    /// the current session actually needs a loader. This prevents the loader from
    /// briefly showing when navigating between sessions, since SwiftUI preserves
    /// @State values while the view body is recomputed before onChange fires.
    private var shouldDisplayLoader: Bool {
        guard showLoader else { return false }
        guard let session = liveSession else { return false }
        let isActivelyWorking = session.state == .queued || session.state == .planning || session.state == .inProgress
        let hasDiffs = session.hasDiffsAvailable
        return isActivelyWorking && !hasDiffs
    }

    private var liveSession: Session? {
        guard let session = session else { return nil }
        return dataManager.recentSessions.first { $0.id == session.id } ?? session
    }

    private var pullRequest: PullRequest? {
        liveSession?.outputs?.compactMap { $0.pullRequest }.first
    }

    /// Whether we're in create mode (no session)
    private var isCreateMode: Bool {
        session == nil
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Always use split view layout - even for new session creation
                // This provides a smooth transition when session data arrives
                SplitViewController(
                    viewA: {
                        if isCreateMode {
                            // No deferral needed for create mode - it's lightweight
                            ActivityView(session: nil)
                                .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            // OPTIMIZATION: Use deferred wrapper to reduce initial view hierarchy
                            DeferredActivityView(session: session)
                                .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                        }
                    },
                    viewB: {
                        diffPanelView
                    }
                )
            }
            .background(glassToolbarEnabled ? Color.clear : AppColors.background)

            // Loader overlay - positioned outside SplitViewController for reliable state updates
            // NOTE: Placed here instead of inside diffPanelView because state changes through
            // NSViewControllerRepresentable (SplitViewController) don't reliably trigger re-renders.
            // By keeping the loader at the TrajectoryView level, SwiftUI handles showLoader
            // state changes directly without going through the representable bridge.
            //
            // OPTIMIZATION: Use GeometryReader with explicit positioning instead of HStack/ZStack
            // with Color.clear. The previous layout could cause unnecessary layout recalculations
            // when the Metal animation updates, leading to a cascade of SwiftUI view updates.
            //
            // NOTE: Uses shouldDisplayLoader instead of showLoader to immediately hide the loader
            // when navigating between sessions. SwiftUI preserves @State values during view updates
            // and onChange fires AFTER body computation, so without this check the loader would
            // briefly flash when paginating or creating a new session.
            if shouldDisplayLoader {
                GeometryReader { geometry in
                    // Position loader in center of right half (diff panel area)
                    // Skip the intro animation if we've already shown the loader for this session
                    // (i.e., user paginated away and back)
                    DiffLoaderView(
                        isClosing: isLoaderClosing,
                        skipIntro: session.map { sessionsWithLoaderIntroShown.contains($0.id) } ?? false
                    )
                        .frame(width: 90, height: 200)
                        .cornerRadius(50)
                        // Animate the wrapper shrinking during close so the rounded rect visually shrinks
                        .scaleEffect(isLoaderClosing ? 0.01 : 1.0)
                        .opacity(isLoaderClosing ? 0.0 : 1.0)
                        .animation(.easeOut(duration: 1.0), value: isLoaderClosing)
                        .position(
                            x: geometry.size.width * 0.75,  // Center of right half
                            y: geometry.size.height / 2     // Vertically centered
                        )
                        .onAppear {
                            // Mark this session as having shown the loader intro
                            if let sessionId = session?.id {
                                sessionsWithLoaderIntroShown.insert(sessionId)
                            }
                        }
                }
                .allowsHitTesting(false)  // Don't intercept mouse events
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == "jules-file" {
                // Extract the filename from the URL host (percent-decoded)
                if let filename = url.host?.removingPercentEncoding,
                   let session = liveSession {
                    dataManager.scrollToDiffFile = (sessionId: session.id, filename: filename)
                }
                return .handled
            }
            return .systemAction
        })
        // NOTE: ensureActivities is now called earlier in DeferredSessionContentView
        // for better performance (gives API more time to fetch data)
        // IMPORTANT: Loader state observers are at TrajectoryView level (outside SplitViewController)
        // because SwiftUI lifecycle callbacks (onAppear/onChange) don't reliably fire for views
        // inside NSViewControllerRepresentable. The loader overlay is also here for the same reason.
        .onAppear {
            updateLoaderState()
        }
        .onChange(of: liveSession?.state) { _ in
            updateLoaderState()
        }
        .onChange(of: liveSession?.hasDiffsAvailable) { _ in
            updateLoaderState()
        }
        .onChange(of: session?.id) { newId in
            // Immediately hide loader when session changes - don't animate
            // The closing animation should only apply when the SAME session
            // transitions from "loading" to "has diffs", not when paginating
            // between sessions
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                showLoader = false
                isLoaderClosing = false
                loaderClosingToken = nil
            }
            diffsLoadedTrigger = 0
            updateLoaderState()

            // PAGINATION FIX: Update lastRenderedSessionId AFTER the current render cycle.
            // This ensures the first render after pagination shows the loading overlay
            // (because isPaginationTransition will be true). The next render will then
            // show the actual content (because lastRenderedSessionId will match session.id).
            // Using DispatchQueue.main.async defers the update to the next run loop.
            DispatchQueue.main.async {
                lastRenderedSessionId = newId
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .diffsDidLoad)) { notification in
            if let loadedSessionId = notification.userInfo?["sessionId"] as? String,
               loadedSessionId == session?.id {
                diffsLoadedTrigger += 1
                updateLoaderState()
            }
        }
    }

    @ViewBuilder
    private var diffPanelView: some View {
        // Access diffsLoadedTrigger to create a SwiftUI dependency that triggers re-evaluation
        // when diffs finish loading, WITHOUT using .id() which would destroy the Metal view
        let _ = diffsLoadedTrigger

        ZStack {
            // CRITICAL FIX: Always show UnifiedDiffPanel when we have a session to prevent
            // the Metal view from being destroyed and recreated during pagination.
            // This fixes flickering and pixelation during quick session navigation.
            //
            // The Metal view is expensive to create and when destroyed/recreated rapidly,
            // it can render with invalid bounds causing pixelated textures.

            if let session = liveSession {
                // CRITICAL: Only access latestDiffs when hasDiffsAvailable is true.
                // The latestDiffs property has side effects - it triggers preloadDiffs()
                // when diffs aren't in cache. If diffs don't exist (empty), this creates
                // an infinite loop because:
                // 1. preloadDiffs() caches empty result and posts .diffsDidLoad notification
                // 2. hasCachedDiffsInMemory() returns false for empty cache
                // 3. Next latestDiffs access triggers preloadDiffs() again
                // This caused ~1000 SwiftUI updates/sec when DiffLoader was showing.
                //
                // PAGINATION FIX: During pagination transition, pass empty diffs to immediately
                // clear the Metal view. This prevents showing stale content from previous session.
                // NOTE: Use ternary operator instead of if-else to avoid @ViewBuilder interpreting
                // the assignment as a View expression (which would cause "Type '()' cannot conform to 'View'" error)
                let diffs: [(patch: String, language: String?, filename: String?)] = isPaginationTransition
                    ? []  // Force empty during transition to clear stale content
                    : (session.hasDiffsAvailable ? (session.latestDiffs ?? []) : [])

                // Always show the diff panel - this keeps the Metal view alive
                UnifiedDiffPanel(
                    diffs: diffs,
                    sessionId: session.id,
                    scrollToFile: scrollToFileBinding(for: session)
                )
                .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                .onAppear {
                    if !diffs.isEmpty {
                        precomputeDiffsIfNeeded(sessionId: session.id, diffs: diffs)
                    }
                    // NOTE: lastRenderedSessionId is updated in the main body's onChange handler.
                    // Don't update it here to avoid potential double-updates and extra renders.
                }
                .onChange(of: diffs.count) { _ in
                    if !diffs.isEmpty {
                        precomputeDiffsIfNeeded(sessionId: session.id, diffs: diffs)
                    }
                }
                // NOTE: lastRenderedSessionId is updated in the main body's onChange(of: session?.id)
                // handler, not here, because SwiftUI lifecycle callbacks don't fire reliably
                // for views inside NSViewControllerRepresentable (SplitViewController).

                // Overlay loading/empty states based on session state and diff availability
                let isTerminalState = session.state.isTerminal
                let isActivelyWorking = session.state == .queued || session.state == .planning || session.state == .inProgress
                let activitiesLoaded = session.activities != nil

                // PAGINATION FIX: Show loading overlay immediately during pagination transition
                // This covers the gap before new content loads, preventing stale content visibility
                if isPaginationTransition {
                    VStack {
                        HStack {
                            Spacer()
                            StyledProgressIndicator()
                                .padding(.trailing, 16)
                                .padding(.top, 12)
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(glassToolbarEnabled ? Color.clear : AppColors.background)
                } else if !session.hasDiffsAvailable {
                    if isTerminalState {
                        if activitiesLoaded {
                            // Data is loaded and confirmed no diffs
                            Text("No diff to display.")
                                .padding()
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                                .background(glassToolbarEnabled ? Color.clear : AppColors.background)
                        } else {
                            // Still loading data for this terminal session
                            VStack {
                                HStack {
                                    Spacer()
                                    StyledProgressIndicator()
                                        .padding(.trailing, 16)
                                        .padding(.top, 12)
                                }
                                Spacer()
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(glassToolbarEnabled ? Color.clear : AppColors.background)
                        }
                    } else if !isActivelyWorking {
                        // Non-terminal, non-actively-working session without diffs (e.g., awaiting state)
                        // Show a loader while diffs may be loading
                        // Note: Actively working sessions show DiffLoaderView via shouldDisplayLoader
                        VStack {
                            HStack {
                                Spacer()
                                StyledProgressIndicator()
                                    .padding(.trailing, 16)
                                    .padding(.top, 12)
                            }
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(glassToolbarEnabled ? Color.clear : AppColors.background)
                    }
                    // Note: For actively working sessions, DiffLoaderView is shown via shouldDisplayLoader
                }
            } else if isCreateMode {
                // New session creation mode - no Metal view needed
                Color.clear
                    .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Fallback
                Color.clear
                    .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
            }
            // NOTE: Loader state observers have been moved to TrajectoryView.body (outside SplitViewController)
            // to ensure reliable state updates. SwiftUI lifecycle callbacks don't fire reliably
            // for views inside NSViewControllerRepresentable.
        }
    }

    /// Create a binding for scroll-to-file that works with the unified diff panel
    private func scrollToFileBinding(for session: Session) -> Binding<(sessionId: String, filename: String)?> {
        Binding(
            get: {
                if let target = dataManager.scrollToDiffFile, target.sessionId == session.id {
                    return target
                }
                return nil
            },
            set: { newValue in
                dataManager.scrollToDiffFile = newValue
            }
        )
    }

    private func updateLoaderState() {
        // DEBUG: Log update frequency
        let now = CACurrentMediaTime()
        TrajectoryView.debugStateUpdateCount += 1
        if now - TrajectoryView.debugLastLogTime >= 1.0 {
            print("[TrajectoryView] updateLoaderState calls/sec: \(TrajectoryView.debugStateUpdateCount), showLoader: \(showLoader)")
            TrajectoryView.debugStateUpdateCount = 0
            TrajectoryView.debugLastLogTime = now
        }

        guard let session = liveSession else {
            // OPTIMIZATION: Only update state if it would actually change
            // This prevents unnecessary SwiftUI view updates
            if showLoader {
                showLoader = false
                loaderClosingToken = nil
            }
            return
        }

        // Only show loader for sessions actively working (where Jules is generating diffs)
        // This excludes completed, failed, paused, and awaiting states - which covers
        // all historical sessions we might paginate to
        let isActivelyWorking = session.state == .queued || session.state == .planning || session.state == .inProgress
        let hasDiffs = session.hasDiffsAvailable
        let shouldShowLoader = isActivelyWorking && !hasDiffs

        if shouldShowLoader {
            // OPTIMIZATION: Only update state if values would actually change
            // This prevents unnecessary SwiftUI view updates that could cascade
            if loaderClosingToken != nil {
                loaderClosingToken = nil
            }
            if !showLoader {
                showLoader = true
            }
            if isLoaderClosing {
                isLoaderClosing = false
            }
        } else {
            // Hide loader - trigger closing animation if currently showing
            if showLoader && !isLoaderClosing {
                isLoaderClosing = true
                // Generate a token for this closing animation
                let token = UUID()
                loaderClosingToken = token
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    // Only hide if this is still the current closing animation
                    // This prevents stale callbacks from hiding a re-shown loader
                    if self.loaderClosingToken == token {
                        self.showLoader = false
                        self.isLoaderClosing = false
                        self.loaderClosingToken = nil
                    }
                }
            } else if !showLoader {
                // OPTIMIZATION: Only update state if values would actually change
                if isLoaderClosing {
                    isLoaderClosing = false
                }
                if loaderClosingToken != nil {
                    loaderClosingToken = nil
                }
            }
        }
    }

    /// Pre-compute all DiffResults and their layouts in background
    /// This eliminates the stall when scrolling to large diffs for the first time
    private func precomputeDiffsIfNeeded(sessionId: String, diffs: [(patch: String, language: String?, filename: String?)]) {
        let lineHeight = CGFloat(FontSizeManager.shared.diffLineHeight)
        DiffPrecomputationService.shared.precomputeAll(
            sessionId: sessionId,
            diffs: diffs,
            lineHeight: lineHeight
        )
    }

}

