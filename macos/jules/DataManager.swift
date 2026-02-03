import SwiftUI
import Combine
import AppKit

extension Notification.Name {
    static let didReceiveNewApiNotifications = Notification.Name("didReceiveNewApiNotifications")
}

/// Determines where the menu appears when triggered
enum MenuLaunchPosition: String, CaseIterable {
    case menuBar = "menuBar"      // Traditional dropdown from menu bar
    case centerScreen = "centerScreen"  // Centered floating panel on screen

    var displayName: String {
        switch self {
        case .menuBar:
            return "Menu Bar"
        case .centerScreen:
            return "Center of Screen"
        }
    }
}

@MainActor
class DataManager: ObservableObject {

    let sessionCreatedPublisher = PassthroughSubject<Session?, Never>()
    // --- UserDefaults Keys ---
    private let lastUsedSourceIdKey = "lastUsedSourceId"
    private let lastUsedBranchKey = "lastUsedBranch"
    private let lastUsedBranchesPerSourceKey = "lastUsedBranchesPerSource"
    private let apiKeyKey = "julesApiKey"
    private let isPopoverExpandedKey = "isPopoverExpanded"
    private let localRepoPathsKey = "localRepoPathsKey"
    private let menuLaunchPositionKey = "menuLaunchPosition"
    private let viewedMessagesKey = "viewedMessages"

    // --- Autocomplete Cache State ---
    /// Track which session IDs have already had their diffs processed for autocomplete
    /// Limited to maxTrackingSetSize to prevent unbounded memory growth
    private var processedSessionDiffIds: Set<String> = []

    // --- Diff Preloading State ---
    /// Track which session IDs have already been queued for diff preloading
    /// Limited to maxTrackingSetSize to prevent unbounded memory growth
    private var preloadedSessionDiffIds: Set<String> = []

    /// Maximum size for tracking sets before they are pruned
    /// This prevents unbounded memory growth from accumulating session IDs
    private let maxTrackingSetSize = 100

    // --- Rate Limiting ---
    // Minimum time between activity polls for the same session (matches active session poll interval)
    private let minActivityPollInterval: TimeInterval = 15.0
    private let rateLimiter = RateLimiter(maxRequests: 100, windowDuration: 60, warningThreshold: 75)

    // Track sessions currently being fetched to prevent duplicate requests
    // Exposed via isLoadingActivities(for:) for UI loading state
    @Published private(set) var inFlightActivityFetches: Set<String> = []

    // Track sessions currently having Gemini descriptions processed
    // This allows the view to show immediately while descriptions load in background
    private var inFlightGeminiProcessing: Set<String> = []

    // --- Gemini Processing Throttling ---
    // Limits the number of concurrent Gemini processing tasks across all sessions
    // to avoid overwhelming the Gemini API with too many parallel requests
    // Uses PriorityAsyncSemaphore to prioritize the currently viewed session
    private let geminiProcessingSemaphore = PriorityAsyncSemaphore(limit: 2)

    // Publisher to notify views when Gemini descriptions are updated for a session
    // Views can subscribe to this to refresh when descriptions become available
    let geminiDescriptionsUpdatedPublisher = PassthroughSubject<String, Never>()

    /// Check if activities are currently being loaded for a session
    func isLoadingActivities(for sessionId: String) -> Bool {
        return inFlightActivityFetches.contains(sessionId)
    }

    // --- Offline Support ---
    private let networkMonitor = NetworkMonitor.shared
    private var sourceRepository: SourceRepository!
    private(set) var offlineSyncManager: OfflineSyncManager!

    /// Whether the device is currently connected to the network
    @Published var isOnline: Bool = true

    /// Number of pending sessions waiting to be synced
    @Published var pendingSessionCount: Int = 0

    /// Whether pending sessions are currently being synced
    @Published var isSyncingPendingSessions: Bool = false

    // --- Published Properties ---
    @Published var sources: [Source] = []

    // Indicates when rate limiting is causing a delay
    @Published var isThrottlingActivities: Bool = false

    // Sessions are now managed by Repository
    // However, for compatibility with existing views, we expose them here.
    @Published var sessions: [Session] = []
    @Published var recentSessions: [Session] = []

    // Dictionary for O(1) session lookups by ID (updated automatically when sessions change)
    private(set) var sessionsById: [String: Session] = [:]

    @Published var isLoadingSources: Bool = false
    @Published var isLoadingSessions: Bool = false
    @Published var isCreatingSession: Bool = false
    @Published var isSendingMessage: Bool = false

    // To track the session currently open in the main window
    @Published var activeSessionId: String? = nil

    /// Returns true if the most recent session is completed but not yet viewed
    var hasUnviewedCompletedSession: Bool {
        guard let firstSession = sessions.first else { return false }
        return firstSession.isUnviewedCompleted
    }

    /// Returns the count of sessions that are completed but not yet viewed
    var unviewedCompletedSessionCount: Int {
        return sessions.filter { $0.isUnviewedCompleted }.count
    }

    // Navigation target for scrolling to a specific file in the diff view
    // Tuple of (sessionId, filename) - set when user clicks a filename in markdown
    @Published var scrollToDiffFile: (sessionId: String, filename: String)? = nil

    // Pagination State (now driven by Repository's syncState)
    @Published var syncState: SyncState = .idle
    @Published var hasMoreSessions = true // Derived from SyncState or Repo

    /// Set to true when loading more sessions triggered by toolbar pagination
    /// This allows the toolbar to show a progress view while loading
    @Published var isLoadingMoreForPagination: Bool = false

    var isFetchingNextPage: Bool {
        syncState == .loading
    }

    // API Keys
    @Published var apiKey: String = "" {
        didSet {
            let wasEmpty = oldValue.isEmpty
            let isNowFilled = !apiKey.isEmpty
            let keyChanged = oldValue != apiKey

            UserDefaults.standard.set(apiKey, forKey: apiKeyKey)
            apiService.apiKey = apiKey

            // Clear all caches when switching users (API key changed from non-empty to different value)
            // This ensures the new user starts with a blank slate
            if !wasEmpty && keyChanged {
                print("[DataManager] API key changed - clearing all caches for fresh start")
                Task {
                    let result = await CacheManager.shared.clearAllCaches()
                    if !result.success {
                        print("[DataManager] Warning: Cache clearing had errors: \(result.error ?? "unknown")")
                    }
                }
            }

            if !apiKey.isEmpty {
                fetchSources()
                Task { await fetchSessions() }
            }

            // Request permissions automatically when API key is added for the first time
            if wasEmpty && isNowFilled {
                requestPermissionsAfterSetup()
            }
        }
    }

    // Form State
    @Published var selectedSourceId: String? {
        didSet {
            if oldValue != selectedSourceId {
                // Defer to next run loop to avoid modifying @Published during view update
                DispatchQueue.main.async { [weak self] in
                    self?.selectedBranchName = nil
                    if let sourceId = self?.selectedSourceId {
                        self?.preselectLastUsedBranch(for: sourceId)
                    }
                }
            }
        }
    }
    @Published var selectedBranchName: String?
    @Published var promptText: String = ""
    @Published var draftAttachmentContent: String? = nil
    @Published var draftImageAttachment: NSImage? = nil

    @Published var isPopoverExpanded: Bool = false {
        didSet {
            UserDefaults.standard.set(isPopoverExpanded, forKey: isPopoverExpandedKey)
        }
    }

    @Published var menuLaunchPosition: MenuLaunchPosition = .menuBar {
        didSet {
            UserDefaults.standard.set(menuLaunchPosition.rawValue, forKey: menuLaunchPositionKey)
        }
    }

    // --- Computed Properties ---
    var branchesForSelectedSource: [GitHubBranch] {
        guard let sourceId = selectedSourceId,
              let selectedSource = sources.first(where: { $0.id == sourceId }),
              let repo = selectedSource.githubRepo
        else { return [] }
        return repo.branches ?? []
    }

    var settingsURL: URL? { APIService.settingsURL }

    var repositories: [Source] {
        let sourceNamesInSessions = Set(sessions.compactMap { $0.sourceContext?.source })
        return sources.filter { sourceNamesInSessions.contains($0.name) }
    }

    // --- Dependencies ---
    private let sessionRepository: SessionRepository
    private let apiService = APIService()
    nonisolated(unsafe) private var pollingController: SessionPollingController?
    private let mergeManager = LocalMergeManager()

    // Helper to access LoadingProfiler's memory profiling flag
    private var isMemoryProfilingEnabled: Bool {
        LoadingProfiler.memoryProfilingEnabled
    }


