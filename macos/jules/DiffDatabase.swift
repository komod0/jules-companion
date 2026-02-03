import GRDB
import Foundation

/// Separate database for storing cached diffs.
/// Using a dedicated database keeps diff data isolated from the main session database,
/// providing better performance through memory-mapped I/O and preventing bloat.
struct DiffDatabase {
    static let shared = makeShared()

    /// Pre-warms the database by accessing it on a background thread.
    /// Call this early in app launch to ensure the database is ready.
    static func preWarm() {
        Task.detached(priority: .userInitiated) {
            _ = shared
        }
    }

    private static func makeShared() -> DatabasePool {
        do {
            let fileManager = FileManager.default
            let appSupportURL = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("Jules")

            try fileManager.createDirectory(at: appSupportURL, withIntermediateDirectories: true)

            let dbURL = appSupportURL.appendingPathComponent("diffs.sqlite")

            var config = Configuration()
            // Optimize for read-heavy workload
            config.prepareDatabase { db in
                // Use adaptive memory-mapped I/O based on actual database size
                // This balances performance with memory usage - we use 2x the file size
                // capped between 16MB (minimum for performance) and 64MB (maximum to save memory)
                let fileSize = (try? FileManager.default.attributesOfItem(atPath: dbURL.path)[.size] as? Int64) ?? 0
                let adaptiveMmapSize = min(64 * 1024 * 1024, max(16 * 1024 * 1024, fileSize * 2))
                try db.execute(sql: "PRAGMA mmap_size = \(adaptiveMmapSize)")
                // Reduce fsync frequency for better write performance
                try db.execute(sql: "PRAGMA synchronous = NORMAL")
            }

            let dbPool = try DatabasePool(path: dbURL.path, configuration: config)
            try migrator.migrate(dbPool)
            return dbPool
        } catch {
            fatalError("Failed to create diff database: \(error)")
        }
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("createDiffs") { db in
            try db.create(table: "diff") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("sessionId", .text).notNull().indexed()
                t.column("patch", .text).notNull()
                t.column("language", .text)
                t.column("filename", .text)
                t.column("orderIndex", .integer).notNull().defaults(to: 0)
            }

            // Composite index for efficient session + order lookups
            try db.create(index: "idx_diff_session_order", on: "diff", columns: ["sessionId", "orderIndex"])
        }

        return migrator
    }
}

// MARK: - Diff Record

