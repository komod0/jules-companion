import GRDB
import Foundation

// --- AppDatabase.swift ---
struct AppDatabase {
    static let shared = makeShared()

    /// Pre-warms the database by accessing it on a background thread.
    /// Call this early in app launch to avoid blocking the main thread on first access.
    static func preWarm() {
        Task.detached(priority: .userInitiated) {
            // Access the shared instance to trigger lazy initialization off main thread
            _ = shared
        }
    }

    /// Configure SQLite to suppress harmless macOS system warnings.
    /// This filters out warnings that occur from macOS system databases, not our app's database.
    private static let configureSQLiteLogging: Void = {
        Database.logError = { (resultCode, message) in
            // Filter out the harmless DetachedSignatures warning on macOS
            // (occurs when SQLite tries to verify code signatures)
            if message.contains("DetachedSignatures") {
                return
            }
            // Filter out cfurl_cache_response constraint errors from macOS URL cache
            // (harmless race condition when URLSession's internal cache has duplicate entries)
            if message.contains("cfurl_cache_response") {
                return
            }
            // Filter out WAL recovery notifications (SQLITE_NOTICE_RECOVER_WAL = 283)
            // These are benign notifications that occur when SQLite recovers uncommitted
            // transactions from the WAL file after an unclean shutdown - not actual errors
            if message.contains("recovered") && message.contains("frames from WAL file") {
                return
            }
            // Log other errors normally
            print("SQLite error \(resultCode): \(message)")
        }
    }()

    // Using DatabasePool enables WAL mode and concurrent reads by default.
    private static func makeShared() -> DatabasePool {
        // Ensure SQLite logging is configured before any database operations
        _ = configureSQLiteLogging

        do {
            let fileManager = FileManager.default
            let appSupportURL = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("Jules")

            try fileManager.createDirectory(at: appSupportURL, withIntermediateDirectories: true)

            let dbURL = appSupportURL.appendingPathComponent("db.sqlite")

            var config = Configuration()
            config.prepareDatabase { db in
                           // db.trace { print($0) } // Optional: for debugging
                       }

            let dbPool = try DatabasePool(path: dbURL.path, configuration: config)
            try migrator.migrate(dbPool)
            return dbPool
        } catch {
            fatalError("Unresolved error: \(error)")
        }
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("createSession") { db in
            try db.create(table: "session") { t in
                t.column("id", .text).primaryKey()
                t.column("updateTime", .text).notNull()
                // Store the full Session object as JSON
                t.column("json", .text).notNull()
            }
        }

        migrator.registerMigration("addCreateTime") { db in
            try db.alter(table: "session") { t in
                t.add(column: "createTime", .text)
            }
        }

        migrator.registerMigration("addLastActivityPollTime") { db in
            try db.alter(table: "session") { t in
                t.add(column: "lastActivityPollTime", .datetime)
            }
        }

        migrator.registerMigration("addViewedAt") { db in
            try db.alter(table: "session") { t in
                t.add(column: "viewedAt", .datetime)
            }
        }

        // Migration: Create sources table for offline storage
        migrator.registerMigration("createSources") { db in
            try db.create(table: "source") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("json", .blob).notNull()
            }
        }

        // Migration: Create pending_sessions table for offline session creation
        migrator.registerMigration("createPendingSessions") { db in
            try db.create(table: "pendingSession") { t in
                t.column("id", .text).primaryKey()
                t.column("createdAt", .datetime).notNull()
                t.column("json", .blob).notNull()
            }
        }

        // Migration: Create file_path table for caching repository file paths
        migrator.registerMigration("createFilePaths") { db in
            try db.create(table: "filePath") { t in
                t.column("id", .integer).primaryKey(autoincrement: true)
                t.column("repositoryId", .text).notNull().indexed()
                t.column("filePath", .text).notNull()
                t.column("filename", .text).notNull().indexed()
                t.column("fromFileSystem", .boolean).notNull().defaults(to: false)
                t.column("fromDiffPatch", .boolean).notNull().defaults(to: false)
                t.column("lastSeen", .datetime).notNull()
                // Unique constraint on repository + file path
                t.uniqueKey(["repositoryId", "filePath"])
            }

            // Create index for common query patterns
            try db.create(index: "idx_filePath_repo_filename", on: "filePath", columns: ["repositoryId", "filename"])
        }

