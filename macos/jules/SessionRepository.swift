import Foundation
import Combine
import GRDB

// --- Sync State ---
enum SyncState: Equatable {
    case idle
    case loading
    case error(String)
    case loadedAll
}

class SessionRepository: ObservableObject {
    private let dbQueue: DatabasePool // Changed to DatabasePool
    private let apiService: APIService
    private let pageSize = 25

    // Publishers
    var sessionsPublisher: AnyPublisher<[Session], Error> {
        sessionsSubject.eraseToAnyPublisher()
    }
    private let sessionsSubject = CurrentValueSubject<[Session], Error>([])

    @Published var syncState: SyncState = .idle
    @Published var limit: Int = 25

    private var cancellables: Set<AnyCancellable> = []

    // Pagination Token
    private var nextPageToken: String? {
        get { UserDefaults.standard.string(forKey: "session_next_page_token") }
        set { UserDefaults.standard.set(newValue, forKey: "session_next_page_token") }
    }
    private var hasPerformedInitialFetch = false
    private let maxRefreshRetries = 3

    // Rate limiting for session list API
    private var lastRefreshTime: Date?
    private var isRefreshInProgress = false
    private let minimumRefreshInterval: TimeInterval = 5  // Minimum seconds between API calls

    init(dbQueue: DatabasePool, apiService: APIService) {
        self.dbQueue = dbQueue
        self.apiService = apiService
        self.limit = pageSize

        setupObservation()

        // Validate database integrity on init
        Task {
            await validateAndRepairDatabase()
        }
    }

    // MARK: - Database Validation & Repair

    /// Validates the database for corrupted sessions and repairs if needed
    func validateAndRepairDatabase() async {
        do {
            let corruptedCount = try await dbQueue.read { db -> Int in
                // Check for sessions with empty or null JSON data
                let corruptedRows = try Row.fetchAll(db, sql: """
                    SELECT COUNT(*) as count FROM session
                    WHERE json IS NULL OR json = '' OR length(json) < 10
                """)
                return corruptedRows.first?["count"] as? Int ?? 0
            }

            if corruptedCount > 0 {
                print("Warning: Found \(corruptedCount) corrupted sessions. Repairing...")
                await repairCorruptedSessions()
            }

            // Also check if we have sessions but they're all somehow invalid
            let validationResult = try await validateSessionsIntegrity()
            if !validationResult.isValid {
                print("Warning: Session integrity check failed: \(validationResult.reason). Force refreshing...")
                await forceRefreshFromAPI()
            }
        } catch {
            print("Error validating database: \(error)")
        }
    }

    private struct ValidationResult {
        let isValid: Bool
        let reason: String
    }

    private func validateSessionsIntegrity() async throws -> ValidationResult {
        return try await dbQueue.read { db in
            let totalCount = try Session.fetchCount(db)

            // If we have no sessions, that's okay - might be new user
            if totalCount == 0 {
                return ValidationResult(isValid: true, reason: "No sessions")
            }

            // Try to fetch all sessions to verify they're decodable
            do {
                let sessions = try Session.limit(min(totalCount, 100)).fetchAll(db)

                // Check for sessions with missing critical data
                let invalidSessions = sessions.filter { session in
                    session.id.isEmpty || session.prompt.isEmpty
                }

                if invalidSessions.count > totalCount / 2 {
                    // More than 50% of sessions are invalid
                    return ValidationResult(isValid: false, reason: "More than 50% of sessions have missing data")
                }

                return ValidationResult(isValid: true, reason: "OK")
            } catch {
                // If we can't even decode the sessions, the data is corrupted
                return ValidationResult(isValid: false, reason: "Failed to decode sessions: \(error)")
            }
        }
    }

    private func repairCorruptedSessions() async {
        do {
            // Delete corrupted sessions
            try await dbQueue.write { db in
                try db.execute(sql: """
                    DELETE FROM session
                    WHERE json IS NULL OR json = '' OR length(json) < 10
                """)
            }
            print("Corrupted sessions removed. Refreshing from API...")

            // Force refresh from API to get clean data
            await forceRefreshFromAPI()
        } catch {
            print("Error repairing corrupted sessions: \(error)")
        }
    }