    private var cancellables: Set<AnyCancellable> = []
    /// Tracks which activity IDs have had notifications sent, per session.
    /// Persisted to UserDefaults to prevent duplicate notifications after app restart.
    /// Limited to maxViewedMessagesSessions to prevent unbounded memory growth.
    private var viewedMessages: [String: Set<String>] = [:] {
        didSet {
            pruneViewedMessagesIfNeeded()
            persistViewedMessages()
        }
    }

    /// Maximum number of sessions to track in viewedMessages before pruning
    private let maxViewedMessagesSessions = 200

    // --- Init ---
    init() {
        let profiler = LoadingProfiler.shared
        profiler.beginSpan("Data: DataManager.init")

        let savedApiKey = UserDefaults.standard.string(forKey: apiKeyKey) ?? ""
        let savedIsPopoverExpanded = UserDefaults.standard.bool(forKey: isPopoverExpandedKey)
        let savedMenuLaunchPosition = UserDefaults.standard.string(forKey: menuLaunchPositionKey)
            .flatMap { MenuLaunchPosition(rawValue: $0) } ?? .menuBar

        // Load persisted viewed messages to prevent duplicate notifications
        self.viewedMessages = Self.loadViewedMessages()

        self.apiKey = savedApiKey
        self.isPopoverExpanded = savedIsPopoverExpanded
        self.menuLaunchPosition = savedMenuLaunchPosition

        apiService.apiKey = savedApiKey
        profiler.checkpoint("Data: UserDefaults loaded")

        // Initialize Repository
        profiler.beginSpan("Data: InitializeRepositories")
        self.sessionRepository = SessionRepository(dbQueue: AppDatabase.shared, apiService: apiService)
        self.pollingController = SessionPollingController(sessionRepository: self.sessionRepository, dataManager: self)

        // Initialize offline support components
        self.sourceRepository = SourceRepository(dbQueue: AppDatabase.shared, apiService: apiService)
        self.offlineSyncManager = OfflineSyncManager(
            dbQueue: AppDatabase.shared,
            apiService: apiService,
            sourceRepository: sourceRepository,
            networkMonitor: networkMonitor
        )
        profiler.endSpan("Data: InitializeRepositories")

        profiler.beginSpan("Data: SetupSubscriptions")
        setupSubscriptions()
        setupOfflineSubscriptions()
        profiler.endSpan("Data: SetupSubscriptions")

        profiler.endSpan("Data: DataManager.init")

        // Defer initial data fetching to allow UI to appear faster
        // This runs on the next run loop after init completes
        if !self.apiKey.isEmpty {
            Task { @MainActor in
                // Small delay to let the app finish launching and UI to render
                try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
                profiler.beginSpan("Data: InitialDataFetch")
                // Only fetch sources from API if we don't have cached data
                // When user clicks repo/branch dropdown, we'll refresh from API
                if self.sources.isEmpty {
                    fetchSources()
                }
                await fetchSessions()
                profiler.endSpan("Data: InitialDataFetch")
                startPolling()
            }
        }
    }

    deinit {
        stopPolling()
        cancellables.forEach { $0.cancel() }
    }

    private func setupSubscriptions() {
        // Subscribe to sessions
        // NOTE: SessionRepository already applies .removeDuplicates() to prevent
        // emitting identical session arrays. This provides defense-in-depth by
        // checking if the actual data has changed before updating @Published properties.
        sessionRepository.sessionsPublisher
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] sessions in
                guard let self = self else { return }

                // OPTIMIZATION: Skip update if sessions haven't actually changed.
                // This prevents triggering objectWillChange (and thus SwiftUI re-renders)
                // when GRDB emits identical data. We compare by ID, state, updateTime,
                // and activity count - these are the fields that affect UI updates.
                // NOTE: Activity count is critical because activities can change while
                // session state remains "running" - without this, ActivityView won't update.
                let newSessionsKey = sessions.map { "\($0.id):\($0.state):\($0.updateTime ?? ""):\($0.activities?.count ?? 0)" }.joined()
                let oldSessionsKey = self.sessions.map { "\($0.id):\($0.state):\($0.updateTime ?? ""):\($0.activities?.count ?? 0)" }.joined()
                guard newSessionsKey != oldSessionsKey else {
                    return
                }

                // Fast path: if no existing sessions, skip all merge logic
                // This avoids creating dictionaries and mapping arrays unnecessarily
                let mergedSessions: [Session]
                var newlyCompletedSessionIds: [String] = []

                if self.sessions.isEmpty {
                    // No existing sessions - use incoming directly without copying
                    mergedSessions = sessions
                } else {
                    // Detect sessions that just transitioned to completed
                    let oldSessionsMap = Dictionary(self.sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

                    for session in sessions {
                        if let oldSession = oldSessionsMap[session.id] {
                            if oldSession.state != .completed && session.state == .completed {
                                newlyCompletedSessionIds.append(session.id)
                            }
                        }
                    }

                    // CRITICAL FIX: Merge incoming sessions with existing data, preserving
                    // activities from whichever source has more. This prevents a race condition
                    // where GRDB emissions from sessionRepository.refresh() (which preserves
                    // existing activities) can arrive AFTER fetchActivities() has already
                    // updated the local cache with newer data via updateLocalSessionCache().
                    // Without this merge, stale GRDB emissions would overwrite fresh activities.
                    var merged = sessions.map { incomingSession -> Session in
                        guard let existingSession = oldSessionsMap[incomingSession.id] else {
                            return incomingSession
                        }
                        // If existing session has more activities, preserve them
                        let existingCount = existingSession.activities?.count ?? 0
                        let incomingCount = incomingSession.activities?.count ?? 0
                        if existingCount > incomingCount {
                            var mergedSession = incomingSession
                            mergedSession.activities = existingSession.activities
                            mergedSession.lastActivityPollTime = existingSession.lastActivityPollTime
                            return mergedSession
                        }
                        return incomingSession
                    }

                    // CRITICAL FIX: Preserve sessions that exist locally but aren't in the
                    // GRDB emission. This handles the race condition where:
                    // 1. A new session is created and synchronously added to recentSessions
                    // 2. A stale GRDB ValueObservation emission arrives (from before the write)
                    // 3. Without this fix, the stale emission would overwrite recentSessions,
                    //    removing the newly created session and causing navigation issues.
                    // We insert missing local sessions at their original positions to maintain order.
                    let incomingSessionIds = Set(sessions.map { $0.id })
                    for (index, existingSession) in self.sessions.enumerated() {
                        if !incomingSessionIds.contains(existingSession.id) {
                            // Session exists locally but not in GRDB emission - preserve it
                            // Insert at original index or at end if index is out of bounds
                            let insertIndex = min(index, merged.count)
                            merged.insert(existingSession, at: insertIndex)
                            print("[DataManager.setupSubscriptions] Preserved locally-added session '\(existingSession.id.prefix(8))' not in GRDB emission")
                        }
                    }

                    mergedSessions = merged
                }

                self.sessions = mergedSessions
                self.recentSessions = mergedSessions

                // Update the sessionsById dictionary for O(1) lookups
                self.sessionsById = Dictionary(mergedSessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

                // Populate filename cache from session diffs for autocomplete
                self.updateFilenameCacheFromSessions(mergedSessions)

                // PERFORMANCE: Preload diffs for recent sessions in background
                // This ensures diffs are ready when user navigates to recent sessions
                self.preloadRecentSessionDiffs(sessions: mergedSessions)

                if !newlyCompletedSessionIds.isEmpty {
                    Task {
                        await self.fetchActivities(for: newlyCompletedSessionIds)
                    }
                }
            })
            .store(in: &cancellables)

