import Foundation
import GRDB

// MARK: - Database Records

/// Database record for cached file paths
struct CachedFilePath: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "filePath"

    var id: Int64?
    let repositoryId: String
    let filePath: String
    let filename: String
    var fromFileSystem: Bool
    var fromDiffPatch: Bool
    var lastSeen: Date

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let repositoryId = Column(CodingKeys.repositoryId)
        static let filePath = Column(CodingKeys.filePath)
        static let filename = Column(CodingKeys.filename)
        static let fromFileSystem = Column(CodingKeys.fromFileSystem)
        static let fromDiffPatch = Column(CodingKeys.fromDiffPatch)
        static let lastSeen = Column(CodingKeys.lastSeen)
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Database record for repository scan state
struct RepositoryScanState: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "repositoryScanState"

    let repositoryId: String
    var hasPerformedInitialScan: Bool
    var lastScanTime: Date?
    var fileCount: Int

    enum Columns {
        static let repositoryId = Column(CodingKeys.repositoryId)
        static let hasPerformedInitialScan = Column(CodingKeys.hasPerformedInitialScan)
        static let lastScanTime = Column(CodingKeys.lastScanTime)
        static let fileCount = Column(CodingKeys.fileCount)
    }
}

// MARK: - FilenameCache

/// Cache for file paths used in autocomplete.
/// Stores full file paths from multiple sources (FSEvents, diff patches) with deduplication.
/// Uses SQLite for efficient storage and querying of large file sets.
@MainActor
final class FilenameCache: ObservableObject {

    // MARK: - Configuration

    /// Enable debug logging for cache operations
    static var debugLoggingEnabled = false

    // MARK: - Types

    /// Source of a cached file path
    enum FilenameSource: String, Hashable, Sendable, Codable {
        case localFileSystem
        case diffPatch
    }

    /// A cached file path entry with metadata (for in-memory operations)
    struct FilenameEntry: Hashable, Sendable {
        let filePath: String
        let filename: String
        let sources: Set<FilenameSource>
        let lastSeen: Date

        var filenameWithoutExtension: String {
            let url = URL(fileURLWithPath: filename)
            return url.deletingPathExtension().lastPathComponent
        }

        init(filePath: String, sources: Set<FilenameSource>, lastSeen: Date) {
            self.filePath = filePath
            self.filename = URL(fileURLWithPath: filePath).lastPathComponent
            self.sources = sources
            self.lastSeen = lastSeen
        }

        init(from record: CachedFilePath) {
            self.filePath = record.filePath
            self.filename = record.filename
            var sources = Set<FilenameSource>()
            if record.fromFileSystem { sources.insert(.localFileSystem) }
            if record.fromDiffPatch { sources.insert(.diffPatch) }
            self.sources = sources
            self.lastSeen = record.lastSeen
        }
    }

    // MARK: - Properties

    let repositoryId: String
    private(set) var localRepoPath: String?
    private let dbQueue: DatabasePool

    /// In-memory cache for fast prefix matching (populated lazily from DB)
    /// Only used for operations that truly need all entries (allFilePaths, contains, etc.)
    private var inMemoryCache: [String: FilenameEntry]?

    /// Cached count to avoid repeated database queries
    private var cachedCount: Int?

    /// Publisher for when the cache changes
    @Published private(set) var lastUpdateTime: Date = Date()

    /// Whether the cache has been populated from initial scan
    @Published private(set) var hasPerformedInitialScan: Bool = false

    // MARK: - Initialization

    init(repositoryId: String, localRepoPath: String? = nil, dbQueue: DatabasePool = AppDatabase.shared) {
        self.repositoryId = repositoryId
        self.localRepoPath = localRepoPath
        self.dbQueue = dbQueue
        loadScanState()
    }

    func setLocalRepoPath(_ path: String?) {
        self.localRepoPath = path
    }

    // MARK: - Database Operations

    private func loadScanState() {
        do {
            let state = try dbQueue.read { db in
                try RepositoryScanState.fetchOne(db, key: repositoryId)
            }
            hasPerformedInitialScan = state?.hasPerformedInitialScan ?? false
        } catch {
            if FilenameCache.debugLoggingEnabled {
                print("[FilenameCache] Error loading scan state: \(error)")
            }
        }
    }