    /// Force refresh from API, clearing local cache but preserving activities
    func forceRefreshFromAPI() async {
        // Prevent concurrent refresh calls (shared with refresh())
        guard !isRefreshInProgress else {
            #if DEBUG
            print("⏭️ forceRefreshFromAPI() skipped - refresh already in progress")
            #endif
            return
        }

        // Rate limit: respect minimum interval between API calls
        if let lastRefresh = lastRefreshTime {
            let elapsed = Date().timeIntervalSince(lastRefresh)
            if elapsed < minimumRefreshInterval {
                #if DEBUG
                print("⏭️ forceRefreshFromAPI() skipped - rate limited (\(String(format: "%.1f", elapsed))s < \(minimumRefreshInterval)s)")
                #endif
                return
            }
        }

        isRefreshInProgress = true
        defer { isRefreshInProgress = false }

        // Reset pagination state
        nextPageToken = nil
        hasPerformedInitialFetch = false

        await MainActor.run {
            self.limit = pageSize
            self.syncState = .loading
        }

        do {
            var response: ListSessionsResponse
            var retryCount = 0
            let maxRetries = maxRefreshRetries

            // Fetch with retry loop for empty responses
            while true {
                response = try await apiService.fetchSessions(pageSize: pageSize)
                lastRefreshTime = Date()  // Update after each successful fetch

                // If we got sessions or exhausted retries, break out of retry loop
                if !(response.sessions ?? []).isEmpty || retryCount >= maxRetries {
                    break
                }

                retryCount += 1
                print("Warning: API returned empty sessions (attempt \(retryCount)/\(maxRetries)). Retrying in 2s...")
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            }

            self.nextPageToken = response.nextPageToken

            try await dbQueue.write { db in
                // Get set of incoming session IDs for cleanup
                let incomingSessions = response.sessions ?? []
                let incomingIds = Set(incomingSessions.map { $0.id })

                // MEMORY FIX: Only fetch existing sessions that match incoming IDs
                // instead of fetching ALL sessions into memory
                let existingSessions = try Session
                    .filter(incomingIds.contains(Session.Columns.id))
                    .fetchAll(db)
                let existingSessionsMap = Dictionary(
                    existingSessions.map { ($0.id, $0) },
                    uniquingKeysWith: { first, _ in first }
                )

                // Use UPSERT pattern: merge incoming sessions with existing data
                for session in incomingSessions {
                    var sessionToSave = session

                    // Preserve client-side only properties from existing session
                    if let existing = existingSessionsMap[session.id] {
                        if sessionToSave.activities == nil {
                            sessionToSave.activities = existing.activities
                        }
                        if sessionToSave.lastActivityPollTime == nil {
                            sessionToSave.lastActivityPollTime = existing.lastActivityPollTime
                        }
                        if sessionToSave.viewedPostCompletionAt == nil {
                            sessionToSave.viewedPostCompletionAt = existing.viewedPostCompletionAt
                        }
                        // Preserve cached git stats
                        if sessionToSave.cachedGitStatsSummary == nil {
                            sessionToSave.cachedGitStatsSummary = existing.cachedGitStatsSummary
                        }
                        // Note: Don't load cachedLatestDiffs here - let DiffStorageManager's
                        // NSCache handle diff caching to avoid duplicating large diffs in memory
                        if sessionToSave.cachedGitStatsUpdateTime == nil {
                            sessionToSave.cachedGitStatsUpdateTime = existing.cachedGitStatsUpdateTime
                        }
                    }

                    // Use saveWithDiffs to handle both session and diff records
                    try sessionToSave.saveWithDiffs(db)
                }

                // Handle sessions that are no longer in the API response
                // Instead of deleting active sessions, mark them as completedUnknown
                // This handles the case where the server deleted a session that was still running
                let existingIds = try String.fetchAll(db, Session.select(Session.Columns.id))
                var deletedSessionIds: [String] = []
                for existingId in existingIds {
                    if !incomingIds.contains(existingId) {
                        // Fetch the existing session to check its state
                        if var existingSession = try Session.fetchOne(db, key: existingId) {
                            if existingSession.state.isActive {
                                // Session was active but is no longer on server - mark as completedUnknown
                                print("⚠️ Session \(existingId.prefix(8)) was active (\(existingSession.state)) but missing from server - marking as completedUnknown")
                                existingSession.state = .completedUnknown
                                try existingSession.saveWithDiffs(db)
                            } else {
                                // Session was already in a terminal state - safe to delete
                                try Session.deleteOne(db, key: existingId)
                                deletedSessionIds.append(existingId)
                            }
                        }
                    }
                }

                // Clean up diff files for deleted sessions (outside of DB transaction)
                if !deletedSessionIds.isEmpty {
                    DiffStorageManager.shared.deleteDiffs(forSessions: deletedSessionIds)
                }
            }

            await MainActor.run {
                self.syncState = .idle
            }
        } catch {
            print("Force refresh error: \(error)")
            await MainActor.run {
                self.syncState = .error(error.localizedDescription)
            }
        }
    }

