import Foundation
import Compression

// MARK: - Notification for Diff Loading
extension Notification.Name {
    /// Posted when diffs finish loading for a session. The userInfo contains "sessionId" key.
    static let diffsDidLoad = Notification.Name("DiffStorageManager.diffsDidLoad")
}

/// Manages storage for cached diffs using a separate SQLite database.
/// Uses an in-memory cache (NSCache) for instant access after first load.
/// Database provides fast indexed lookups and memory-mapped I/O.
final class DiffStorageManager: NSObject, NSCacheDelegate {
    static let shared = DiffStorageManager()

    private let fileManager = FileManager.default

    /// In-memory cache for loaded diffs - avoids repeated database reads
    /// NSCache automatically evicts entries under memory pressure
    private let memoryCache = NSCache<NSString, CachedDiffArray>()

    /// Background queue for async diff loading
    private let loadQueue = DispatchQueue(label: "com.jules.diff-loading", qos: .userInitiated)

    /// Tracks sessions currently being loaded to avoid duplicate concurrent loads
    private var loadingSessionIds = Set<String>()
    private let loadingLock = NSLock()

    /// Tracks approximate current cache memory usage for diagnostics
    private var estimatedCacheMemoryBytes: Int = 0
    private let cacheMemoryLock = NSLock()