    private func saveScanState() {
        do {
            try dbQueue.write { db in
                let fileCount = try CachedFilePath
                    .filter(CachedFilePath.Columns.repositoryId == repositoryId)
                    .fetchCount(db)

                let state = RepositoryScanState(
                    repositoryId: repositoryId,
                    hasPerformedInitialScan: hasPerformedInitialScan,
                    lastScanTime: Date(),
                    fileCount: fileCount
                )
                try state.save(db)
            }
        } catch {
            if FilenameCache.debugLoggingEnabled {
                print("[FilenameCache] Error saving scan state: \(error)")
            }
        }
    }

    /// Invalidate in-memory cache when DB changes
    private func invalidateInMemoryCache() {
        inMemoryCache = nil
        cachedCount = nil
        lastUpdateTime = Date()
    }

    /// Load entries from database into memory for fast matching
    private func ensureInMemoryCache() -> [String: FilenameEntry] {
        if let cache = inMemoryCache {
            return cache
        }

        var cache = [String: FilenameEntry]()
        do {
            let records = try dbQueue.read { db in
                try CachedFilePath
                    .filter(CachedFilePath.Columns.repositoryId == repositoryId)
                    .fetchAll(db)
            }
            for record in records {
                cache[record.filePath] = FilenameEntry(from: record)
            }
        } catch {
            if FilenameCache.debugLoggingEnabled {
                print("[FilenameCache] Error loading file paths from database: \(error)")
            }
        }

        inMemoryCache = cache
        return cache
    }

    // MARK: - Public Methods

    /// Add file paths from the local file system
    /// Uses UPSERT pattern with batched operations for better performance
    func addFromFileSystem(_ filePaths: Set<String>) {
        guard !filePaths.isEmpty else { return }

        let now = Date()
        let batchSize = 500 // Process in batches for very large sets

        do {
            try dbQueue.write { db in
                // Prepare statement once, execute multiple times
                let sql = """
                    INSERT INTO filePath (repositoryId, filePath, filename, fromFileSystem, fromDiffPatch, lastSeen)
                    VALUES (?, ?, ?, 1, 0, ?)
                    ON CONFLICT(repositoryId, filePath) DO UPDATE SET
                        fromFileSystem = 1,
                        lastSeen = excluded.lastSeen
                """
                let statement = try db.cachedStatement(sql: sql)

                // Process in batches to avoid memory issues with very large file sets
                let pathsArray = Array(filePaths)
                for batch in stride(from: 0, to: pathsArray.count, by: batchSize) {
                    let end = min(batch + batchSize, pathsArray.count)
                    for i in batch..<end {
                        let filePath = pathsArray[i]
                        let filename = URL(fileURLWithPath: filePath).lastPathComponent
                        try statement.execute(arguments: [repositoryId, filePath, filename, now])
                    }
                }
            }
            invalidateInMemoryCache()
            if FilenameCache.debugLoggingEnabled {
                print("[FilenameCache] Added \(filePaths.count) files from filesystem for repo: \(repositoryId)")
            }
        } catch {
            if FilenameCache.debugLoggingEnabled {
                print("[FilenameCache] Error adding file paths to database: \(error)")
            }
        }
    }

    /// Remove file paths from the local file system
    /// Uses batched operations for better performance
    func removeFromFileSystem(_ filePaths: Set<String>) {
        guard !filePaths.isEmpty else { return }

        do {
            try dbQueue.write { db in
                // Batch fetch all existing records for the given paths
                let pathsArray = Array(filePaths)
                let existingRecords = try CachedFilePath
                    .filter(CachedFilePath.Columns.repositoryId == repositoryId)
                    .filter(pathsArray.contains(CachedFilePath.Columns.filePath))
                    .fetchAll(db)

                // Build lookup for quick access
                var recordsByPath = Dictionary(
                    existingRecords.map { ($0.filePath, $0) },
                    uniquingKeysWith: { first, _ in first }
                )

                // Prepare statements for updates and deletes
                let updateSql = """
                    UPDATE filePath SET fromFileSystem = 0
                    WHERE repositoryId = ? AND filePath = ?
                """
                let updateStatement = try db.cachedStatement(sql: updateSql)

                let deleteSql = """
                    DELETE FROM filePath
                    WHERE repositoryId = ? AND filePath = ? AND fromDiffPatch = 0
                """
                let deleteStatement = try db.cachedStatement(sql: deleteSql)

                for filePath in filePaths {
                    if let existing = recordsByPath[filePath] {
                        // If the record has diffPatch source, just update; otherwise delete
                        if existing.fromDiffPatch {
                            try updateStatement.execute(arguments: [repositoryId, filePath])
                        } else {
                            try deleteStatement.execute(arguments: [repositoryId, filePath])
                        }
                    }
                }
            }
            invalidateInMemoryCache()
        } catch {
            if FilenameCache.debugLoggingEnabled {
                print("[FilenameCache] Error removing file paths from database: \(error)")
            }
        }
    }