    private func setupObservation() {
        // Observe 'limit' and switch to a new database observation when it changes.
        $limit
            .removeDuplicates()
            .map { [weak self] currentLimit -> AnyPublisher<[Session], Error> in
                guard let self = self else { return Empty().eraseToAnyPublisher() }

                let observation = ValueObservation.tracking { db in
                    try Session
                        .order(Column("createTime").desc)
                        .limit(currentLimit)
                        .fetchAll(db)
                }
                // ValueObservation publisher
                return observation.publisher(in: self.dbQueue).eraseToAnyPublisher()
            }
            .switchToLatest() // Cancels previous observation when limit changes
            // CRITICAL FIX: GRDB ValueObservation emits on every database transaction
            // that *could* affect observed data, even if the data hasn't changed.
            // Without deduplication, this causes ~1000 SwiftUI view updates per second
            // when the DiffLoader animation is visible, because every Metal frame
            // triggers a database read that emits identical session data.
            // Session conforms to Equatable, so removeDuplicates() compares arrays.
            .removeDuplicates()
            .sink(
                receiveCompletion: { completion in
                    if case .failure(let error) = completion {
                        print("Database observation error: \(error)")
                    }
                },
                receiveValue: { [weak self] sessions in
                    self?.sessionsSubject.send(sessions)
                }
            )
            .store(in: &cancellables)
    }

    func refresh(bypassRateLimit: Bool = false) async {
        // Prevent concurrent refresh calls
        guard !isRefreshInProgress else {
            #if DEBUG
            print("⏭️ SessionRepository.refresh() skipped - already in progress")
            #endif
            return
        }

        // Rate limit: skip if called too soon after last refresh (unless no data yet)
        // Can be bypassed for critical operations like after creating a new session
        if !bypassRateLimit, let lastRefresh = lastRefreshTime {
            let elapsed = Date().timeIntervalSince(lastRefresh)
            if elapsed < minimumRefreshInterval {
                #if DEBUG
                print("⏭️ SessionRepository.refresh() skipped - rate limited (\(String(format: "%.1f", elapsed))s < \(minimumRefreshInterval)s)")
                #endif
                return
            }
        }

        if !hasPerformedInitialFetch {
            hasPerformedInitialFetch = true
            let count = (try? await dbQueue.read { db in try Session.fetchCount(db) }) ?? 0
            if count > 0 {
                syncState = .idle // We have local data, no need to fetch on first launch
                return
            }
        }

        isRefreshInProgress = true
        defer { isRefreshInProgress = false }

        syncState = .loading
        do {
            let response = try await apiService.fetchSessions(pageSize: pageSize)
            lastRefreshTime = Date()  // Update after successful fetch
            self.nextPageToken = response.nextPageToken

            try await dbQueue.write { db in
                // Batch fetch existing sessions for efficient lookup
                let sessionIds = (response.sessions ?? []).map { $0.id }
                let existingSessions = try Session
                    .filter(sessionIds.contains(Session.Columns.id))
                    .fetchAll(db)
                let existingSessionsMap = Dictionary(
                    existingSessions.map { ($0.id, $0) },
                    uniquingKeysWith: { first, _ in first }
                )

                for session in response.sessions ?? [] {
                    var newSession = session

                    if let existing = existingSessionsMap[session.id] {
                        // Preserve client-side only properties
                        if newSession.activities == nil {
                            newSession.activities = existing.activities
                        }
                        if newSession.lastActivityPollTime == nil {
                            newSession.lastActivityPollTime = existing.lastActivityPollTime
                        }
                        if newSession.viewedPostCompletionAt == nil {
                            newSession.viewedPostCompletionAt = existing.viewedPostCompletionAt
                        }
                        // Preserve cached git stats
                        if newSession.cachedGitStatsSummary == nil {
                            newSession.cachedGitStatsSummary = existing.cachedGitStatsSummary
                        }
                        // Note: Don't load cachedLatestDiffs here - let DiffStorageManager's
                        // NSCache handle diff caching to avoid duplicating large diffs in memory
                        if newSession.cachedGitStatsUpdateTime == nil {
                            newSession.cachedGitStatsUpdateTime = existing.cachedGitStatsUpdateTime
                        }
                    }

                    try newSession.saveWithDiffs(db)
                }
            }
            syncState = .idle
        } catch {
            print("Refresh error: \(error)")
            syncState = .error(error.localizedDescription)
        }
    }