        // Migration: Create repository_scan_state table to track scan status
        migrator.registerMigration("createRepositoryScanState") { db in
            try db.create(table: "repositoryScanState") { t in
                t.column("repositoryId", .text).primaryKey()
                t.column("hasPerformedInitialScan", .boolean).notNull().defaults(to: false)
                t.column("lastScanTime", .datetime)
                t.column("fileCount", .integer).notNull().defaults(to: 0)
            }
        }

        // Migration: Add performance indexes for session queries
        migrator.registerMigration("addSessionPerformanceIndexes") { db in
            // Add state column for indexed querying (extracted from JSON for performance)
            try db.alter(table: "session") { t in
                t.add(column: "state", .text)
            }

            // Create indexes for common query patterns
            try db.create(index: "idx_session_state", on: "session", columns: ["state"])
            try db.create(index: "idx_session_lastActivityPollTime", on: "session", columns: ["lastActivityPollTime"])
            try db.create(index: "idx_session_state_createTime", on: "session", columns: ["state", "createTime"])
        }

        // Migration: Create separate table for cached diffs (large patches stored outside session JSON)
        // Note: This table is no longer used - diffs are now stored as compressed files
        // Keeping migration for backwards compatibility with existing databases
        migrator.registerMigration("createCachedDiffs") { db in
            try db.create(table: "cachedDiff") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("sessionId", .text).notNull().indexed()
                t.column("patch", .text).notNull()
                t.column("language", .text)
                t.column("filename", .text)
                t.column("orderIndex", .integer).notNull().defaults(to: 0)
            }

            // Create index for efficient session lookups
            try db.create(index: "idx_cachedDiff_sessionId", on: "cachedDiff", columns: ["sessionId"])
        }

        // Migration: Add hasCachedDiffs flag to session table for fast lookup
        // This avoids file system checks when determining if a session has diffs
        migrator.registerMigration("addHasCachedDiffs") { db in
            try db.alter(table: "session") { t in
                t.add(column: "hasCachedDiffs", .boolean).notNull().defaults(to: false)
            }
        }

        // Migration: Rename viewedAt to viewedPostCompletionAt to clarify that we only
        // track visits that occur after a session has completed
        migrator.registerMigration("renameViewedAtToViewedPostCompletionAt") { db in
            try db.alter(table: "session") { t in
                t.rename(column: "viewedAt", to: "viewedPostCompletionAt")
            }
        }

        return migrator
    }
}

// MARK: - Diagnostics