        // Subscribe to sync state (with deduplication to prevent redundant updates)
        sessionRepository.$syncState
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.syncState = state
            }
            .store(in: &cancellables)

        sessionRepository.$syncState
            .map { state in
                if case .loadedAll = state { return false }
                return true
            }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] hasMore in
                self?.hasMoreSessions = hasMore
            }
            .store(in: &cancellables)

        // Map sync state to isLoadingSessions for legacy compatibility (if needed)
        sessionRepository.$syncState
            .map { $0 == .loading }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isLoading in
                self?.isLoadingSessions = isLoading
            }
            .store(in: &cancellables)

        // Listen for cache clearing notification (e.g., when user clears cache or switches accounts)
        NotificationCenter.default.publisher(for: .clearInMemoryCaches)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.clearInMemoryData()

                // Immediately fetch fresh data after clearing cache
                // This ensures the UI shows current data rather than being empty
                if !self.apiKey.isEmpty {
                    self.fetchSources()
                    Task {
                        await self.fetchSessions(bypassRateLimit: true)
                    }
                }
            }
            .store(in: &cancellables)
    }

    private func setupOfflineSubscriptions() {
        // Subscribe to network connectivity changes
        // Add removeDuplicates to prevent redundant SwiftUI updates
        networkMonitor.$isConnected
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isConnected in
                self?.isOnline = isConnected
            }
            .store(in: &cancellables)

        // Subscribe to source repository updates
        sourceRepository.sourcesPublisher
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { [weak self] sources in
                    guard let self = self else { return }
                    self.sources = sources
                    self.restoreSelection()
                }
            )
            .store(in: &cancellables)

        // Subscribe to source repository loading state
        sourceRepository.$isLoading
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isLoading in
                self?.isLoadingSources = isLoading
            }
            .store(in: &cancellables)

        // Subscribe to pending session count
        offlineSyncManager.$pendingSessionCount
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] count in
                self?.pendingSessionCount = count
            }
            .store(in: &cancellables)

        // Subscribe to syncing state
        offlineSyncManager.$isSyncing
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isSyncing in
                self?.isSyncingPendingSessions = isSyncing
            }
            .store(in: &cancellables)

        // When connectivity is restored, refresh data
        networkMonitor.connectivityRestoredPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self = self else { return }
                print("🌐 Connectivity restored - refreshing data")
                self.fetchSources()
                Task { await self.fetchSessions() }
            }
            .store(in: &cancellables)

        // When a pending session is synced, refresh sessions to show it in the list.
        // NOTE: We intentionally do NOT call sessionCreatedPublisher here.
        // The old code used getNewestSession() which caused a race condition:
        // if the user was creating a new session at the same time, getNewestSession()
        // might return a different session (the one being created or another recent one),
        // causing the UI to navigate to the wrong session.
        // The synced session will appear in the sidebar list - the user can click it if desired.
        offlineSyncManager.sessionSyncedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self = self else { return }
                Task {
                    // Bypass rate limit to ensure we get the newly synced session in the list
                    await self.fetchSessions(isRefresh: true, bypassRateLimit: true)
                }
            }
            .store(in: &cancellables)
    }

    // --- Permission Requests ---
    /// Requests permissions for notifications and launch at login
    func askForPermissions() {
        // Request notification permissions
        NotificationManager.shared.requestAuthorization()

        // Request launch at login
        Task {
            do {
                try await LaunchAtLoginManager.shared.enable()
                print("✅ Launch at login enabled automatically")
            } catch {
                print("⚠️ Could not enable launch at login: \(error.localizedDescription)")
            }
        }
    }

    /// Requests permissions automatically after API key setup
    private func requestPermissionsAfterSetup() {
        askForPermissions()
    }

    // --- Polling ---
    func startPolling() {
        pollingController?.startPolling()
    }

    nonisolated func stopPolling() {
        pollingController?.stopPolling()
    }

    @MainActor
    func fetchActivities(for sessionIds: [String]) async {
        let profiler = LoadingProfiler.shared

        // Filter out sessions that don't need activity fetching
        // Completed sessions with cached git stats don't need re-fetching
        // BUT always allow fetching for the currently active/viewed session
        let sessionsNeedingFetch = sessionIds.filter { sessionId in
            // Always fetch for the active session being viewed
            if sessionId == self.activeSessionId { return true }
            guard let session = self.sessionsById[sessionId] else { return true }
            return session.needsActivityFetchForStats
        }

        // Skip if no sessions need fetching
        guard !sessionsNeedingFetch.isEmpty else { return }

        // Log diff cache state before fetching to help debug memory spikes
        DiffStorageManager.shared.logCacheMemory("before fetch")

        profiler.startMemoryTrace("fetchActivities(\(sessionsNeedingFetch.count) sessions)")

        // Record rate limiting for each request we're about to make
        for _ in sessionsNeedingFetch {
            await rateLimiter.recordRequest()
        }

        profiler.startMemoryTrace("API fetch activities")
        let results = await apiService.fetchActivities(sessionIds: sessionsNeedingFetch)
        profiler.endMemoryTrace("API fetch activities")

        let pollTime = Date()

        for (sessionId, result) in results {
            switch result {
            case .success(let fetchResult):
                // MEMORY FIX: Hash-based cache validation in APIService skips JSON decoding
                // (~29MB) when response data is unchanged. This is checked BEFORE decoding,
                // so we never allocate memory for unchanged activity data.
                switch fetchResult {
                case .unchanged:
                    // API response data hash unchanged - JSON decoding was skipped entirely
                    // No memory was allocated for activity objects
                    if isMemoryProfilingEnabled {
                        print("🧠 [MemoryFix] Session \(sessionId.prefix(8)): response hash unchanged, skipped JSON decoding")
                    }
                    continue

                case .activities(let activities):
                    // New or changed activities - process normally
                    guard var sessionToUpdate = self.sessions.first(where: { $0.id == sessionId }) else {
                        continue
                    }

                    if isMemoryProfilingEnabled {
                        print("🧠 [MemoryDebug] Session \(sessionId.prefix(8)): processing \(activities.count) activities (response changed)")
                    }

                    // DEBUG: Log heavy data sizes only for sessions we're actually processing
                var mediaBytes = 0
                var bashBytes = 0
                var patchBytes = 0
                for activity in activities {
                    for artifact in activity.artifacts ?? [] {
                        if let media = artifact.media {
                            mediaBytes += media.data.utf8.count
                        }
                        if let bash = artifact.bashOutput {
                            bashBytes += (bash.output?.utf8.count ?? 0)
                        }
                        if let patch = artifact.changeSet?.gitPatch?.unidiffPatch {
                            patchBytes += patch.utf8.count
                        }
                    }
                }
                if isMemoryProfilingEnabled && (mediaBytes > 0 || bashBytes > 0 || patchBytes > 0) {
                    let mediaKB = Double(mediaBytes) / 1024
                    let bashKB = Double(bashBytes) / 1024
                    let patchKB = Double(patchBytes) / 1024
                    print("🧠 [HeavyData] Session \(sessionId.prefix(8)): media=\(String(format: "%.1f", mediaKB))KB, bash=\(String(format: "%.1f", bashKB))KB, patches=\(String(format: "%.1f", patchKB))KB")
                }

                profiler.startMemoryTrace("process session \(sessionId.prefix(8))")

                // Merge cached generatedDescription values from existing activities
                // This prevents re-calling Gemini for activities we've already processed
                let activitiesWithCachedDescriptions = mergeGeneratedDescriptions(
                    newActivities: activities,
                    existingActivities: sessionToUpdate.activities
                )

                // Update session immediately with activities (before Gemini processing)
                // This allows the view to show right away while descriptions load in background
                sessionToUpdate.activities = activitiesWithCachedDescriptions
                sessionToUpdate.lastActivityPollTime = pollTime

                // Update cached diff data (computed once here instead of on every UI access)
                profiler.startMemoryTrace("updateCachedDiffData \(sessionId.prefix(8))")
                sessionToUpdate.updateCachedDiffData()
                profiler.endMemoryTrace("updateCachedDiffData \(sessionId.prefix(8))")

                // DEBUG: Log whether diffs were computed
                if isMemoryProfilingEnabled {
                    if let diffs = sessionToUpdate.cachedLatestDiffs {
                        let diffBytes = diffs.reduce(0) { $0 + $1.patch.utf8.count }
                        print("🧠 [MemoryDebug] Session \(sessionId.prefix(8)): updateCachedDiffData computed \(diffs.count) diffs (\(String(format: "%.1f", Double(diffBytes)/1024))KB)")
                    } else {
                        print("🧠 [MemoryDebug] Session \(sessionId.prefix(8)): updateCachedDiffData returned nil (no latest activity with patches)")
                    }
                }

                // Strip heavy data from activities after extracting diffs:
                // - unidiffPatch (stored separately in DiffStorageManager)
                // - media (base64 images can be 1-5MB each)
                // - large bash outputs (truncated to ~10KB)
                profiler.logMemory("before stripping activities \(sessionId.prefix(8))")
                sessionToUpdate.activities = sessionToUpdate.activities?.map { $0.strippedForStorage() }
                profiler.logMemory("after stripping activities \(sessionId.prefix(8))")

                // DEBUG: Log stripped sizes to verify memory savings
                var strippedMediaBytes = 0
                var strippedBashBytes = 0
                var strippedPatchBytes = 0
                for activity in sessionToUpdate.activities ?? [] {
                    for artifact in activity.artifacts ?? [] {
                        if let media = artifact.media {
                            strippedMediaBytes += media.data.utf8.count
                        }
                        if let bash = artifact.bashOutput {
                            strippedBashBytes += (bash.output?.utf8.count ?? 0)
                        }
                        if let patch = artifact.changeSet?.gitPatch?.unidiffPatch {
                            strippedPatchBytes += patch.utf8.count
                        }
                    }
                }
                let savedBytes = (mediaBytes + bashBytes + patchBytes) - (strippedMediaBytes + strippedBashBytes + strippedPatchBytes)
                if isMemoryProfilingEnabled && savedBytes > 0 {
                    let savedKB = Double(savedBytes) / 1024
                    print("🧠 [HeavyData] Session \(sessionId.prefix(8)) STRIPPED: saved \(String(format: "%.1f", savedKB))KB (media: \(String(format: "%.1f", Double(strippedMediaBytes)/1024))KB, bash: \(String(format: "%.1f", Double(strippedBashBytes)/1024))KB)")
                }

                // Check for new messages for notifications
                // Use .last(where:) since activities are sorted oldest to newest
                // Only send notification if the session hasn't been viewed yet
                // MEMORY FIX: Use stripped activities from sessionToUpdate instead of activitiesWithCachedDescriptions.
                // The agentMessaged field is preserved by stripping, and this allows activitiesWithCachedDescriptions
                // (which contains heavy unstripped data) to be deallocated earlier.
                if let latestMessage = sessionToUpdate.activities?.last(where: { $0.agentMessaged != nil }) {
                     if !sessionToUpdate.isViewed && !isMessageViewed(sessionId: sessionToUpdate.id, activityId: latestMessage.id) {
                         sendLocalNotification(session: sessionToUpdate, activity: latestMessage)
                         markMessageViewed(sessionId: sessionToUpdate.id, activityId: latestMessage.id)
                     }
                }

                profiler.startMemoryTrace("saveSession \(sessionId.prefix(8))")
                await sessionRepository.updateSession(sessionToUpdate)
                profiler.endMemoryTrace("saveSession \(sessionId.prefix(8))")

                // MEMORY FIX: Clear cachedLatestDiffs after saving to repository.
                // The diffs are now stored in DiffStorageManager, so keeping them in
                // the Session object would duplicate memory. Without this, diffs were
                // stored in both DiffStorageManager AND every Session copy in:
                // sessions, recentSessions, sessionsById - causing 200MB+ memory spikes.
                if isMemoryProfilingEnabled, let diffs = sessionToUpdate.cachedLatestDiffs, !diffs.isEmpty {
                    let diffBytes = diffs.reduce(0) { $0 + $1.patch.utf8.count }
                    print("🧠 [MemoryFix] Session \(sessionId.prefix(8)): clearing \(String(format: "%.1f", Double(diffBytes)/1024))KB of cachedLatestDiffs from in-memory Session")
                }
                sessionToUpdate.cachedLatestDiffs = nil

                updateLocalSessionCache(sessionToUpdate)
                profiler.endMemoryTrace("process session \(sessionId.prefix(8))")

                // Process Gemini descriptions asynchronously - view shows immediately,
                // descriptions populate as they become available
                // Priority is given to the currently viewed session so its descriptions appear first
                let isActiveSession = sessionId == self.activeSessionId
                // MEMORY FIX: Pass stripped activities to Gemini processing.
                // Previously passed unstripped activitiesWithCachedDescriptions, which retained
                // heavy data (media, patches) in the Task closure for the duration of Gemini API calls.
                // Gemini only needs progressUpdated?.description, which strippedForStorage() preserves.
                processGeminiDescriptionsAsync(
                    sessionId: sessionId,
                    activities: sessionToUpdate.activities ?? [],
                    isPriority: isActiveSession
                )
                }  // end case .activities

            case .failure(let error):
                print("Error fetching activities for session \(sessionId): \(error)")
            }
        }

        profiler.endMemoryTrace("fetchActivities(\(sessionsNeedingFetch.count) sessions)")

        // Log diff cache state after fetching to help correlate memory spikes with cache growth
        DiffStorageManager.shared.logCacheMemory("after fetch")
    }

    /// Merges cached generatedDescription and generatedTitle values from existing activities into new activities.
    /// This prevents unnecessary Gemini API calls for activities we've already processed.
    private func mergeGeneratedDescriptions(newActivities: [Activity], existingActivities: [Activity]?) -> [Activity] {
        guard let existingActivities = existingActivities else {
            return newActivities
        }

        // Create a lookup dictionary for existing generated content by activity ID
        let existingContent = Dictionary(
            existingActivities.compactMap { activity -> (String, (description: String?, title: String?))? in
                guard activity.generatedDescription != nil || activity.generatedTitle != nil else { return nil }
                return (activity.id, (description: activity.generatedDescription, title: activity.generatedTitle))
            },
            uniquingKeysWith: { first, _ in first }
        )

        // Merge existing content into new activities
        return newActivities.map { activity in
            var updatedActivity = activity
            if let cached = existingContent[activity.id] {
                if updatedActivity.generatedDescription == nil, let cachedDescription = cached.description {
                    updatedActivity.generatedDescription = cachedDescription
                }
                if updatedActivity.generatedTitle == nil, let cachedTitle = cached.title {
                    updatedActivity.generatedTitle = cachedTitle
                }
            }
            return updatedActivity
        }
    }

    /// Processes Gemini descriptions asynchronously for a session's activities.
    /// This runs in the background so the view can show immediately while descriptions load.
    /// When processing completes, the session is updated with the generated descriptions.
    /// Uses a priority semaphore to ensure the currently viewed session is processed first.
    /// - Parameters:
    ///   - sessionId: The session to process
    ///   - activities: The activities to generate descriptions for
    ///   - isPriority: If true, this session gets priority processing (e.g., the currently viewed session)
    private func processGeminiDescriptionsAsync(sessionId: String, activities: [Activity], isPriority: Bool) {
        // Skip if already processing this session
        guard !inFlightGeminiProcessing.contains(sessionId) else { return }

        // Check if any activities actually need Gemini processing
        let needsProcessing = activities.contains { activity in
            guard let progressDescription = activity.progressUpdated?.description,
                  !progressDescription.isEmpty else { return false }
            return activity.generatedDescription == nil || activity.generatedTitle == nil
        }
        guard needsProcessing else { return }

        inFlightGeminiProcessing.insert(sessionId)

        Task {
            defer {
                Task { @MainActor in
                    self.inFlightGeminiProcessing.remove(sessionId)
                }
            }

            // Acquire semaphore slot with priority handling
            // Priority sessions (currently viewed) are processed before background sessions
            // This ensures the user sees descriptions update quickly for the session they're viewing
            await geminiProcessingSemaphore.acquire(priority: isPriority)

            let profiler = LoadingProfiler.shared
            profiler.beginSpan("Data: Gemini async processing \(sessionId.prefix(8))")
            profiler.startMemoryTrace("Gemini async \(sessionId.prefix(8))")

            // Use batched processing for non-priority sessions (completed/background)
            // to reduce API calls and avoid rate limits. For example, 10 activities
            // become 1 API call instead of 10, significantly reducing rate limit issues.
            // Active sessions use individual requests for real-time streaming updates.
            let geminiResults: [Int: GeminiProgressSummary]
            if isPriority {
                // Active session - process individually for real-time updates
                geminiResults = await apiService.processActivityDescriptionsWithGemini(activities, throttle: false)
            } else {
                // Completed/background session - use batched processing for efficiency
                geminiResults = await apiService.processActivityDescriptionsBatched(activities)
            }

            // Release semaphore immediately after API call completes
            // This allows other sessions to start processing while we update the local cache
            await geminiProcessingSemaphore.release()

            profiler.endMemoryTrace("Gemini async \(sessionId.prefix(8))")
            profiler.endSpan("Data: Gemini async processing \(sessionId.prefix(8))")

            // Update the session with generated descriptions
            guard var sessionToUpdate = self.sessions.first(where: { $0.id == sessionId }) else { return }

            // Check if any descriptions were actually generated
            let hasNewDescriptions = !geminiResults.isEmpty

            // Apply the Gemini results directly to the session's existing activities
            // This avoids creating intermediate copies of the activities array
            if var existingActivities = sessionToUpdate.activities {
                for (index, summary) in geminiResults {
                    guard index < existingActivities.count else { continue }
                    if existingActivities[index].generatedTitle == nil {
                        existingActivities[index].generatedTitle = summary.title
                    }
                    if existingActivities[index].generatedDescription == nil {
                        existingActivities[index].generatedDescription = summary.description
                    }
                }
                sessionToUpdate.activities = existingActivities
            }

            // Save to repository for persistence
            await sessionRepository.updateSession(sessionToUpdate)

            // Update local cache with the session containing new descriptions
            // NOTE: This triggers @Published observers, causing SwiftUI to re-evaluate views.
            // However, the diff panel is protected by hash-based change detection in its
            // updateNSView method - it computes a hash of the diffs and returns early when
            // unchanged, preventing any actual rendering work. Only the ActivityView will
            // meaningfully update because it subscribes to geminiDescriptionsUpdatedPublisher.
            updateLocalSessionCache(sessionToUpdate)

            // Notify ActivityView to refresh and show the new descriptions
            // This targeted notification ensures the activity list updates immediately
            if hasNewDescriptions {
                self.geminiDescriptionsUpdatedPublisher.send(sessionId)
            }
        }
    }

    /// Updates the local session cache immediately after a database write.
    /// This ensures views see new data right away without waiting for the
    /// Combine pipeline's async scheduling via .receive(on: DispatchQueue.main).
    private func updateLocalSessionCache(_ session: Session) {
        if let index = self.sessions.firstIndex(where: { $0.id == session.id }) {
            self.sessions[index] = session
        }
        if let index = self.recentSessions.firstIndex(where: { $0.id == session.id }) {
            self.recentSessions[index] = session
        }
        self.sessionsById[session.id] = session
    }

    private func isMessageViewed(sessionId: String, activityId: String) -> Bool {
        return viewedMessages[sessionId]?.contains(activityId) ?? false
    }

    private func markMessageViewed(sessionId: String, activityId: String) {
        if viewedMessages[sessionId] == nil { viewedMessages[sessionId] = [] }
        viewedMessages[sessionId]?.insert(activityId)
    }

    /// Persists viewedMessages to UserDefaults for use across app restarts.
    /// Uses a dictionary of [sessionId: [activityIds]] for storage.
    private func persistViewedMessages() {
        // Convert Set<String> to Array<String> for JSON encoding
        let arrayVersion = viewedMessages.mapValues { Array($0) }
        UserDefaults.standard.set(arrayVersion, forKey: viewedMessagesKey)
    }

    /// Prunes viewedMessages if it exceeds the maximum allowed sessions.
    /// Keeps only the most recently added sessions (approximated by keeping sessions
    /// that exist in our current sessions list, which is sorted by recency).
    private func pruneViewedMessagesIfNeeded() {
        guard viewedMessages.count > maxViewedMessagesSessions else { return }

        // Get session IDs that we currently have, which are sorted by recency
        let recentSessionIds = Set(sessions.prefix(maxViewedMessagesSessions).map { $0.id })

        // Keep only sessions that are in our recent list, or if we have fewer sessions
        // than the limit, keep all current sessions plus trim the rest
        let keysToKeep: Set<String>
        if recentSessionIds.count >= maxViewedMessagesSessions {
            keysToKeep = recentSessionIds
        } else {
            // Not enough sessions loaded, just keep the first maxViewedMessagesSessions keys
            keysToKeep = Set(viewedMessages.keys.prefix(maxViewedMessagesSessions))
        }

        let keysToRemove = viewedMessages.keys.filter { !keysToKeep.contains($0) }
        for key in keysToRemove {
            viewedMessages.removeValue(forKey: key)
        }

        if !keysToRemove.isEmpty {
            print("[DataManager] Pruned \(keysToRemove.count) old sessions from viewedMessages (was \(keysToRemove.count + viewedMessages.count), now \(viewedMessages.count))")
        }
    }

    /// Loads viewedMessages from UserDefaults.
    /// Returns empty dictionary if no data exists.
    /// Static to allow calling during init before all properties are initialized.
    private static func loadViewedMessages() -> [String: Set<String>] {
        guard let stored = UserDefaults.standard.dictionary(forKey: "viewedMessages") as? [String: [String]] else {
            return [:]
        }
        // Convert Array<String> back to Set<String>
        return stored.mapValues { Set($0) }
    }

    private func sendLocalNotification(session: Session, activity: Activity) {
        let notification = AppNotification(
            id: activity.id,
            sessionId: session.id,
            title: "Jules: \(session.state.displayName)",
            subtitle: session.prompt,
            body: activity.agentMessaged?.agentMessage ?? "New update",
            timestamp: Date(),
            relatedUrl: session.url,
            viewedAt: nil
        )
        NotificationCenter.default.post(
            name: .didReceiveNewApiNotifications,
            object: self,
            userInfo: ["notifications": [notification]]
        )
    }

    // --- Data Fetching ---

    /// Fetches sources using offline-first approach
    /// First loads from local cache, then refreshes from API if online
    func fetchSources(forceRefresh: Bool = false) {
        Task {
            let profiler = LoadingProfiler.shared
            profiler.beginSpan("Data: fetchSources")
            // The SourceRepository handles offline-first logic internally
            // It will return cached data if offline, or fetch from API if online
            await sourceRepository.refresh()
            profiler.endSpan("Data: fetchSources")
        }
    }

    /// Force refresh sources - fetches fresh from API
    func forceRefreshSources() {
        fetchSources(forceRefresh: true)
    }

    private func restoreSelection() {
        let lastSourceId = UserDefaults.standard.string(forKey: lastUsedSourceIdKey)
        if let currentId = selectedSourceId, !sources.contains(where: { $0.id == currentId }) {
             selectedSourceId = nil
        } else if selectedSourceId == nil, let lastSourceId = lastSourceId, sources.contains(where: { $0.id == lastSourceId }) {
             self.selectedSourceId = lastSourceId
        }
    }

    // Replaced with Repository logic
    func fetchSessions(background: Bool = false, isRefresh: Bool = false, pageSize: Int? = nil, bypassRateLimit: Bool = false) async {
        let profiler = LoadingProfiler.shared
        profiler.beginSpan("Data: fetchSessions")
        // This is primarily called on init or manually refresh.
        // We map it to repository.refresh()
        await sessionRepository.refresh(bypassRateLimit: bypassRateLimit)
        profiler.endSpan("Data: fetchSessions")
    }

    func fetchNextPageOfSessions() async {
        // Delegate logic to repository which knows about DB count vs Limit vs API
        sessionRepository.loadMore()
    }

    // Explicit trigger for UI "Load More" or "Retry"
    // Bypasses rate limit since this is an explicit user action
    func loadMoreData() async {
        // If retrying, we force a fetch attempt
        // Bypass rate limit for explicit user clicks on "Load More"
        await sessionRepository.fetchMoreData(bypassRateLimit: true)
    }

    /// Force refresh sessions from API - clears local cache and re-fetches
    /// Use this when data appears corrupted or missing
    func forceRefreshSessions() async {
        await sessionRepository.forceRefreshFromAPI()
    }

    /// Validates and repairs session data if needed
    func validateAndRepairSessionData() async {
        await sessionRepository.validateAndRepairDatabase()
    }

    /// Check if sources data appears valid, if not trigger refresh
    func ensureSourcesLoaded() {
        if sources.isEmpty && !isLoadingSources && !apiKey.isEmpty {
            print("Sources are empty, triggering refresh...")
            forceRefreshSources()
        }
    }

    /// Check if sessions data appears valid, if not trigger refresh
    func ensureSessionsLoaded() {
        if sessions.isEmpty && syncState != .loading && !apiKey.isEmpty {
            print("Sessions are empty, triggering refresh...")
            Task {
                await forceRefreshSessions()
            }
        }
    }

    private func preselectLastUsedBranch(for sourceId: String) {
         guard let source = sources.first(where: { $0.id == sourceId }),
               let repo = source.githubRepo,
               let branches = repo.branches
         else { return }

         // First check per-source branch memory
         let perSourceBranches = UserDefaults.standard.dictionary(forKey: lastUsedBranchesPerSourceKey) as? [String: String]
         if let branchName = perSourceBranches?[sourceId],
            branches.contains(where: { $0.displayName == branchName }) {
             self.selectedBranchName = branchName
             return
         }

         // Fall back to global last used branch (backward compatibility)
         let lastBranchName = UserDefaults.standard.string(forKey: lastUsedBranchKey)
         if let lastBranchName = lastBranchName, branches.contains(where: { $0.displayName == lastBranchName }) {
             self.selectedBranchName = lastBranchName
         } else if let defaultBranch = repo.defaultBranch {
             self.selectedBranchName = defaultBranch.displayName
         }
    }

    /// Save the branch for a specific source
    private func saveLastUsedBranch(_ branchName: String, forSource sourceId: String) {
        var perSourceBranches = UserDefaults.standard.dictionary(forKey: lastUsedBranchesPerSourceKey) as? [String: String] ?? [:]
        perSourceBranches[sourceId] = branchName
        UserDefaults.standard.set(perSourceBranches, forKey: lastUsedBranchesPerSourceKey)
        // Also save globally for backward compatibility
        UserDefaults.standard.set(branchName, forKey: lastUsedBranchKey)
    }

    func createSession() {
        guard let sourceId = selectedSourceId,
              let branchName = selectedBranchName,
              let selectedSource = sources.first(where: { $0.id == sourceId }),
              !isCreatingSession else { return }

        let promptToSend = constructPrompt()
        if promptToSend.isEmpty { return }

        let originalPrompt = promptText
        let originalAttachment = draftAttachmentContent

        isCreatingSession = true
        promptText = ""; clearDraftAttachment()

        // Show wave flash message at top of menu
        FlashMessageManager.shared.show(
            message: "Submitting Task",
            type: .success,
            duration: 0,  // No auto-dismiss - we'll hide it when done
            style: .wave,
            showBoids: true,
            waveConfig: .default
        )

        // Show flash message on the StickyStatusView for new session form
        StickyStatusFlashManager.shared.show(
            sessionId: StickyStatusFlashManager.newSessionKey,
            message: "Creating Task...",
            isSuccess: false,
            duration: 30.0  // Long duration since we'll clear it manually
        )

        Task {
            defer {
                self.isCreatingSession = false
                FlashMessageManager.shared.hide()
            }

            // Check if we're offline - queue the session for later
            if !networkMonitor.isConnected {
                do {
                    try await offlineSyncManager.queuePendingSession(
                        sourceName: selectedSource.name,
                        branchName: branchName,
                        prompt: promptToSend
                    )
                    UserDefaults.standard.set(sourceId, forKey: lastUsedSourceIdKey)
                    saveLastUsedBranch(branchName, forSource: sourceId)
                    // Show success flash briefly then clear (view stays on form for offline)
                    StickyStatusFlashManager.shared.show(
                        sessionId: StickyStatusFlashManager.newSessionKey,
                        message: "Task Queued",
                        isSuccess: true,
                        duration: 2.0
                    )
                } catch {
                    restoreState(prompt: originalPrompt, attachment: originalAttachment)
                    StickyStatusFlashManager.shared.clear(sessionId: StickyStatusFlashManager.newSessionKey)
                    FlashMessageManager.shared.show(message: "Failed to queue task.", type: .error)
                    print("❌ Error queuing offline session: \(error)")
                }
                return
            }

            // Online - create session immediately
            do {
                // createSession now returns the Session directly from the API response,
                // avoiding the race condition where getNewestSession() might return
                // a different session if the new one isn't immediately available via polling.
                let newSession = try await apiService.createSession(source: selectedSource, branchName: branchName, prompt: promptToSend)
                if let newSession = newSession {
                    UserDefaults.standard.set(sourceId, forKey: lastUsedSourceIdKey)
                    saveLastUsedBranch(branchName, forSource: sourceId)

                    // Clear the "Creating Task..." flash from the new session form
                    StickyStatusFlashManager.shared.clear(sessionId: StickyStatusFlashManager.newSessionKey)

                    // Show success flash on the NEW SESSION's ID (not newSessionKey)
                    // because the view will transition to show the actual session
                    StickyStatusFlashManager.shared.show(
                        sessionId: newSession.id,
                        message: "Task Created!",
                        isSuccess: true,
                        duration: 2.0
                    )

                    // Insert new session into local arrays SYNCHRONOUSLY before sending
                    // the publisher. This ensures TahoeSessionView can find the session
                    // when it looks it up by ID.
                    if !self.recentSessions.contains(where: { $0.id == newSession.id }) {
                        self.recentSessions.insert(newSession, at: 0)
                        self.sessions.insert(newSession, at: 0)
                        self.sessionsById[newSession.id] = newSession
                    }

                    // Save to database so it persists
                    await sessionRepository.updateSession(newSession)

                    self.sessionCreatedPublisher.send(newSession)

                    // Also refresh sessions in background to ensure we have the latest list
                    // (non-blocking, doesn't affect navigation)
                    Task {
                        await fetchSessions(isRefresh: true, bypassRateLimit: true)
                    }
                } else {
                    restoreState(prompt: originalPrompt, attachment: originalAttachment)
                    StickyStatusFlashManager.shared.clear(sessionId: StickyStatusFlashManager.newSessionKey)
                    FlashMessageManager.shared.show(message: "Creation failed.", type: .error)
                }
            } catch {
                // Network error - queue for later instead of failing
                do {
                    try await offlineSyncManager.queuePendingSession(
                        sourceName: selectedSource.name,
                        branchName: branchName,
                        prompt: promptToSend
                    )
                    UserDefaults.standard.set(sourceId, forKey: lastUsedSourceIdKey)
                    saveLastUsedBranch(branchName, forSource: sourceId)
                    // Show success flash (view stays on form for queued tasks)
                    StickyStatusFlashManager.shared.show(
                        sessionId: StickyStatusFlashManager.newSessionKey,
                        message: "Task Queued",
                        isSuccess: true,
                        duration: 2.0
                    )
                } catch {
                    restoreState(prompt: originalPrompt, attachment: originalAttachment)
                    StickyStatusFlashManager.shared.clear(sessionId: StickyStatusFlashManager.newSessionKey)
                    FlashMessageManager.shared.show(message: "Failed to queue task.", type: .error)
                    print("❌ Error queuing session after network error: \(error)")
                }
            }
        }
    }

    private func constructPrompt() -> String {
        var p = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let att = draftAttachmentContent {
            if !p.isEmpty { p += "\n\n---\n\n" }
            p += "```\n\(att)\n```"
        }
        return p
    }

    private func restoreState(prompt: String, attachment: String?) {
        promptText = prompt
        if let att = attachment { setDraftAttachment(content: att) }
    }

    // Note: draftAttachmentContent is @Published, so objectWillChange is triggered automatically.
    // Manual objectWillChange.send() was removed to avoid cascading re-renders of all observers.
    func setDraftAttachment(content: String) { draftAttachmentContent = content }
    func clearDraftAttachment() { draftAttachmentContent = nil }

    func setDraftImageAttachment(image: NSImage) { draftImageAttachment = image }
    func clearDraftImageAttachment() { draftImageAttachment = nil }

    func openURL(_ urlString: String?) {
        guard let s = urlString, let u = URL(string: s) else { return }
        NSWorkspace.shared.open(u)
    }

    func openSettings() {
        if let url = settingsURL {
            NSWorkspace.shared.open(url)
        }
    }
    
    func sendMessage(session: Session, message: String) {
        guard !isSendingMessage else { return }

        isSendingMessage = true

        // Show flash message on the StickyStatusView
        StickyStatusFlashManager.shared.show(
            sessionId: session.id,
            message: "Posting Message",
            isSuccess: true,
            duration: 2.0
        )

        Task {
            defer { self.isSendingMessage = false }
            do {
                let success = try await apiService.sendMessage(sessionId: session.id, message: message)
                if success {
                    // Clear the activity response hash cache to ensure we get fresh data
                    // after sending a message (the response will definitely be different)
                    apiService.clearActivityCache(for: session.id)
                    await fetchActivities(for: session)
                } else {
                    StickyStatusFlashManager.shared.clear(sessionId: session.id)
                    FlashMessageManager.shared.show(message: "Failed to send message.", type: .error)
                }
            } catch {
                StickyStatusFlashManager.shared.clear(sessionId: session.id)
                FlashMessageManager.shared.show(message: "Network error.", type: .error)
                print("❌ Error sending message: \(error)")
            }
        }
    }

    func fetchActivities(for session: Session) async {
        let profiler = LoadingProfiler.shared
        profiler.beginSpan("Data: fetchActivities(\(session.id.prefix(8))...)")
        profiler.startMemoryTrace("fetchActivities(single) \(session.id.prefix(8))")

        do {
            profiler.beginSpan("Data: API fetchActivities")
            profiler.startMemoryTrace("API fetch \(session.id.prefix(8))")
            // MEMORY FIX: Use hash-based cache validation to skip JSON decoding (~29MB)
            // when response data hasn't changed since last fetch.
            let fetchResult = try await apiService.fetchActivitiesIfChanged(sessionId: session.id)
            profiler.endMemoryTrace("API fetch \(session.id.prefix(8))")
            profiler.endSpan("Data: API fetchActivities")

            // Handle cache hit - skip all processing if response unchanged
            guard case .activities(let activities) = fetchResult else {
                if isMemoryProfilingEnabled {
                    print("🧠 [MemoryFix] Session \(session.id.prefix(8)): response hash unchanged, skipped JSON decoding")
                }
                profiler.checkpoint("Data: Response unchanged, skipped decoding")
                profiler.endMemoryTrace("fetchActivities(single) \(session.id.prefix(8))")
                profiler.endSpan("Data: fetchActivities(\(session.id.prefix(8))...)")
                return
            }

            // Log latest activity title for debugging UI updates
            if let latestActivity = activities.last {
                let title = latestActivity.title ?? latestActivity.generatedTitle ?? "untitled"
                print("📋 Session \(session.id.prefix(8))... latest activity: \(title), \(activities.count) activities")
            }

            // Get the latest session from our cache to ensure we have the most up-to-date
            // cached generatedDescriptions (the passed session might be stale)
            let currentSession = self.sessions.first(where: { $0.id == session.id }) ?? session

            // Merge cached generatedDescription values from existing activities
            // This prevents re-calling Gemini for activities we've already processed
            let activitiesWithCachedDescriptions = mergeGeneratedDescriptions(
                newActivities: activities,
                existingActivities: currentSession.activities
            )

            // Update session immediately with activities (before Gemini processing)
            // This allows the view to show right away while descriptions load in background
            var updatedSession = currentSession
            updatedSession.activities = activitiesWithCachedDescriptions
            updatedSession.lastActivityPollTime = Date()

            // Update cached diff data (computed once here instead of on every UI access)
            profiler.beginSpan("Data: updateCachedDiffData")
            profiler.startMemoryTrace("updateCachedDiffData \(session.id.prefix(8))")
            updatedSession.updateCachedDiffData()
            profiler.endMemoryTrace("updateCachedDiffData \(session.id.prefix(8))")
            profiler.endSpan("Data: updateCachedDiffData")

            // DEBUG: Log whether diffs were computed
            if isMemoryProfilingEnabled {
                if let diffs = updatedSession.cachedLatestDiffs {
                    let diffBytes = diffs.reduce(0) { $0 + $1.patch.utf8.count }
                    print("🧠 [MemoryDebug] Session \(session.id.prefix(8)): updateCachedDiffData computed \(diffs.count) diffs (\(String(format: "%.1f", Double(diffBytes)/1024))KB)")
                } else {
                    print("🧠 [MemoryDebug] Session \(session.id.prefix(8)): updateCachedDiffData returned nil (no latest activity with patches)")
                }
            }

            // Strip heavy data from activities after extracting diffs:
            // - unidiffPatch (stored separately in DiffStorageManager)
            // - media (base64 images can be 1-5MB each)
            // - large bash outputs (truncated to ~10KB)
            profiler.logMemory("before strip \(session.id.prefix(8))")
            updatedSession.activities = updatedSession.activities?.map { $0.strippedForStorage() }
            profiler.logMemory("after strip \(session.id.prefix(8))")

            // Check for new messages for notifications
            // Use .last(where:) since activities are sorted oldest to newest
            // Only send notification if the session hasn't been viewed yet
            // MEMORY FIX: Use stripped activities from updatedSession instead of activitiesWithCachedDescriptions.
            // The agentMessaged field is preserved by stripping, and this allows activitiesWithCachedDescriptions
            // (which contains heavy unstripped data) to be deallocated earlier.
            if let latestMessage = updatedSession.activities?.last(where: { $0.agentMessaged != nil }) {
                 if !currentSession.isViewed && !isMessageViewed(sessionId: session.id, activityId: latestMessage.id) {
                     sendLocalNotification(session: currentSession, activity: latestMessage)
                     markMessageViewed(sessionId: session.id, activityId: latestMessage.id)
                 }
            }

            profiler.beginSpan("Data: updateSession in DB")
            profiler.startMemoryTrace("saveSession \(session.id.prefix(8))")
            await sessionRepository.updateSession(updatedSession)
            profiler.endMemoryTrace("saveSession \(session.id.prefix(8))")
            profiler.endSpan("Data: updateSession in DB")

            // MEMORY FIX: Clear cachedLatestDiffs after saving to repository.
            // The diffs are now stored in DiffStorageManager, so keeping them in
            // the Session object would duplicate memory. Without this, diffs were
            // stored in both DiffStorageManager AND every Session copy in:
            // sessions, recentSessions, sessionsById - causing 200MB+ memory spikes.
            if isMemoryProfilingEnabled, let diffs = updatedSession.cachedLatestDiffs, !diffs.isEmpty {
                let diffBytes = diffs.reduce(0) { $0 + $1.patch.utf8.count }
                print("🧠 [MemoryFix] Session \(session.id.prefix(8)): clearing \(String(format: "%.1f", Double(diffBytes)/1024))KB of cachedLatestDiffs from in-memory Session")
            }
            updatedSession.cachedLatestDiffs = nil

            updateLocalSessionCache(updatedSession)
            profiler.endMemoryTrace("fetchActivities(single) \(session.id.prefix(8))")

            // Process Gemini descriptions asynchronously - view shows immediately,
            // descriptions populate as they become available
            // Priority is given to the currently viewed session so its descriptions appear first
            let isActiveSession = session.id == self.activeSessionId
            // MEMORY FIX: Pass stripped activities to Gemini processing.
            // Previously passed unstripped activitiesWithCachedDescriptions, which retained
            // heavy data (media, patches) in the Task closure for the duration of Gemini API calls.
            // Gemini only needs progressUpdated?.description, which strippedForStorage() preserves.
            processGeminiDescriptionsAsync(
                sessionId: session.id,
                activities: updatedSession.activities ?? [],
                isPriority: isActiveSession
            )

        } catch {
            print("❌ Error fetching activities for session \(session.id): \(error)")
            profiler.endMemoryTrace("fetchActivities(single) \(session.id.prefix(8))")
        }
        profiler.endSpan("Data: fetchActivities(\(session.id.prefix(8))...)")
    }

    // On-demand fetch for UI with rate limiting and poll time checks
    func ensureActivities(for session: Session) {
        // If already fetching this session, skip
        guard !inFlightActivityFetches.contains(session.id) else { return }

        // For terminal sessions with activities already loaded, skip API fetch
        // These sessions won't have new activities, so use cached data from DB
        let isTerminalState = session.state.isTerminal
        if isTerminalState && session.activities != nil {
            LoadingProfiler.shared.checkpoint("Data: ensureActivities skipped (terminal state with cached data)")
            return
        }

        // For in-progress sessions, check poll interval to avoid too frequent fetches
        if session.activities != nil {
            if let lastPollTime = session.lastActivityPollTime,
               Date().timeIntervalSince(lastPollTime) < minActivityPollInterval {
                LoadingProfiler.shared.checkpoint("Data: ensureActivities skipped (poll interval)")
                return
            }
        }

        inFlightActivityFetches.insert(session.id)

        Task {
            defer {
                Task { @MainActor in
                    self.inFlightActivityFetches.remove(session.id)
                }
            }

            let profiler = LoadingProfiler.shared
            profiler.beginSpan("Data: ensureActivities(\(session.id.prefix(8))...)")

            // Check rate limit before fetching
            let isApproachingLimit = await rateLimiter.isApproachingLimit()
            if isApproachingLimit {
                profiler.checkpoint("Data: Rate limit check - approaching limit")
                // Check if we need to wait
                let (canProceed, waitTime) = await rateLimiter.checkAvailability()
                if !canProceed && waitTime > 0 {
                    profiler.beginSpan("Data: Rate limit wait")
                    await MainActor.run { self.isThrottlingActivities = true }
                    try? await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
                    await MainActor.run { self.isThrottlingActivities = false }
                    profiler.endSpan("Data: Rate limit wait")
                }
            }

            await rateLimiter.recordRequest()
            await fetchActivities(for: session)
            profiler.endSpan("Data: ensureActivities(\(session.id.prefix(8))...)")
        }
    }

    func mergeLocal(session: Session, completion: ((Bool) -> Void)? = nil) {
        // Look up the source ID from the source name in sourceContext
        guard let sourceName = session.sourceContext?.source,
              let source = sources.first(where: { $0.name == sourceName }) else {
            FlashMessageManager.shared.show(message: "Could not find source for session.", type: .error)
            completion?(false)
            return
        }
        mergeManager.mergeLocal(session: session, sourceId: source.id) { [weak self] success in
            if success {
                self?.markSessionAsMergedLocally(session)
            }
            completion?(success)
        }
    }

    /// Check if a patch can be applied without conflicts (dry-run)
    /// Returns true if patch can be applied cleanly, false if there are conflicts
    func canApplyPatch(session: Session) -> Bool {
        guard let sourceName = session.sourceContext?.source,
              let source = sources.first(where: { $0.name == sourceName }) else {
            return true // Optimistically assume no conflicts if we can't find source
        }
        return mergeManager.canApplyPatch(session: session, sourceId: source.id)
    }

    /// Count the number of files with conflicts
    /// Returns the number of files that would have conflicts, or nil if unknown
    func countConflicts(session: Session) -> Int? {
        guard let sourceName = session.sourceContext?.source,
              let source = sources.first(where: { $0.name == sourceName }) else {
            return nil // Can't determine conflicts without source
        }
        return mergeManager.countConflicts(session: session, sourceId: source.id)
    }

    // MARK: - Session Viewed State

    /// Marks a specific session as viewed post-completion (only tracks if session is already completed or completedUnknown)
    func markSessionAsViewed(_ session: Session) {
        // Only track post-completion visits - ignore visits to non-completed sessions
        guard session.state == .completed || session.state == .completedUnknown else { return }
        guard session.viewedPostCompletionAt == nil else { return }

        Task {
            var updatedSession = session
            updatedSession.viewedPostCompletionAt = Date()
            await sessionRepository.updateSession(updatedSession)
            updateLocalSessionCache(updatedSession)
        }
    }

    /// Marks a specific session as merged locally
    func markSessionAsMergedLocally(_ session: Session) {
        guard session.mergedLocallyAt == nil else { return }

        Task {
            var updatedSession = session
            updatedSession.mergedLocallyAt = Date()
            await sessionRepository.updateSession(updatedSession)
            updateLocalSessionCache(updatedSession)
        }
    }

    /// Checks if a specific session is unviewed (post-completion)
    func isSessionUnviewed(_ session: Session) -> Bool {
        return session.viewedPostCompletionAt == nil
    }

    // MARK: - Filename Autocomplete Cache

    /// Get the local path for a source from UserDefaults
    private func getLocalPath(for sourceId: String) -> String? {
        let paths = UserDefaults.standard.dictionary(forKey: localRepoPathsKey) as? [String: String]
        return paths?[sourceId]
    }

    /// Update the filename autocomplete cache from session diffs
    /// Only processes sessions that haven't been processed before to avoid log spam
    /// IMPORTANT: Uses cache-only access to avoid triggering diff preloads during pagination
    private func updateFilenameCacheFromSessions(_ sessions: [Session]) {
        let autocompleteManager = FilenameAutocompleteManager.shared

        for session in sessions {
            // 1. Check processedSessionDiffIds FIRST - skip already-processed sessions early
            if processedSessionDiffIds.contains(session.id) {
                continue
            }

            guard let sourceId = session.sourceContext?.source else { continue }

            // 2. Check hasDiffsAvailable - cheap, no side effects, defensive guard
            // This prevents triggering preloads for sessions without cached diffs
            guard session.hasDiffsAvailable else { continue }

            // 3. Use getCachedDiffs() directly - no side effects, only reads from cache
            // Unlike latestDiffs, this won't trigger preloadDiffs() as a side effect
            guard let cachedDiffs = DiffStorageManager.shared.getCachedDiffs(forSession: session.id),
                  !cachedDiffs.isEmpty else { continue }

            // Convert CachedDiff array to expected tuple format
            let diffs = cachedDiffs.map { (patch: $0.patch, language: $0.language, filename: $0.filename) }

            // Get the local path from UserDefaults
            let localPath = getLocalPath(for: sourceId)

            // Register repository with local path if available
            autocompleteManager.registerRepository(repositoryId: sourceId, localPath: localPath)

            // Add filenames from diffs
            autocompleteManager.addFilenamesFromPatches(diffs, for: sourceId)

            // Mark this session as processed
            processedSessionDiffIds.insert(session.id)
        }

        // Prune set if it exceeds the limit to prevent unbounded growth
        if processedSessionDiffIds.count > maxTrackingSetSize {
            processedSessionDiffIds.removeAll()
        }
    }

    // MARK: - Memory Management for Menubar Mode

    /// Clears all in-memory data for a fresh start (e.g., when switching users).
    /// This ensures a new user doesn't see stale data from a previous user's session.
    func clearInMemoryData() {
        print("[DataManager] Clearing all in-memory data for fresh start")

        // Clear all session data
        sessions = []
        recentSessions = []
        sessionsById = [:]

        // Clear sources
        sources = []

        // Clear viewed messages tracking (also cleared from UserDefaults by CacheManager)
        viewedMessages = [:]

        // Clear tracking sets
        processedSessionDiffIds.removeAll()
        preloadedSessionDiffIds.removeAll()

        // Clear in-flight fetches
        inFlightActivityFetches.removeAll()

        // Clear diff caches
        DiffPrecomputationService.shared.clearAllCache()
        DiffStorageManager.shared.clearMemoryCache()

        // Reset form state
        selectedSourceId = nil
        selectedBranchName = nil
        promptText = ""
        draftAttachmentContent = nil
        draftImageAttachment = nil

        // Reset active session
        activeSessionId = nil
        scrollToDiffFile = nil

        print("[DataManager] In-memory data cleared successfully")
    }

    /// Trims session data to reduce memory footprint when running in menubar-only mode.
    /// Clears cached diffs and precomputation caches, but preserves activities to avoid
    /// re-fetching from API and re-processing through Gemini (which would hit rate limits).
    func trimSessionDataForMenubarMode() {
        print("[DataManager] Trimming session data for menubar-only mode")

        // Clear cached diffs from sessions (stored in files anyway, can be reloaded)
        // Keep activities to preserve Gemini-generated titles/descriptions
        var trimmedSessions: [Session] = []
        for var session in sessions {
            // Keep: id, prompt, state, title, updateTime, cachedGitStatsSummary, activities
            // Clear: cachedLatestDiffs (stored in files anyway)
            session.cachedLatestDiffs = nil
            trimmedSessions.append(session)
        }

        // Update in-place without triggering a full refresh
        self.sessions = trimmedSessions
        self.recentSessions = trimmedSessions
        self.sessionsById = Dictionary(trimmedSessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Clear tracking sets (they'll be repopulated when needed)
        processedSessionDiffIds.removeAll()
        preloadedSessionDiffIds.removeAll()

        // Clear diff precomputation cache (parsed diff results)
        DiffPrecomputationService.shared.clearAllCache()

        // NOTE: We intentionally DO NOT clear DiffStorageManager's memory cache here.
        // The raw diffs are backed by SQLite and the 64MB NSCache serves as a hot cache.
        // NSCache automatically evicts entries under memory pressure, so manual clearing
        // just causes unnecessary disk I/O and UI lag when the user reopens windows.
        // The diffs will be instantly available from cache instead of reloading from disk.

        print("[DataManager] Session data trimmed for \(trimmedSessions.count) sessions")
    }

    // MARK: - Diff Preloading

    /// Preloads diffs for the first N recent sessions in background
    /// This ensures diffs are ready when user navigates to recent sessions
    /// Only queues sessions that haven't been preloaded yet
    private func preloadRecentSessionDiffs(sessions: [Session], count: Int = 5) {
        // Get session IDs that haven't been preloaded yet
        var sessionIdsToPreload: [String] = []

        for session in sessions.prefix(count) {
            // Skip if already preloaded or currently in memory
            if preloadedSessionDiffIds.contains(session.id) {
                continue
            }
            if DiffStorageManager.shared.hasCachedDiffsInMemory(forSession: session.id) {
                preloadedSessionDiffIds.insert(session.id)
                continue
            }
            // Only preload sessions that might have diffs (have the flag set or are in a terminal state)
            if session.hasCachedDiffsFlag || session.state.isTerminal {
                sessionIdsToPreload.append(session.id)
                preloadedSessionDiffIds.insert(session.id)
            }
        }

        // Preload all at once in background
        if !sessionIdsToPreload.isEmpty {
            DiffStorageManager.shared.preloadDiffs(forSessions: sessionIdsToPreload)
        }

        // Prune set if it exceeds the limit to prevent unbounded growth
        if preloadedSessionDiffIds.count > maxTrackingSetSize {
            preloadedSessionDiffIds.removeAll()
        }
    }
}
