import SwiftUI
import AppKit

struct ActivityView: View {
    @EnvironmentObject var dataManager: DataManager
    @ObservedObject private var fontSizeManager = FontSizeManager.shared

    /// The session to display. If nil, shows the new session creation view.
    let session: Session?

    @State private var messageText: String = ""
    @State private var messageAttachmentContent: String? = nil
    @State private var messageImageAttachment: NSImage? = nil

    /// Tracks whether we're in rapid pagination mode (animations should be disabled)
    /// When session changes, this is set to true and then reset after a short delay
    @State private var isRapidPagination: Bool = false

    /// Token to track rapid pagination reset - prevents stale resets
    @State private var rapidPaginationResetToken: UUID?

    /// PAGINATION FIX: Tracks the session ID that content was last rendered for.
    /// When this differs from the current session, we know we're in a pagination transition
    /// and should show loading state immediately.
    @State private var lastRenderedSessionId: String?

    /// Incremented when Gemini descriptions are updated for this session.
    /// This forces SwiftUI to re-evaluate computed properties that depend on descriptions.
    @State private var geminiDescriptionUpdateCounter: Int = 0

    /// Flag to indicate we should scroll to bottom when the session content finishes loading.
    /// Set to true when a session is loaded/navigated to, cleared after scrolling.
    /// Initialized to true so the first session shown also scrolls to bottom.
    @State private var shouldScrollToBottomOnLoad: Bool = true

    /// PAGINATION FIX: When true, indicates we're in a pagination transition and should
    /// show loading state to prevent stale content from being visible.
    private var isPaginationTransition: Bool {
        guard let session = session else { return false }
        return lastRenderedSessionId != nil && lastRenderedSessionId != session.id
    }

    /// Whether we're in create mode (no session)
    private var isCreateMode: Bool {
        session == nil
    }

    private var liveSession: Session? {
        guard let session = session else { return nil }
        // Find the session in the DataManager's recentSessions array that has the same ID.
        // If not found, fall back to the initial session passed in.
        return dataManager.recentSessions.first { $0.id == session.id } ?? session
    }

    /// Whether the session is still loading activity data (activities haven't been fetched yet)
    private var isLoadingActivities: Bool {
        // PAGINATION FIX: During pagination transition, always show loading state
        // to prevent stale content from previous session being visible.
        if isPaginationTransition {
            return true
        }

        guard let session = liveSession else { return false }
        // Activities being nil means data hasn't been loaded yet
        // This is different from an empty array which means data was loaded but no activities exist
        // Only show loading indicator for terminal sessions (completed/failed/paused/completedUnknown)
        // Active sessions show status in the sticky bar, so no loader needed
        let isActiveSession = !session.state.isTerminal
        return session.activities == nil && !isActiveSession
    }

    /// Whether to show the progress view at the bottom
    private var shouldShowProgressView: Bool {
        guard let _ = liveSession else { return false }
        // Always show progress view - it handles both active states (spinner + phrases)
        // and completed/failed states (checkmark/X + status text)
        return true
    }

    /// A value that changes when either session state or progress updates change.
    /// Used to trigger animations and scroll updates.
    private var progressUpdateTrigger: String {
        guard let session = liveSession else { return "" }
        let stateString = session.state.rawValue
        let progressTitle = session.latestProgressTitle ?? ""
        let updateTime = session.updateTime ?? ""
        return "\(stateString)-\(progressTitle)-\(updateTime)"
    }

    /// Returns all activities (including completed progress) sorted chronologically.
    /// This interleaves messages, plans, and progress updates in true chronological order.
    /// Note: Includes defensive deduplication to handle any duplicate IDs in the data.
    private var displayableActivities: [Activity] {
        guard let session = liveSession, let activities = session.activities else { return [] }

        // Get the ID of the latest progress activity (to exclude from the list - shown separately)
        let latestProgressActivityId: String? = {
            let progressActivities = activities
                .filter { $0.progressUpdated != nil }
                .sorted { ($0.createTime ?? "") < ($1.createTime ?? "") }
            return progressActivities.last?.id
        }()

        // Include all activities EXCEPT the latest progress activity (shown at bottom)
        // Sort by createTime to ensure activities appear in chronological order
        let filtered = activities
            .filter { activity in
                // Exclude the latest progress activity (it's shown separately at the bottom)
                activity.id != latestProgressActivityId
            }
            .sorted { ($0.createTime ?? "") < ($1.createTime ?? "") }

        // Defensive deduplication: ensure unique IDs to prevent SwiftUI ForEach errors
        // Keep the last occurrence of each ID (most recent data)
        var seenIds = Set<String>()
        return filtered.reversed().filter { activity in
            if seenIds.contains(activity.id) {
                return false
            }
            seenIds.insert(activity.id)
            return true
        }.reversed()
    }