extension AppDatabase {
    /// Get the database file size in bytes (for diagnostics)
    static func databaseFileSize() -> Int64 {
        do {
            let fileManager = FileManager.default
            let appSupportURL = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            ).appendingPathComponent("Jules").appendingPathComponent("db.sqlite")

            let attributes = try fileManager.attributesOfItem(atPath: appSupportURL.path)
            return attributes[.size] as? Int64 ?? 0
        } catch {
            return 0
        }
    }

    /// Get total count of sessions (for diagnostics)
    static func totalSessionCount() -> Int {
        do {
            return try shared.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session") ?? 0
            }
        } catch {
            return 0
        }
    }

    /// Get count of sessions by state (for diagnostics)
    static func sessionCountByState() -> [String: Int] {
        do {
            return try shared.read { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT COALESCE(state, 'unknown') as state, COUNT(*) as count
                    FROM session
                    GROUP BY state
                    """)
                var result: [String: Int] = [:]
                for row in rows {
                    let state: String = row["state"]
                    let count: Int = row["count"]
                    result[state] = count
                }
                return result
            }
        } catch {
            return [:]
        }
    }

    /// Get total size of all session JSON data in bytes (for diagnostics)
    static func totalJsonDataSize() -> Int64 {
        do {
            return try shared.read { db in
                try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(LENGTH(json)), 0) FROM session") ?? 0
            }
        } catch {
            return 0
        }
    }

    /// Get average session JSON size in bytes (for diagnostics)
    static func averageSessionSize() -> Int64 {
        do {
            return try shared.read { db in
                try Int64.fetchOne(db, sql: "SELECT COALESCE(AVG(LENGTH(json)), 0) FROM session") ?? 0
            }
        } catch {
            return 0
        }
    }

    /// Get count of sessions with cached diffs (for diagnostics)
    static func sessionsWithDiffsCount() -> Int {
        do {
            return try shared.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session WHERE hasCachedDiffs = 1") ?? 0
            }
        } catch {
            return 0
        }
    }

    /// Log comprehensive database diagnostics
    static func logDiagnostics() {
        let fileSize = databaseFileSize()
        let sessionCount = totalSessionCount()
        let jsonDataSize = totalJsonDataSize()
        let avgSessionSize = averageSessionSize()
        let sessionsWithDiffs = sessionsWithDiffsCount()
        let stateBreakdown = sessionCountByState()

        let fileSizeMB = Double(fileSize) / 1_048_576.0
        let jsonDataMB = Double(jsonDataSize) / 1_048_576.0
        let avgSessionKB = Double(avgSessionSize) / 1_024.0

        print("═══════════════════════════════════════════════════════")
        print("📊 [SessionDatabase] Diagnostics:")
        print("   Database file size: \(String(format: "%.2f", fileSizeMB)) MB")
        print("   Total JSON data:    \(String(format: "%.2f", jsonDataMB)) MB")
        print("   Total sessions:     \(sessionCount)")
        print("   Avg session size:   \(String(format: "%.1f", avgSessionKB)) KB")
        print("   Sessions with diffs: \(sessionsWithDiffs)")
        if !stateBreakdown.isEmpty {
            print("   Sessions by state:")
            for (state, count) in stateBreakdown.sorted(by: { $0.value > $1.value }) {
                print("     - \(state): \(count)")
            }
        }
        print("═══════════════════════════════════════════════════════")
    }
}

// MARK: - Database Maintenance

extension AppDatabase {
    /// Calculate the bloat ratio (file size vs actual data size)
    /// A ratio > 2.0 means more than half the file is wasted space
    static func bloatRatio() -> Double {
        let fileSize = databaseFileSize()
        let dataSize = totalJsonDataSize()

        // Add ~20% overhead for SQLite metadata/indexes (reasonable baseline)
        let expectedSize = Double(dataSize) * 1.2
        guard expectedSize > 0 else { return 1.0 }

        return Double(fileSize) / expectedSize
    }

    /// Check if the database needs vacuuming (bloat ratio > threshold)
    /// - Parameter threshold: Bloat ratio threshold (default 2.0 = 50%+ wasted space)
    static func needsVacuum(threshold: Double = 2.0) -> Bool {
        return bloatRatio() > threshold
    }

    /// Reclaim wasted space in the database by running VACUUM
    /// This can take a few seconds for large databases but significantly reduces file size
    /// - Returns: Bytes reclaimed, or nil if vacuum failed
    @discardableResult
    static func vacuum() -> Int64? {
        let beforeSize = databaseFileSize()

        do {
            // VACUUM cannot run inside a transaction, so use writeWithoutTransaction
            try shared.writeWithoutTransaction { db in
                try db.execute(sql: "VACUUM")
            }

            let afterSize = databaseFileSize()
            let reclaimed = beforeSize - afterSize

            if reclaimed > 0 {
                let reclaimedMB = Double(reclaimed) / 1_048_576.0
                print("[SessionDatabase] VACUUM reclaimed \(String(format: "%.2f", reclaimedMB)) MB")
            }

            return reclaimed
        } catch {
            print("[SessionDatabase] VACUUM failed: \(error)")
            return nil
        }
    }

    /// Automatically vacuum if bloat exceeds threshold
    /// Call this during app startup or periodic maintenance
    /// - Parameter threshold: Bloat ratio threshold (default 2.0)
    static func vacuumIfNeeded(threshold: Double = 2.0) {
        guard needsVacuum(threshold: threshold) else { return }

        let ratio = bloatRatio()
        print("[SessionDatabase] Bloat ratio \(String(format: "%.1f", ratio))x detected, running VACUUM...")

        // Run vacuum on background thread to avoid blocking app launch
        Task.detached(priority: .utility) {
            vacuum()
        }
    }
}