    /// Add file paths from a diff patch
    /// Uses UPSERT pattern with prepared statement for better performance
    func addFromDiffPatch(_ filePaths: Set<String>) {
        guard !filePaths.isEmpty else { return }

        let now = Date()
        do {
            try dbQueue.write { db in
                // Prepare statement once, execute multiple times
                let sql = """
                    INSERT INTO filePath (repositoryId, filePath, filename, fromFileSystem, fromDiffPatch, lastSeen)
                    VALUES (?, ?, ?, 0, 1, ?)
                    ON CONFLICT(repositoryId, filePath) DO UPDATE SET
                        fromDiffPatch = 1,
                        lastSeen = excluded.lastSeen
                """
                let statement = try db.cachedStatement(sql: sql)

                for filePath in filePaths {
                    let filename = URL(fileURLWithPath: filePath).lastPathComponent
                    try statement.execute(arguments: [repositoryId, filePath, filename, now])
                }
            }
            invalidateInMemoryCache()
            if FilenameCache.debugLoggingEnabled {
                print("[FilenameCache] Added \(filePaths.count) files from diff patch for repo: \(repositoryId)")
            }
        } catch {
            if FilenameCache.debugLoggingEnabled {
                print("[FilenameCache] Error adding diff patch file paths to database: \(error)")
            }
        }
    }

    /// Add a single file path from any source
    func addFilePath(_ filePath: String, source: FilenameSource) {
        switch source {
        case .localFileSystem:
            addFromFileSystem([filePath])
        case .diffPatch:
            addFromDiffPatch([filePath])
        }
    }

    /// Mark that initial scan has been performed
    func markInitialScanComplete() {
        hasPerformedInitialScan = true
        saveScanState()
    }

    /// Find file paths matching a prefix (case-insensitive, matches on filename portion)
    /// Uses SQL LIKE query with indexed lookup for efficient prefix matching
    func findMatches(prefix: String, limit: Int = 10) -> [String] {
        guard !prefix.isEmpty else { return [] }

        if FilenameCache.debugLoggingEnabled {
            print("[FilenameCache] findMatches: prefix='\(prefix)', repo=\(repositoryId)")
        }

        do {
            // Use SQL LIKE query with the indexed filename column
            // The index on (repositoryId, filename) makes this efficient
            // We match on the filename portion, case-insensitive
            let escapedPrefix = prefix
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            let likePattern = "\(escapedPrefix)%"

            let matches = try dbQueue.read { db -> [String] in
                // Query using LIKE with ESCAPE clause for proper pattern matching
                // Order by filename for consistent results
                let sql = """
                    SELECT filePath FROM filePath
                    WHERE repositoryId = ?
                    AND filename LIKE ? ESCAPE '\\'
                    ORDER BY filename COLLATE NOCASE ASC
                    LIMIT ?
                """
                return try String.fetchAll(db, sql: sql, arguments: [repositoryId, likePattern, limit])
            }

            if FilenameCache.debugLoggingEnabled {
                print("[FilenameCache] findMatches: found \(matches.count) matches using SQL")
            }
            return matches
        } catch {
            if FilenameCache.debugLoggingEnabled {
                print("[FilenameCache] findMatches SQL error: \(error), falling back to in-memory")
            }
            // Fallback to in-memory matching if SQL fails
            return findMatchesInMemory(prefix: prefix, limit: limit)
        }
    }

    /// Fallback in-memory matching (only used if SQL query fails)
    private func findMatchesInMemory(prefix: String, limit: Int) -> [String] {
        let lowercasedPrefix = prefix.lowercased()
        let cache = ensureInMemoryCache()

        var matches: [String] = []
        for entry in cache.values {
            if entry.filename.lowercased().hasPrefix(lowercasedPrefix) {
                matches.append(entry.filePath)
                if matches.count >= limit {
                    break
                }
            }
        }
        return matches
    }