    /// A value that changes when generatedDescriptions are loaded.
    /// This helps trigger view updates when Gemini finishes processing.
    /// Includes the update counter to ensure refresh when publisher notifies us.
    private var generatedDescriptionsTrigger: String {
        // Track generated descriptions for progress activities within displayableActivities
        let progressActivitiesWithDescriptions = displayableActivities
            .filter { $0.progressUpdated != nil }
            .compactMap { $0.generatedDescription }
            .joined(separator: "|")
        // Include counter to force re-evaluation when Gemini publisher fires
        return "\(displayableActivities.count)-\(progressActivitiesWithDescriptions.hashValue)-\(geminiDescriptionUpdateCounter)"
    }

    var body: some View {
        VStack(spacing: 0) {
            if isCreateMode {
                // Empty view with just the input at the bottom
                // The split view provides visual context (diff panel on right)
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        HStack {
                            Spacer()
                            StickyStatusView(session: nil)
                            Spacer()
                        }
                    }
            } else {
                chatHistoryView
            }

            messageInputView
                .padding(.top, 12)
        }
        .background(AppColors.background)
        // NOTE: ensureActivities is now called earlier in DeferredSessionContentView
        // for better performance (gives API more time to fetch data)
        // Reset state when session changes - necessary since we don't use .id() on parent views
        // to avoid destroying NSViewRepresentables (Metal views, text editors)
        .onChange(of: session?.id) { newId in
            // OPTIMIZATION: Set rapid pagination flag to disable animations during fast navigation.
            // This prevents animation stacking/stuttering when quickly paginating between sessions.
            // The flag is reset after a short delay once the user settles on a session.
            isRapidPagination = true
            let token = UUID()
            rapidPaginationResetToken = token

            // Re-enable animations after settling on a session (300ms threshold)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                // Only reset if this is still the current token (prevents stale resets)
                if rapidPaginationResetToken == token {
                    isRapidPagination = false
                }
            }

            // PAGINATION FIX: Update lastRenderedSessionId AFTER the current render cycle.
            // This ensures the first render after pagination shows the loading indicator
            // (because isPaginationTransition will be true). The next render will then
            // show the actual content (because lastRenderedSessionId will match session.id).
            DispatchQueue.main.async {
                lastRenderedSessionId = newId
            }

            // Scroll to bottom when session content loads - most recent activity is at bottom
            shouldScrollToBottomOnLoad = true