    // Logic to handle "Load More" from UI
    func loadMore() {
        // Don't do anything if already loading or loaded all (unless we are just increasing DB limit?)
        // But if we are loading from API, we might still want to increase limit if DB has more data?
        // Let's keep it simple.
        if case .loading = syncState { return }

        Task(priority: .userInitiated) {
            // Check if DB has more items than current limit
            let totalCount = try await dbQueue.read { db in
                try Session.fetchCount(db)
            }

            if totalCount > limit {
                // We have more data in DB that is not shown yet.
                // Just increase the limit.
                await MainActor.run {
                    self.limit += self.pageSize
                }
                // If the increase still leaves us with totalCount <= newLimit, we might want to pre-fetch?
                // But the user will scroll again and trigger loadMore again if needed.
            } else {
                // DB is exhausted (or we are showing everything).
                // Fetch more from API in the background.
                await fetchMoreDataInBackground()
            }
        }
    }

    func fetchMoreData(bypassRateLimit: Bool = false) async {
        guard syncState != .loading && syncState != .loadedAll else { return }

        // Rate limit pagination calls (unless bypassed for explicit user action)
        if !bypassRateLimit, let lastRefresh = lastRefreshTime {
            let elapsed = Date().timeIntervalSince(lastRefresh)
            if elapsed < minimumRefreshInterval {
                #if DEBUG
                print("⏭️ fetchMoreData() skipped - rate limited (\(String(format: "%.1f", elapsed))s)")
                #endif
                return
            }
        }

        guard let token = nextPageToken else {
            syncState = .loadedAll
            return
        }

        syncState = .loading
        do {
            let response = try await apiService.fetchSessions(pageSize: pageSize, pageToken: token)
            lastRefreshTime = Date()  // Update after successful fetch
            self.nextPageToken = response.nextPageToken

            try await dbQueue.write { db in
                // Batch fetch existing sessions for efficient lookup
                let sessionIds = (response.sessions ?? []).map { $0.id }
                let existingSessions = try Session
                    .filter(sessionIds.contains(Session.Columns.id))
                    .fetchAll(db)
                let existingSessionsMap = Dictionary(
                    existingSessions.map { ($0.id, $0) },
                    uniquingKeysWith: { first, _ in first }
                )

                for session in response.sessions ?? [] {
                    var newSession = session

                    if let existing = existingSessionsMap[session.id] {
                        // Preserve client-side only properties
                        if newSession.activities == nil {
                            newSession.activities = existing.activities
                        }
                        if newSession.lastActivityPollTime == nil {
                            newSession.lastActivityPollTime = existing.lastActivityPollTime
                        }
                        if newSession.viewedPostCompletionAt == nil {
                            newSession.viewedPostCompletionAt = existing.viewedPostCompletionAt
                        }
                        // Preserve cached git stats
                        if newSession.cachedGitStatsSummary == nil {
                            newSession.cachedGitStatsSummary = existing.cachedGitStatsSummary
                        }
                        // Note: Don't load cachedLatestDiffs here - let DiffStorageManager's
                        // NSCache handle diff caching to avoid duplicating large diffs in memory
                        if newSession.cachedGitStatsUpdateTime == nil {
                            newSession.cachedGitStatsUpdateTime = existing.cachedGitStatsUpdateTime
                        }
                    }

                    try newSession.saveWithDiffs(db)
                }
            }

            // After fetching, we should ensure the limit is high enough to show the new items?
            // Usually, we want the limit to expand to include the new items.
            // If we fetched `pageSize` items, and we want to show them, we should increase limit.
            // But usually infinite scroll increases limit first, finds no data, then fetches.
            // If we fetch data, it goes into DB. But if limit is restricted, user won't see them.
            // So we should increase limit to cover the new total count or at least by pageSize.

            let newTotal = try await dbQueue.read { try Session.fetchCount($0) }
            await MainActor.run {
                if self.limit < newTotal {
                    self.limit = newTotal // Or just increase by pageSize? Let's just show everything we have up to new total.
                    // Or strictly: limit += pageSize.
                    // If we just fetched 25 items, we want to show them.
                    self.limit += self.pageSize
                }

                if response.nextPageToken == nil {
                    self.syncState = .loadedAll
                } else {
                    self.syncState = .idle
                }
            }

        } catch {
             print("Fetch more error: \(error)")
             syncState = .error(error.localizedDescription)
        }
    }