    /// Async version of findMatches for background processing
    func findMatchesAsync(prefix: String, limit: Int = 10) async -> [String] {
        return findMatches(prefix: prefix, limit: limit)
    }

    /// Get all cached file paths
    var allFilePaths: [String] {
        return Array(ensureInMemoryCache().keys)
    }

    /// Get all cached entries
    var allEntries: [FilenameEntry] {
        return Array(ensureInMemoryCache().values)
    }

    /// Number of cached file paths (cached to avoid repeated DB queries)
    var count: Int {
        if let cached = cachedCount {
            return cached
        }

        do {
            let count = try dbQueue.read { db in
                try CachedFilePath
                    .filter(CachedFilePath.Columns.repositoryId == repositoryId)
                    .fetchCount(db)
            }
            cachedCount = count
            return count
        } catch {
            return inMemoryCache?.count ?? 0
        }
    }

    /// Check if a file path exists in the cache
    func contains(_ filePath: String) -> Bool {
        return ensureInMemoryCache()[filePath] != nil
    }

    /// Check if a filename exists in the cache
    func containsFilename(_ filename: String) -> Bool {
        return ensureInMemoryCache().values.contains { $0.filename == filename }
    }

    /// Clear all cached file paths for this repository
    func clear() {
        do {
            try dbQueue.write { db in
                try CachedFilePath
                    .filter(CachedFilePath.Columns.repositoryId == repositoryId)
                    .deleteAll(db)
            }
            hasPerformedInitialScan = false
            saveScanState()
            invalidateInMemoryCache()
        } catch {
            if FilenameCache.debugLoggingEnabled {
                print("[FilenameCache] Error clearing file path cache: \(error)")
            }
        }
    }

    /// Clear only file paths from a specific source
    func clear(source: FilenameSource) {
        do {
            try dbQueue.write { db in
                let records = try CachedFilePath
                    .filter(CachedFilePath.Columns.repositoryId == repositoryId)
                    .fetchAll(db)

                for var record in records {
                    switch source {
                    case .localFileSystem:
                        record.fromFileSystem = false
                    case .diffPatch:
                        record.fromDiffPatch = false
                    }

                    if !record.fromFileSystem && !record.fromDiffPatch {
                        try record.delete(db)
                    } else {
                        try record.update(db)
                    }
                }
            }
            invalidateInMemoryCache()
        } catch {
            if FilenameCache.debugLoggingEnabled {
                print("[FilenameCache] Error clearing source from cache: \(error)")
            }
        }
    }

    /// Clear persisted cache (for compatibility - now clears from database)
    func clearPersistedCache() {
        clear()
    }
}

// MARK: - FilenameCache Extensions for Diff Parsing

extension FilenameCache {
    /// Extract and cache file paths from a unified diff patch string
    func extractAndCacheFromPatch(_ patch: String) {
        let filePaths = Self.extractFilePathsFromPatch(patch)
        addFromDiffPatch(filePaths)
    }

    /// Extract full file paths from a unified diff patch
    static func extractFilePathsFromPatch(_ patch: String) -> Set<String> {
        var filePaths: Set<String> = []
        let lines = patch.components(separatedBy: "\n")

        for line in lines {
            if line.hasPrefix("diff --git ") {
                let parts = line.components(separatedBy: " ")
                if parts.count >= 4 {
                    var path = parts[3]
                    if path.hasPrefix("b/") {
                        path = String(path.dropFirst(2))
                    }
                    if !path.isEmpty && path != "/dev/null" {
                        filePaths.insert(path)
                    }
                }
            } else if line.hasPrefix("+++ ") {
                var path = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                if path.hasPrefix("b/") {
                    path = String(path.dropFirst(2))
                }
                if !path.isEmpty && path != "/dev/null" {
                    filePaths.insert(path)
                }
            } else if line.hasPrefix("--- ") {
                var path = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                if path.hasPrefix("a/") {
                    path = String(path.dropFirst(2))
                }
                if !path.isEmpty && path != "/dev/null" {
                    filePaths.insert(path)
                }
            }
        }

        return filePaths
    }

    /// Legacy method for backwards compatibility
    static func extractFilenamesFromPatch(_ patch: String) -> Set<String> {
        return extractFilePathsFromPatch(patch)
    }
}