            // Defer state updates to next run loop to prevent multiple updates per frame
            // when quickly paginating through sessions
            Task { @MainActor in
                // Clear any in-progress message state when switching sessions
                messageText = ""
                messageAttachmentContent = nil
                messageImageAttachment = nil
            }
        }
        // Subscribe to Gemini description updates for real-time view refresh
        // When descriptions are generated for this session, increment counter to force re-render
        .onReceive(dataManager.geminiDescriptionsUpdatedPublisher) { updatedSessionId in
            if updatedSessionId == session?.id {
                geminiDescriptionUpdateCounter += 1
            }
        }
    }

    // MARK: - New Session Header

    private var newSessionHeaderView: some View {
        VStack {
            Spacer()

            VStack(spacing: 12) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 48))
                    .foregroundColor(AppColors.accent)

                Text("New Session")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary)

                Text("Describe the task and Jules will get to work")
                    .font(.system(size: 14))
                    .foregroundColor(AppColors.textSecondary)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Subviews

    private var chatHistoryView: some View {
        ScrollView {
            ScrollViewReader { proxy in
                if isLoadingActivities {
                    // Empty placeholder when loading - progress indicator shown via safeAreaInset
                    Color.clear
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    chatContentView
                        .onChange(of: displayableActivities.count) { _ in
                            scrollToBottom(proxy: proxy)
                        }
                        .onChange(of: progressUpdateTrigger) { _ in
                            scrollToBottomOnProgress(proxy: proxy)
                        }
                        .onChange(of: dataManager.isSendingMessage) { isSending in
                            // Scroll to bottom immediately when user posts a message
                            // This ensures the user sees their message appear at the bottom
                            if isSending {
                                scrollToBottom(proxy: proxy)
                            }
                        }
                        .onAppear {
                            // Scroll to bottom when session content first appears after loading
                            // This ensures the most recent activity is visible when navigating to a session
                            if shouldScrollToBottomOnLoad {
                                // Use a slight delay to ensure the view has finished laying out
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                    scrollToBottom(proxy: proxy)
                                    shouldScrollToBottomOnLoad = false
                                }
                            }
                        }
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                // Centered StickyStatusView
                HStack {
                    Spacer()
                    if let session = liveSession {
                        StickyStatusView(session: session)
                    }
                    Spacer()
                }

                // Top-right progress indicator
                if isLoadingActivities {
                    StyledProgressIndicator()
                        .padding(.trailing, 16)
                        .padding(.top, 12)
                }
            }
        }
    }

    private var chatContentView: some View {
        let activityIds = displayableActivities.map(\.id)
        return VStack(alignment: .leading, spacing: 20) {
            activitiesListView
            // Progress activities are now interleaved in activitiesListView
            currentProgressView
        }
        // OPTIMIZATION: Disable animations during rapid pagination to prevent
        // animation stacking/stuttering when quickly navigating between sessions.
        // Only animate when user is viewing a single session for a moment.
        .animation(isRapidPagination ? nil : .spring(response: 0.4, dampingFraction: 0.8), value: activityIds)
        .animation(isRapidPagination ? nil : .spring(response: 0.3, dampingFraction: 0.8), value: progressUpdateTrigger)
        .animation(isRapidPagination ? nil : .easeInOut(duration: 0.2), value: generatedDescriptionsTrigger)
        .padding(.horizontal)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .padding(.leading, 8)
        .padding(.trailing, 8)
    }

    private var activitiesListView: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Show the session prompt at the start
            if let session = liveSession {
                ActivityPromptView(prompt: session.prompt)
            }

            ForEach(displayableActivities) { activity in
                activityItemView(for: activity)
            }
        }
    }

    @ViewBuilder
    private func activityItemView(for activity: Activity) -> some View {
        if let userMessage = activity.userMessaged?.userMessage {
            ActivityMessageView(message: userMessage, originator: "user")
                .id(activity.id)
        } else if let agentMessage = activity.agentMessaged?.agentMessage {
            ActivityMessageView(message: agentMessage, originator: "agent")
                .id(activity.id)
        } else if let plan = activity.planGenerated?.plan {
            ActivityPlanView(plan: plan)
                .id(activity.id)
                .padding(.bottom, 8)
        } else if let progressTitle = activity.progressUpdated?.title {
            // Render completed progress activities inline (interleaved with messages)
            ActivityProgressCompletedView(
                title: progressTitle,
                description: activity.progressUpdated?.description ?? "",
                generatedDescription: activity.generatedDescription,
                generatedTitle: activity.generatedTitle
            )
            .id("completed-progress-\(activity.id)-\(activity.generatedDescription != nil)-\(activity.generatedTitle != nil)")
        }

        if let artifacts = activity.artifacts {
            artifactsView(for: artifacts, activityId: activity.id)
        }
    }

    private func artifactsView(for artifacts: [Artifact], activityId: String) -> some View {
        ForEach(Array(artifacts.enumerated()), id: \.offset) { index, artifact in
            if let bashOutput = artifact.bashOutput {
                ActivityBashOutputView(bashOutput: bashOutput)
                    .id("\(activityId)-artifact-\(index)")
            }
        }
    }

    // completedProgressListView removed - progress activities are now interleaved in activitiesListView

    @ViewBuilder
    private var currentProgressView: some View {
        if shouldShowProgressView, let session = liveSession {
            ActivityProgressView(session: session)
                .id("progress-view")
        }
    }

    private var messageInputView: some View {
        UnifiedMessageInputView(
            session: liveSession,
            messageText: $messageText,
            attachmentContent: $messageAttachmentContent,
            imageAttachment: $messageImageAttachment
        )
        .padding(8)
    }

    // MARK: - Helper Methods

    private func scrollToBottom(proxy: ScrollViewProxy) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            if shouldShowProgressView {
                proxy.scrollTo("progress-view", anchor: .bottom)
            } else if let id = displayableActivities.last?.id {
                proxy.scrollTo(id, anchor: .bottom)
            }
        }
    }

    private func scrollToBottomOnProgress(proxy: ScrollViewProxy) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            if shouldShowProgressView {
                proxy.scrollTo("progress-view", anchor: .bottom)
            }
        }
    }
}