    /// Fetches more data in the background without blocking the UI
    /// This version updates the loading state immediately and performs DB operations asynchronously
    private func fetchMoreDataInBackground() async {
        guard syncState != .loading && syncState != .loadedAll else { return }

        guard let token = nextPageToken else {
            await MainActor.run {
                self.syncState = .loadedAll
            }
            return
        }

        // Update state immediately on main actor
        await MainActor.run {
            self.syncState = .loading
        }

        // Perform network and DB operations in background
        do {
            let response = try await apiService.fetchSessions(pageSize: pageSize, pageToken: token)
            lastRefreshTime = Date()  // Update after successful fetch
            let pageToken = response.nextPageToken

            // Database write on background thread
            try await dbQueue.write { db in
                // Batch fetch existing sessions for efficient lookup
                let sessionIds = (response.sessions ?? []).map { $0.id }
                let existingSessions = try Session
                    .filter(sessionIds.contains(Session.Columns.id))
                    .fetchAll(db)
                let existingSessionsMap = Dictionary(
                    existingSessions.map { ($0.id, $0) },
                    uniquingKeysWith: { first, _ in first }
                )

                for session in response.sessions ?? [] {
                    var newSession = session

                    if let existing = existingSessionsMap[session.id] {
                        // Preserve client-side only properties
                        if newSession.activities == nil {
                            newSession.activities = existing.activities
                        }
                        if newSession.lastActivityPollTime == nil {
                            newSession.lastActivityPollTime = existing.lastActivityPollTime
                        }
                        if newSession.viewedPostCompletionAt == nil {
                            newSession.viewedPostCompletionAt = existing.viewedPostCompletionAt
                        }
                        // Preserve cached git stats
                        if newSession.cachedGitStatsSummary == nil {
                            newSession.cachedGitStatsSummary = existing.cachedGitStatsSummary
                        }
                        // Note: Don't load cachedLatestDiffs here - let DiffStorageManager's
                        // NSCache handle diff caching to avoid duplicating large diffs in memory
                        if newSession.cachedGitStatsUpdateTime == nil {
                            newSession.cachedGitStatsUpdateTime = existing.cachedGitStatsUpdateTime
                        }
                    }

                    try newSession.saveWithDiffs(db)
                }
            }

            // Read new total in background
            let newTotal = try await dbQueue.read { try Session.fetchCount($0) }

            // Update state on main actor only after all work is done
            await MainActor.run {
                self.nextPageToken = pageToken
                if self.limit < newTotal {
                    self.limit += self.pageSize
                }

                if pageToken == nil {
                    self.syncState = .loadedAll
                } else {
                    self.syncState = .idle
                }
            }

        } catch {
             print("Fetch more error: \(error)")
             await MainActor.run {
                 self.syncState = .error(error.localizedDescription)
             }
        }
    }

    func updateSession(_ session: Session) async {
        do {
            try await dbQueue.write { db in
                var sessionToSave = session
                try sessionToSave.saveWithDiffs(db)
            }
        } catch {
            print("Error updating session: \(error)")
        }
    }

    /// Gets the newest session directly from the database (by createTime descending).
    /// This is useful when you need the most recent session immediately after a write,
    /// before the async ValueObservation has emitted the update.
    func getNewestSession() async -> Session? {
        do {
            return try await dbQueue.read { db in
                try Session
                    .order(Column("createTime").desc)
                    .limit(1)
                    .fetchOne(db)
            }
        } catch {
            print("Error fetching newest session: \(error)")
            return nil
        }
    }