/// Database record for a cached diff
struct DiffRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "diff"

    var id: Int64?
    var sessionId: String
    var patch: String
    var language: String?
    var filename: String?
    var orderIndex: Int

    enum Columns {
        static let id = Column("id")
        static let sessionId = Column("sessionId")
        static let patch = Column("patch")
        static let language = Column("language")
        static let filename = Column("filename")
        static let orderIndex = Column("orderIndex")
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Database Operations

extension DiffDatabase {
    /// Save diffs for a session (replaces any existing diffs)
    static func saveDiffs(_ diffs: [CachedDiff], forSession sessionId: String) throws {
        try shared.write { db in
            // Delete existing diffs for this session
            try DiffRecord.filter(DiffRecord.Columns.sessionId == sessionId).deleteAll(db)

            // Insert new diffs
            for (index, diff) in diffs.enumerated() {
                var record = DiffRecord(
                    sessionId: sessionId,
                    patch: diff.patch,
                    language: diff.language,
                    filename: diff.filename,
                    orderIndex: index
                )
                try record.insert(db)
            }
        }
    }

    /// Load diffs for a session
    static func loadDiffs(forSession sessionId: String) -> [CachedDiff]? {
        do {
            let records = try shared.read { db in
                try DiffRecord
                    .filter(DiffRecord.Columns.sessionId == sessionId)
                    .order(DiffRecord.Columns.orderIndex)
                    .fetchAll(db)
            }

            guard !records.isEmpty else { return nil }

            return records.map { record in
                CachedDiff(patch: record.patch, language: record.language, filename: record.filename)
            }
        } catch {
            print("[DiffDatabase] Error loading diffs for session \(sessionId): \(error)")
            return nil
        }
    }

    /// Check if diffs exist for a session (fast indexed lookup)
    static func hasDiffs(forSession sessionId: String) -> Bool {
        do {
            return try shared.read { db in
                try DiffRecord.filter(DiffRecord.Columns.sessionId == sessionId).fetchCount(db) > 0
            }
        } catch {
            return false
        }
    }

    /// Delete diffs for a session
    static func deleteDiffs(forSession sessionId: String) {
        do {
            try shared.write { db in
                try DiffRecord.filter(DiffRecord.Columns.sessionId == sessionId).deleteAll(db)
            }
        } catch {
            print("[DiffDatabase] Error deleting diffs for session \(sessionId): \(error)")
        }
    }

    /// Delete diffs for multiple sessions
    static func deleteDiffs(forSessions sessionIds: [String]) {
        guard !sessionIds.isEmpty else { return }
        do {
            try shared.write { db in
                try DiffRecord.filter(sessionIds.contains(DiffRecord.Columns.sessionId)).deleteAll(db)
            }
        } catch {
            print("[DiffDatabase] Error deleting diffs for sessions: \(error)")
        }
    }

    /// Clean up orphaned diffs (sessions that no longer exist)
    static func cleanupOrphanedDiffs(keepingSessions validSessionIds: Set<String>) {
        guard !validSessionIds.isEmpty else { return }
        do {
            try shared.write { db in
                try DiffRecord.filter(!validSessionIds.contains(DiffRecord.Columns.sessionId)).deleteAll(db)
            }
        } catch {
            print("[DiffDatabase] Error during cleanup: \(error)")
        }
    }

    /// Get total count of diffs (for diagnostics)
    static func totalDiffCount() -> Int {
        do {
            return try shared.read { db in
                try DiffRecord.fetchCount(db)
            }
        } catch {
            return 0
        }
    }

    /// Get count of sessions with diffs (for diagnostics)
    static func sessionCount() -> Int {
        do {
            return try shared.read { db in
                try String.fetchAll(db, sql: "SELECT DISTINCT sessionId FROM diff").count
            }
        } catch {
            return 0
        }
    }

    /// Get the database file size in bytes (for diagnostics)
    static func databaseFileSize() -> Int64 {
        do {
            let fileManager = FileManager.default
            let appSupportURL = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            ).appendingPathComponent("Jules").appendingPathComponent("diffs.sqlite")

            let attributes = try fileManager.attributesOfItem(atPath: appSupportURL.path)
            return attributes[.size] as? Int64 ?? 0
        } catch {
            return 0
        }
    }

    /// Get total size of all patch data in bytes (for diagnostics)
    static func totalPatchDataSize() -> Int64 {
        do {
            return try shared.read { db in
                try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(LENGTH(patch)), 0) FROM diff") ?? 0
            }
        } catch {
            return 0
        }
    }

    /// Log comprehensive database diagnostics
    static func logDiagnostics() {
        let fileSize = databaseFileSize()
        let diffCount = totalDiffCount()
        let sessCount = sessionCount()
        let patchDataSize = totalPatchDataSize()

        let fileSizeMB = Double(fileSize) / 1_048_576.0
        let patchDataMB = Double(patchDataSize) / 1_048_576.0

        print("═══════════════════════════════════════════════════════")
        print("📊 [DiffDatabase] Diagnostics:")
        print("   Database file size: \(String(format: "%.2f", fileSizeMB)) MB")
        print("   Total patch data:   \(String(format: "%.2f", patchDataMB)) MB")
        print("   Total diffs:        \(diffCount)")
        print("   Sessions with diffs: \(sessCount)")
        if sessCount > 0 {
            print("   Avg diffs/session:  \(diffCount / sessCount)")
            print("   Avg patch size:     \(patchDataSize / Int64(max(1, diffCount))) bytes")
        }
        print("═══════════════════════════════════════════════════════")
    }

    /// Reclaim wasted space in the database by running VACUUM
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
                print("[DiffDatabase] VACUUM reclaimed \(String(format: "%.2f", reclaimedMB)) MB")
            }

            return reclaimed
        } catch {
            print("[DiffDatabase] VACUUM failed: \(error)")
            return nil
        }
    }
}
