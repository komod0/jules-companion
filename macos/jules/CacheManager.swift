import Foundation
import GRDB
import UserNotifications

/// Manages clearing of all caches and local databases in the app.
/// This includes the SQLite session database, UserDefaults preferences, and in-memory caches.
@MainActor
class CacheManager {
    static let shared = CacheManager()

    private let dbPool: DatabasePool

    // UserDefaults keys to clear (excludes API key which should be preserved)
    private let userDefaultsKeysToClear: [String] = [
        // Session/pagination
        "session_next_page_token",
        // Last used selections
        "lastUsedSourceId",
        "lastUsedBranch",
        "lastUsedBranchesPerSource",
        // UI state
        "isPopoverExpanded",
        // Local repo mappings
        "localRepoPathsKey",
        "localRepoBookmarksKey",
        // Font sizes
        "activityViewFontSize",
        "diffViewFontSize",
        // Offline sync
        "sources_last_sync_time",
        // Viewed messages tracking (per-session notification tracking)
        "viewedMessages"
    ]

    private init() {
        self.dbPool = AppDatabase.shared
    }

    /// Clears all caches and local databases.
    /// - Returns: A tuple containing success status and an optional error message
    func clearAllCaches() async -> (success: Bool, error: String?) {
        var errors: [String] = []

        // 1. Clear SQLite database (sessions)
        do {
            try await clearDatabase()
        } catch {
            errors.append("Database: \(error.localizedDescription)")
        }

        // 2. Clear UserDefaults (except API key)
        clearUserDefaults()

        // 3. Reset font sizes to defaults
        FontSizeManager.shared.resetToDefaults()

        // 4. Clear delivered notifications
        clearNotifications()

        // 5. Post notification for in-memory cache clearing
        NotificationCenter.default.post(name: .clearInMemoryCaches, object: nil)

        if errors.isEmpty {
            return (true, nil)
        } else {
            return (false, errors.joined(separator: "; "))
        }
    }

    /// Clears the SQLite session database (sessions, sources, pending sessions)
    private func clearDatabase() async throws {
        try await dbPool.write { db in
            try db.execute(sql: "DELETE FROM session")
            // Clear sources cache (will be refreshed on next fetch)
            try? db.execute(sql: "DELETE FROM source")
            // Clear pending sessions (user should be warned before this)
            try? db.execute(sql: "DELETE FROM pendingSession")
        }
    }

    /// Clears all UserDefaults keys except the API key
    private func clearUserDefaults() {
        let defaults = UserDefaults.standard
        for key in userDefaultsKeysToClear {
            defaults.removeObject(forKey: key)
        }

        // Also clear dynamic file path cache keys
        clearFilePathCacheKeys()

        defaults.synchronize()
    }

    /// Clears all file path cache keys (dynamic keys prefixed with FilePathCache_ and FilePathCacheScanState_)
    /// Also clears file path data from the database
    private func clearFilePathCacheKeys() {
        let defaults = UserDefaults.standard
        let allKeys = defaults.dictionaryRepresentation().keys

        // Clear old FilenameCache_ keys (legacy)
        for key in allKeys where key.hasPrefix("FilenameCache_") {
            defaults.removeObject(forKey: key)
        }

        // Clear new FilePathCache_ keys (legacy - now using database)
        for key in allKeys where key.hasPrefix("FilePathCache_") {
            defaults.removeObject(forKey: key)
        }

        // Clear FilePathCacheScanState_ keys (legacy - now using database)
        for key in allKeys where key.hasPrefix("FilePathCacheScanState_") {
            defaults.removeObject(forKey: key)
        }

        // Clear file path data from database
        Task {
            do {
                try await dbPool.write { db in
                    try? db.execute(sql: "DELETE FROM filePath")
                    try? db.execute(sql: "DELETE FROM repositoryScanState")
                }
            } catch {
                print("Error clearing file path cache from database: \(error)")
            }
        }
    }

    /// Clears all delivered and pending notifications
    private func clearNotifications() {
        let center = UNUserNotificationCenter.current()
        center.removeAllDeliveredNotifications()
        center.removeAllPendingNotificationRequests()
    }

    /// Returns the approximate size of the database file
    func getDatabaseSize() -> String {
        do {
            let fileManager = FileManager.default
            let appSupportURL = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            ).appendingPathComponent("Jules")

            let dbURL = appSupportURL.appendingPathComponent("db.sqlite")

            if let attributes = try? fileManager.attributesOfItem(atPath: dbURL.path),
               let fileSize = attributes[.size] as? Int64 {
                return ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
            }
        } catch {
            // Ignore errors
        }
        return "Unknown"
    }

    /// Returns the number of cached sessions
    func getCachedSessionCount() async -> Int {
        do {
            return try await dbPool.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session") ?? 0
            }
        } catch {
            return 0
        }
    }
}

// MARK: - Notification Extension

extension Notification.Name {
    /// Posted when in-memory caches should be cleared
    static let clearInMemoryCaches = Notification.Name("clearInMemoryCaches")
}