    /// Queries sessions that need backfilling (activity fetching) from the database.
    /// This bypasses the in-memory limit to find older sessions that haven't been processed.
    /// - Parameters:
    ///   - offset: Number of sessions to skip (e.g., skip first 5 that are actively polled)
    ///   - limit: Maximum number of sessions to return
    /// - Returns: Sessions that need activity fetching, ordered by createTime descending
    func getSessionsNeedingBackfill(offset: Int, limit: Int) async -> [Session] {
        do {
            return try await dbQueue.read { db in
                // MEMORY FIX: Don't load ALL sessions into memory.
                // Instead, process in batches to find sessions needing backfill.
                // This prevents 50-100MB memory spikes when there are 100+ sessions.
                var results: [Session] = []
                let batchSize = 20
                var currentOffset = offset

                while results.count < limit {
                    // Fetch a small batch at a time
                    let batch = try Session
                        .order(Column("createTime").desc)
                        .limit(batchSize, offset: currentOffset)
                        .fetchAll(db)

                    // If no more sessions, we're done
                    if batch.isEmpty { break }

                    // Filter this batch for sessions needing backfill
                    let matching = batch.filter { $0.activities == nil || $0.needsActivityFetchForStats }
                    results.append(contentsOf: matching)

                    currentOffset += batchSize

                    // Safety limit: don't scan more than 200 sessions
                    if currentOffset > offset + 200 { break }
                }

                return Array(results.prefix(limit))
            }
        } catch {
            print("Error querying sessions for backfill: \(error)")
            return []
        }
    }

    /// Returns the total count of sessions in the database
    func getTotalSessionCount() async -> Int {
        do {
            return try await dbQueue.read { db in
                try Session.fetchCount(db)
            }
        } catch {
            print("Error counting sessions: \(error)")
            return 0
        }
    }

    // MARK: - Stale Session Detection

    /// Checks for sessions that have been in an active state for too long without updates.
    /// For each stale session, verifies with the API:
    /// - If session was deleted (404), removes it from local DB
    /// - If session state changed on server, updates local state
    /// - If session is still active on server but stale locally, updates with fresh data
    ///
    /// This handles:
    /// - Sessions deleted from server that we didn't receive deletion for
    /// - Sessions that got stuck and never received completion events
    /// - Network issues that prevented us from receiving session updates
    ///
    /// Returns the number of sessions that were deleted or updated
    @discardableResult
    func markStaleSessions() async -> Int {
        // First, find stale sessions from the database
        let staleSessions: [Session]
        do {
            staleSessions = try await dbQueue.read { db -> [Session] in
                let activeStates = [
                    SessionState.queued.rawValue,
                    SessionState.planning.rawValue,
                    SessionState.inProgress.rawValue,
                    SessionState.awaitingPlanApproval.rawValue,
                    SessionState.awaitingUserFeedback.rawValue
                ]

                let activeSessions = try Session
                    .filter(activeStates.contains(Session.Columns.state))
                    .fetchAll(db)

                // Filter to only stale sessions
                return activeSessions.filter { $0.isStaleActive }
            }
        } catch {
            print("Error querying stale sessions: \(error)")
            return 0
        }

        guard !staleSessions.isEmpty else { return 0 }

        var processedCount = 0

        // For each stale session, verify with the API
        for session in staleSessions {
            do {
                // Try to fetch the session from the API
                let freshSession = try await apiService.fetchSession(sessionId: session.id)

                // Session exists on server - update our local copy with fresh state
                try await dbQueue.write { db in
                    var sessionToSave = freshSession

                    // Preserve client-side only properties
                    if let existing = try Session.fetchOne(db, key: session.id) {
                        sessionToSave.activities = existing.activities
                        sessionToSave.lastActivityPollTime = existing.lastActivityPollTime
                        sessionToSave.viewedPostCompletionAt = existing.viewedPostCompletionAt
                        sessionToSave.cachedGitStatsSummary = existing.cachedGitStatsSummary
                        sessionToSave.cachedGitStatsUpdateTime = existing.cachedGitStatsUpdateTime
                        sessionToSave.hasCachedDiffsFlag = existing.hasCachedDiffsFlag
                    }

                    try sessionToSave.saveWithDiffs(db)
                }

                if freshSession.state != session.state {
                    print("📋 Session \(session.id.prefix(8)) state updated from \(session.state) to \(freshSession.state)")
                    processedCount += 1
                }

            } catch APIError.notFound {
                // Session was deleted from server - remove locally
                print("🗑️ Session \(session.id.prefix(8)) no longer exists on server - deleting locally")

                do {
                    try await dbQueue.write { db in
                        try Session.deleteOne(db, key: session.id)
                    }
                    // Clean up diff files
                    DiffStorageManager.shared.deleteDiffs(forSession: session.id)
                    processedCount += 1
                } catch {
                    print("Error deleting session \(session.id.prefix(8)): \(error)")
                }

            } catch {
                // Other errors (network, etc.) - log but don't take action
                // The session will be checked again on the next cycle
                print("⚠️ Failed to verify session \(session.id.prefix(8)): \(error.localizedDescription)")
            }
        }

        return processedCount
    }
}