    /// Legacy file-based storage directory (for migration)
    private lazy var legacyDiffsDirectory: URL? = {
        do {
            let appSupportURL = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            ).appendingPathComponent("Jules").appendingPathComponent("diffs")

            if fileManager.fileExists(atPath: appSupportURL.path) {
                return appSupportURL
            }
            return nil
        } catch {
            return nil
        }
    }()

    private override init() {
        super.init()
        // Configure cache limits
        memoryCache.countLimit = 50 // Cache up to 50 sessions' diffs
        memoryCache.totalCostLimit = 64 * 1024 * 1024 // 64MB total memory limit

        // Set delegate to track automatic evictions for memory accounting
        memoryCache.delegate = self

        // Migrate legacy file-based diffs to database on first launch
        migrateLegacyDiffsIfNeeded()
    }

    // MARK: - NSCacheDelegate

    /// Called when NSCache automatically evicts an entry (due to memory pressure or exceeding totalCostLimit).
    /// This is critical for keeping estimatedCacheMemoryBytes accurate - without this, the tracker
    /// would keep growing even though NSCache has evicted entries.
    func cache(_ cache: NSCache<AnyObject, AnyObject>, willEvictObject obj: Any) {
        guard let evictedArray = obj as? CachedDiffArray else { return }

        let evictedCost = evictedArray.estimatedMemorySize
        cacheMemoryLock.lock()
        estimatedCacheMemoryBytes -= evictedCost
        // Ensure we don't go negative due to timing issues
        if estimatedCacheMemoryBytes < 0 {
            estimatedCacheMemoryBytes = 0
        }
        let currentBytes = estimatedCacheMemoryBytes
        cacheMemoryLock.unlock()

        if LoadingProfiler.memoryProfilingEnabled {
            let evictedKB = Double(evictedCost) / 1024
            let currentMB = Double(currentBytes) / (1024 * 1024)
            print("🧠 [DiffCache] ♻️ NSCache evicted entry: -\(String(format: "%.1f", evictedKB))KB, cache total: \(String(format: "%.1f", currentMB))MB")
        }
    }

    // MARK: - Public API

    /// Check if diffs are already in memory cache (instant access)
    /// - Parameter sessionId: The session ID to check
    /// - Returns: True if non-empty diffs are in memory cache
    func hasCachedDiffsInMemory(forSession sessionId: String) -> Bool {
        guard let cached = memoryCache.object(forKey: sessionId as NSString) else {
            return false
        }
        // Must check for non-empty: loadDiffsFromDatabase caches empty arrays
        // to avoid repeated lookups, but empty means no diffs available
        return !cached.diffs.isEmpty
    }

    /// Get diffs from memory cache only - never blocks on disk I/O
    /// Use this from the main thread to avoid blocking UI
    /// - Parameter sessionId: The session ID to get diffs for
    /// - Returns: Array of CachedDiff if in cache, nil otherwise
    func getCachedDiffs(forSession sessionId: String) -> [CachedDiff]? {
        guard let cached = memoryCache.object(forKey: sessionId as NSString) else {
            return nil
        }
        return cached.diffs.isEmpty ? nil : cached.diffs
    }

    /// Check if diffs are currently being loaded for a session
    /// - Parameter sessionId: The session ID to check
    /// - Returns: True if loading is in progress
    func isLoadingDiffs(forSession sessionId: String) -> Bool {
        loadingLock.lock()
        defer { loadingLock.unlock() }
        return loadingSessionIds.contains(sessionId)
    }

    /// Preload diffs for a session asynchronously
    /// Call this when navigating to a session to ensure diffs are ready instantly
    /// Posts .diffsDidLoad notification when loading completes
    /// - Parameter sessionId: The session ID to preload diffs for
    /// - Parameter completion: Optional callback when loading completes
    func preloadDiffs(forSession sessionId: String, completion: (() -> Void)? = nil) {
        // Already in cache - nothing to do
        if hasCachedDiffsInMemory(forSession: sessionId) {
            completion?()
            return
        }

        // Check if already loading to avoid duplicate work
        loadingLock.lock()
        if loadingSessionIds.contains(sessionId) {
            loadingLock.unlock()
            // Already loading - just wait for existing load to complete
            return
        }
        loadingSessionIds.insert(sessionId)
        loadingLock.unlock()

        loadQueue.async { [weak self] in
            guard let self = self else { return }

            // Load from database (this populates the cache)
            _ = self.loadDiffsFromDatabase(forSession: sessionId)

            // Remove from loading set
            self.loadingLock.lock()
            self.loadingSessionIds.remove(sessionId)
            self.loadingLock.unlock()

            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .diffsDidLoad,
                    object: nil,
                    userInfo: ["sessionId": sessionId]
                )
                completion?()
            }
        }
    }

    /// Preload diffs for multiple sessions asynchronously
    /// Useful for pre-warming cache for adjacent sessions during pagination
    /// Posts .diffsDidLoad notification for each session when loading completes
    /// - Parameter sessionIds: Array of session IDs to preload
    func preloadDiffs(forSessions sessionIds: [String]) {
        var sessionsToLoad: [String] = []

        loadingLock.lock()
        for sessionId in sessionIds {
            if !hasCachedDiffsInMemory(forSession: sessionId) && !loadingSessionIds.contains(sessionId) {
                loadingSessionIds.insert(sessionId)
                sessionsToLoad.append(sessionId)
            }
        }
        loadingLock.unlock()

        guard !sessionsToLoad.isEmpty else { return }

        loadQueue.async { [weak self] in
            guard let self = self else { return }

            var loadedSessionIds: [String] = []

            for sessionId in sessionsToLoad {
                _ = self.loadDiffsFromDatabase(forSession: sessionId)
                loadedSessionIds.append(sessionId)

                self.loadingLock.lock()
                self.loadingSessionIds.remove(sessionId)
                self.loadingLock.unlock()
            }

            DispatchQueue.main.async {
                for sessionId in loadedSessionIds {
                    NotificationCenter.default.post(
                        name: .diffsDidLoad,
                        object: nil,
                        userInfo: ["sessionId": sessionId]
                    )
                }
            }
        }
    }

    /// Save diffs for a session (replaces any existing diffs)
    /// Also updates the in-memory cache for instant access
    /// Skips save if diffs are identical to what's already cached (avoids unnecessary UI updates)
    /// - Parameters:
    ///   - diffs: Array of CachedDiff to save
    ///   - sessionId: The session ID to associate with these diffs
    /// - Returns: True if diffs were actually saved (changed), false if skipped (unchanged)
    @discardableResult
    func saveDiffs(_ diffs: [CachedDiff], forSession sessionId: String) throws -> Bool {
        // Check if diffs have actually changed by comparing with cached version
        // This prevents unnecessary database writes and UI updates during polling
        if let existingCached = memoryCache.object(forKey: sessionId as NSString) {
            if existingCached.diffs == diffs {
                // Diffs are identical - skip save to avoid triggering unnecessary UI updates
                return false
            }
        }

        // Diffs have changed - update cache and database
        let cachedArray = CachedDiffArray(diffs)
        let cost = cachedArray.estimatedMemorySize
        // setObject evicts old entry (triggering delegate to subtract old cost), then stores new
        memoryCache.setObject(cachedArray, forKey: sessionId as NSString, cost: cost)

        // Update cache memory tracking - only add new cost (delegate handles subtracting old cost)
        cacheMemoryLock.lock()
        estimatedCacheMemoryBytes += cost
        let currentCacheBytes = estimatedCacheMemoryBytes
        cacheMemoryLock.unlock()

        // Log cache memory for debugging memory spikes
        if LoadingProfiler.memoryProfilingEnabled {
            let cacheMB = Double(currentCacheBytes) / (1024 * 1024)
            let costKB = Double(cost) / 1024
            let diffCount = diffs.count
            print("🧠 [DiffCache] saveDiffs(\(sessionId.prefix(8))): +\(String(format: "%.1f", costKB))KB for \(diffCount) diffs, cache total: \(String(format: "%.1f", cacheMB))MB")
        }

        // Save to database
        try DiffDatabase.saveDiffs(diffs, forSession: sessionId)
        return true
    }

    /// Load diffs for a session
    /// Checks in-memory cache first for instant access, falls back to database
    /// - Parameter sessionId: The session ID to load diffs for
    /// - Returns: Array of CachedDiff, or nil if no diffs exist
    func loadDiffs(forSession sessionId: String) -> [CachedDiff]? {
        // Check in-memory cache first (instant)
        if let cached = memoryCache.object(forKey: sessionId as NSString) {
            return cached.diffs.isEmpty ? nil : cached.diffs
        }

        // Fall back to database and populate cache
        return loadDiffsFromDatabase(forSession: sessionId)
    }

    /// Load diffs from database and populate cache
    private func loadDiffsFromDatabase(forSession sessionId: String) -> [CachedDiff]? {
        let diffs = DiffDatabase.loadDiffs(forSession: sessionId)

        // Cache result (including empty results to avoid repeated lookups)
        let cachedArray = CachedDiffArray(diffs ?? [])
        let cost = cachedArray.estimatedMemorySize
        // setObject evicts old entry if exists (triggering delegate to subtract old cost), then stores new
        memoryCache.setObject(cachedArray, forKey: sessionId as NSString, cost: cost)

        // Update cache memory tracking - only add new cost (delegate handles subtracting old cost)
        if cost > 0 {
            cacheMemoryLock.lock()
            estimatedCacheMemoryBytes += cost
            let currentCacheBytes = estimatedCacheMemoryBytes
            cacheMemoryLock.unlock()

            if LoadingProfiler.memoryProfilingEnabled {
                let cacheMB = Double(currentCacheBytes) / (1024 * 1024)
                let costKB = Double(cost) / 1024
                let diffCount = diffs?.count ?? 0
                print("🧠 [DiffCache] loadDiffs(\(sessionId.prefix(8))): +\(String(format: "%.1f", costKB))KB for \(diffCount) diffs, cache total: \(String(format: "%.1f", cacheMB))MB")
            }
        }

        return diffs
    }

    /// Delete all diffs for a session
    /// - Parameter sessionId: The session ID to delete diffs for
    func deleteDiffs(forSession sessionId: String) {
        // Memory tracking is handled by NSCacheDelegate.willEvictObject
        memoryCache.removeObject(forKey: sessionId as NSString)
        DiffDatabase.deleteDiffs(forSession: sessionId)
    }

    /// Delete diffs for multiple sessions
    /// - Parameter sessionIds: Array of session IDs to delete diffs for
    func deleteDiffs(forSessions sessionIds: [String]) {
        // Memory tracking is handled by NSCacheDelegate.willEvictObject
        for sessionId in sessionIds {
            memoryCache.removeObject(forKey: sessionId as NSString)
        }
        DiffDatabase.deleteDiffs(forSessions: sessionIds)
    }

    /// Check if diffs exist for a session
    /// - Parameter sessionId: The session ID to check
    /// - Returns: True if diffs exist
    func hasDiffs(forSession sessionId: String) -> Bool {
        // Check cache first
        if let cached = memoryCache.object(forKey: sessionId as NSString) {
            return !cached.diffs.isEmpty
        }
        // Fall back to database
        return DiffDatabase.hasDiffs(forSession: sessionId)
    }

    /// Get total count of stored diffs (for diagnostics)
    func totalDiffCount() -> Int {
        return DiffDatabase.totalDiffCount()
    }

    /// Clean up orphaned diff directories (sessions that no longer exist)
    /// - Parameter validSessionIds: Set of session IDs that should be kept
    func cleanupOrphanedDiffs(keepingSessions validSessionIds: Set<String>) {
        DiffDatabase.cleanupOrphanedDiffs(keepingSessions: validSessionIds)
    }

    /// Clear all entries from the in-memory cache.
    /// Use this when transitioning to menubar-only mode to reduce memory footprint.
    /// Diffs will be reloaded from database when needed.
    func clearMemoryCache() {
        cacheMemoryLock.lock()
        let previousMB = Double(estimatedCacheMemoryBytes) / (1024 * 1024)
        estimatedCacheMemoryBytes = 0
        cacheMemoryLock.unlock()

        memoryCache.removeAllObjects()
        loadingLock.lock()
        loadingSessionIds.removeAll()
        loadingLock.unlock()

        // Always log cache clears with stack trace to debug unexpected clears
        print("🧠 [DiffCache] ⚠️ Memory cache CLEARED (was \(String(format: "%.1f", previousMB))MB)")
        Thread.callStackSymbols.prefix(10).forEach { print("  \($0)") }
    }

    /// Returns estimated current cache memory usage in bytes for diagnostics
    func estimatedCacheMemory() -> Int {
        cacheMemoryLock.lock()
        defer { cacheMemoryLock.unlock() }
        return estimatedCacheMemoryBytes
    }

    /// Logs current cache memory usage for debugging
    func logCacheMemory(_ context: String = "") {
        guard LoadingProfiler.memoryProfilingEnabled else { return }

        cacheMemoryLock.lock()
        let bytes = estimatedCacheMemoryBytes
        cacheMemoryLock.unlock()

        let mb = Double(bytes) / (1024 * 1024)
        let limitMB = Double(memoryCache.totalCostLimit) / (1024 * 1024)
        let utilization = limitMB > 0 ? (mb / limitMB) * 100 : 0

        let emoji = utilization > 80 ? "🔴" : utilization > 50 ? "🟠" : "🟢"
        let contextStr = context.isEmpty ? "" : " (\(context))"
        print("🧠 [DiffCache]\(contextStr) \(emoji) \(String(format: "%.1f", mb))MB / \(String(format: "%.0f", limitMB))MB (\(String(format: "%.0f", utilization))% utilized)")
    }

    // MARK: - Legacy Migration

    /// Migrate diffs from legacy file-based storage to database
    private func migrateLegacyDiffsIfNeeded() {
        guard let legacyDir = legacyDiffsDirectory else { return }

        loadQueue.async { [weak self] in
            guard let self = self else { return }

            do {
                let sessionDirs = try self.fileManager.contentsOfDirectory(
                    at: legacyDir,
                    includingPropertiesForKeys: nil
                )

                var migratedCount = 0

                for sessionDir in sessionDirs {
                    let sessionId = sessionDir.lastPathComponent

                    // Skip if already in database
                    if DiffDatabase.hasDiffs(forSession: sessionId) {
                        continue
                    }

                    // Load from legacy files
                    if let diffs = self.loadLegacyDiffs(from: sessionDir) {
                        try? DiffDatabase.saveDiffs(diffs, forSession: sessionId)
                        migratedCount += 1
                    }
                }

                if migratedCount > 0 {
                    print("[DiffStorageManager] Migrated \(migratedCount) sessions from file storage to database")
                }

                // Clean up legacy directory after successful migration
                try? self.fileManager.removeItem(at: legacyDir)

            } catch {
                print("[DiffStorageManager] Error during legacy migration: \(error)")
            }
        }
    }

    /// Load diffs from legacy compressed files
    private func loadLegacyDiffs(from sessionDir: URL) -> [CachedDiff]? {
        do {
            let files = try fileManager.contentsOfDirectory(at: sessionDir, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "gz" }
                .sorted { url1, url2 in
                    let index1 = Int(url1.deletingPathExtension().deletingPathExtension().lastPathComponent) ?? 0
                    let index2 = Int(url2.deletingPathExtension().deletingPathExtension().lastPathComponent) ?? 0
                    return index1 < index2
                }

            guard !files.isEmpty else { return nil }

            var diffs: [CachedDiff] = []
            for fileURL in files {
                if let diff = try? readLegacyDiff(from: fileURL) {
                    diffs.append(diff)
                }
            }

            return diffs.isEmpty ? nil : diffs
        } catch {
            return nil
        }
    }

    /// Read a single diff from legacy compressed file
    private func readLegacyDiff(from url: URL) throws -> CachedDiff {
        let compressedData = try Data(contentsOf: url)
        let jsonData = try decompressLegacy(compressedData)
        let decoder = JSONDecoder()
        return try decoder.decode(CachedDiff.self, from: jsonData)
    }

    /// Decompress data from legacy zlib format
    private func decompressLegacy(_ data: Data) throws -> Data {
        let estimatedSize = data.count * 15
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: estimatedSize)
        defer { destinationBuffer.deallocate() }

        let decompressedSize = data.withUnsafeBytes { sourceBuffer -> Int in
            guard let sourcePtr = sourceBuffer.baseAddress else { return 0 }
            return compression_decode_buffer(
                destinationBuffer,
                estimatedSize,
                sourcePtr.assumingMemoryBound(to: UInt8.self),
                data.count,
                nil,
                COMPRESSION_ZLIB
            )
        }

        guard decompressedSize > 0 else {
            throw LegacyError.decompressionFailed
        }

        return Data(bytes: destinationBuffer, count: decompressedSize)
    }

    private enum LegacyError: Error {
        case decompressionFailed
    }
}

// MARK: - Cache Helper

/// Wrapper class for storing [CachedDiff] in NSCache (which requires reference types)
private final class CachedDiffArray {
    let diffs: [CachedDiff]

    /// Estimated memory size in bytes for NSCache cost calculation
    let estimatedMemorySize: Int

    init(_ diffs: [CachedDiff]) {
        self.diffs = diffs
        // Estimate memory: each diff has patch string + optional language/filename
        // Swift strings use UTF-16 internally (2 bytes per code unit) plus object overhead
        // NSString bridging adds additional ~32 bytes per string
        // Using 2.5x multiplier to account for UTF-16 + Swift String overhead + bridging
        self.estimatedMemorySize = diffs.reduce(0) { total, diff in
            let patchBytes = diff.patch.utf8.count
            let languageBytes = diff.language?.utf8.count ?? 0
            let filenameBytes = diff.filename?.utf8.count ?? 0
            let rawBytes = patchBytes + languageBytes + filenameBytes
            // Multiply by 2.5 for UTF-16 encoding + Swift overhead, add 80 bytes per diff for object overhead
            return total + Int(Double(rawBytes) * 2.5) + 80
        }
    }
}
