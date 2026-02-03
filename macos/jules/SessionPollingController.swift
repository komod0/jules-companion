import Foundation
import Combine

@MainActor
class SessionPollingController {
    private let sessionRepository: SessionRepository
    private weak var dataManager: DataManager?
    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Unified Polling Timer

    // Single timer with 5-second base interval
    // Different operations run on different tick cycles:
    // - Active sessions: every 2 ticks (10s)
    // - Backfill: every 6 ticks (30s)
    // - Completed sessions: every 12 ticks (60s)
    // - Stale session check: every 120 ticks (10 minutes)
    private static let baseInterval: TimeInterval = 5
    private static let activeSessionsTicks = 2      // 10s
    private static let backfillTicks = 6            // 30s
    private static let completedSessionsTicks = 12  // 60s
    private static let staleSessionCheckTicks = 120 // 10 minutes
    private static let initialBackfillTicks = 2     // 10s delay before first backfill

    nonisolated(unsafe) private var unifiedTimer: Timer?
    private var tickCount: Int = 0
    private var isPaused: Bool = false
    private var hasRunInitialBackfill: Bool = false

    init(sessionRepository: SessionRepository, dataManager: DataManager) {
        self.sessionRepository = sessionRepository
        self.dataManager = dataManager
    }

    func startPolling() {
        stopPolling()
        tickCount = 0
        hasRunInitialBackfill = false
        isPaused = false

        // Single unified timer fires every 5 seconds
        unifiedTimer = Timer.scheduledTimer(withTimeInterval: Self.baseInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.onTick()
            }
        }
    }

    private func onTick() async {
        guard !isPaused else { return }

        tickCount += 1

        // Capture the current tick value for this invocation.
        // This is critical because multiple onTick() tasks can run concurrently
        // (timer fires every 5s regardless of whether previous tick completed).
        // Without capturing, async operations that take longer than 5s would see
        // a stale tickCount after resuming, causing missed or duplicate polls.
        let currentTick = tickCount

        // Initial backfill after 10 seconds (2 ticks)
        if !hasRunInitialBackfill && currentTick >= Self.initialBackfillTicks {
            hasRunInitialBackfill = true
            await backfillActivities()
        }

        // Active sessions: every 3 ticks (15s)
        if currentTick % Self.activeSessionsTicks == 0 {
            await pollActiveSessions()
        }

        // Backfill: every 6 ticks (30s)
        if currentTick % Self.backfillTicks == 0 {
            await backfillActivities()
        }

        // Completed sessions: every 12 ticks (60s)
        if currentTick % Self.completedSessionsTicks == 0 {
            await pollCompletedSessions()
        }

        // Stale session check: every 120 ticks (10 minutes)
        // Marks active sessions that haven't had updates for over an hour as completedUnknown
        if currentTick % Self.staleSessionCheckTicks == 0 {
            await checkStaleSessions()
        }
    }

    nonisolated func stopPolling() {
        unifiedTimer?.invalidate()
        unifiedTimer = nil
    }

    /// Pause all polling operations (e.g., during heavy UI operations)
    func pausePolling() {
        isPaused = true
    }

    /// Resume polling operations
    func resumePolling() {
        isPaused = false
    }

    private func pollActiveSessions() async {
        guard let dataManager = dataManager else { return }
        await sessionRepository.refresh()

        // Start with the top 5 active sessions
        let topActiveSessions = dataManager.sessions.prefix(5).filter { !$0.state.isTerminal }
        var idsToFetch = Set(topActiveSessions.map { $0.id })

        // Always include the currently active session window, if it exists and is not already in the list
        if let activeId = dataManager.activeSessionId, !idsToFetch.contains(activeId) {
            idsToFetch.insert(activeId)
        }

        if !idsToFetch.isEmpty {
            await dataManager.fetchActivities(for: Array(idsToFetch))
        }
    }

    private func pollCompletedSessions() async {
        guard let dataManager = dataManager else { return }
        await sessionRepository.refresh()
        // Only poll completed/completedUnknown sessions that still need stats (don't have cached git stats yet)
        let completedSessions = dataManager.sessions.prefix(5).filter {
            ($0.state == .completed || $0.state == .completedUnknown) && $0.needsActivityFetchForStats
        }
        let idsToFetch = completedSessions.map { $0.id }
        if !idsToFetch.isEmpty {
            await dataManager.fetchActivities(for: idsToFetch)
        }
    }

    private func backfillActivities() async {
        guard let dataManager = dataManager else { return }

        // Query the database directly for sessions that need backfilling.
        // This bypasses the in-memory limit (default 25) to find older sessions
        // that haven't had their activities fetched or git stats computed.
        // Skip the first 5 sessions (handled by pollActiveSessions/pollCompletedSessions)
        // and process up to 3 at a time for better performance.
        let sessionsToBackfill = await sessionRepository.getSessionsNeedingBackfill(offset: 5, limit: 3)

        let idsToBackfill = sessionsToBackfill.map { $0.id }
        if !idsToBackfill.isEmpty {
            await dataManager.fetchActivities(for: idsToBackfill)
        }
    }

    private func checkStaleSessions() async {
        // Check for sessions that have been active for too long without updates.
        // For each stale session, verifies with the API:
        // - If session was deleted (404), removes it from local DB
        // - If session state changed on server, updates local state
        let processedCount = await sessionRepository.markStaleSessions()
        if processedCount > 0 {
            print("📋 Processed \(processedCount) stale session(s)")
        }
    }
}
