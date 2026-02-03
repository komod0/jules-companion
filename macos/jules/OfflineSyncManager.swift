import Foundation
import Combine
import GRDB

/// Manages offline session creation and syncs pending sessions when connectivity is restored
@MainActor
class OfflineSyncManager: ObservableObject {
    private let dbQueue: DatabasePool
    private let apiService: APIService
    private let sourceRepository: SourceRepository
    private let networkMonitor: NetworkMonitor

    /// Number of pending sessions waiting to be synced
    @Published private(set) var pendingSessionCount: Int = 0

    /// Whether we're currently syncing pending sessions
    @Published private(set) var isSyncing: Bool = false

    /// Last sync error message (if any)
    @Published private(set) var lastSyncError: String?

    /// Publisher that emits when a pending session is successfully synced
    let sessionSyncedPublisher = PassthroughSubject<Void, Never>()

    private var cancellables: Set<AnyCancellable> = []

    init(dbQueue: DatabasePool, apiService: APIService, sourceRepository: SourceRepository, networkMonitor: NetworkMonitor = .shared) {
        self.dbQueue = dbQueue
        self.apiService = apiService
        self.sourceRepository = sourceRepository
        self.networkMonitor = networkMonitor

        setupSubscriptions()
        Task {
            await refreshPendingCount()
            // If we're already online when initializing, check for pending sessions to sync
            // This handles the case where connectivity was restored before we subscribed to the publisher
            if networkMonitor.isConnected {
                await syncPendingSessions()
            }
        }
    }

    private func setupSubscriptions() {
        // Listen for connectivity restored events
        networkMonitor.connectivityRestoredPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.syncPendingSessions()
                }
            }
            .store(in: &cancellables)

        // Observe pending sessions table for count updates
        let observation = ValueObservation.tracking { db in
            try PendingSession.fetchCount(db)
        }

        observation.publisher(in: dbQueue)
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { [weak self] count in
                    self?.pendingSessionCount = count
                }
            )
            .store(in: &cancellables)
    }

    /// Refreshes the count of pending sessions
    func refreshPendingCount() async {
        do {
            let count = try await dbQueue.read { db in
                try PendingSession.fetchCount(db)
            }
            self.pendingSessionCount = count
        } catch {
            print("❌ Error counting pending sessions: \(error)")
        }
    }

    /// Queues a session for creation when connectivity is restored
    func queuePendingSession(sourceName: String, branchName: String, prompt: String) async throws {
        let pendingSession = PendingSession(
            sourceName: sourceName,
            branchName: branchName,
            prompt: prompt
        )

        do {
            try await dbQueue.write { db in
                try pendingSession.save(db)
            }
            print("📝 Queued pending session: \(pendingSession.id)")
            await refreshPendingCount()
        } catch {
            print("❌ Error queueing pending session: \(error)")
            throw error
        }
    }

    /// Returns all pending sessions
    func getPendingSessions() async -> [PendingSession] {
        do {
            return try await dbQueue.read { db in
                try PendingSession.order(Column("createdAt").asc).fetchAll(db)
            }
        } catch {
            print("❌ Error fetching pending sessions: \(error)")
            return []
        }
    }

    /// Attempts to sync all pending sessions
    func syncPendingSessions() async {
        guard networkMonitor.isConnected else {
            print("⏸️ Cannot sync pending sessions - offline")
            return
        }

        guard !isSyncing else {
            print("⏸️ Already syncing pending sessions")
            return
        }

        let pendingSessions = await getPendingSessions()
        guard !pendingSessions.isEmpty else {
            return
        }

        print("🔄 Syncing \(pendingSessions.count) pending session(s)...")
        isSyncing = true
        lastSyncError = nil

        var successCount = 0
        var failedSessions: [PendingSession] = []

        for pendingSession in pendingSessions {
            do {
                // Get the source from repository
                guard let source = await sourceRepository.getSource(byName: pendingSession.sourceName) else {
                    print("⚠️ Source not found for pending session: \(pendingSession.sourceName)")
                    failedSessions.append(pendingSession)
                    continue
                }

                // Try to create the session
                let createdSession = try await apiService.createSession(
                    source: source,
                    branchName: pendingSession.branchName,
                    prompt: pendingSession.prompt
                )

                if createdSession != nil {
                    // Remove from pending queue
                    try await dbQueue.write { db in
                        try PendingSession.deleteOne(db, key: pendingSession.id)
                    }
                    successCount += 1
                    print("✅ Synced pending session: \(pendingSession.id)")
                    sessionSyncedPublisher.send()
                } else {
                    print("❌ Failed to sync pending session (API returned false): \(pendingSession.id)")
                    failedSessions.append(pendingSession)
                }
            } catch {
                print("❌ Error syncing pending session \(pendingSession.id): \(error)")
                failedSessions.append(pendingSession)
                lastSyncError = error.localizedDescription
            }
        }

        isSyncing = false
        await refreshPendingCount()

        if successCount > 0 {
            print("✅ Successfully synced \(successCount) pending session(s)")
            FlashMessageManager.shared.show(
                message: "Synced \(successCount) pending task\(successCount == 1 ? "" : "s")",
                type: .success
            )
        }

        if !failedSessions.isEmpty {
            print("⚠️ \(failedSessions.count) pending session(s) failed to sync")
            FlashMessageManager.shared.show(
                message: "\(failedSessions.count) task\(failedSessions.count == 1 ? "" : "s") failed to sync",
                type: .error
            )
        }
    }

    /// Removes a pending session (e.g., if user cancels it)
    func removePendingSession(_ pendingSession: PendingSession) async {
        do {
            try await dbQueue.write { db in
                try PendingSession.deleteOne(db, key: pendingSession.id)
            }
            await refreshPendingCount()
        } catch {
            print("❌ Error removing pending session: \(error)")
        }
    }

    /// Removes all pending sessions
    func clearAllPendingSessions() async {
        do {
            try await dbQueue.write { db in
                try PendingSession.deleteAll(db)
            }
            await refreshPendingCount()
        } catch {
            print("❌ Error clearing pending sessions: \(error)")
        }
    }
}
