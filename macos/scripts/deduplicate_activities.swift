#!/usr/bin/env swift
// deduplicate_activities.swift
// A script to deduplicate activities in the Jules database
// Run with: swift scripts/deduplicate_activities.swift
// Or make executable: chmod +x scripts/deduplicate_activities.swift && ./scripts/deduplicate_activities.swift

import Foundation
import SQLite3

// MARK: - Database Path
func getDatabasePath() -> String {
    let fileManager = FileManager.default
    guard let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
        fatalError("Could not find Application Support directory")
    }
    return appSupportURL.appendingPathComponent("Jules/db.sqlite").path
}

// MARK: - SQLite Helpers
class Database {
    private var db: OpaquePointer?

    init(path: String) throws {
        var dbPointer: OpaquePointer?
        if sqlite3_open(path, &dbPointer) != SQLITE_OK {
            throw NSError(domain: "SQLite", code: Int(sqlite3_errcode(dbPointer)), userInfo: [
                NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(dbPointer))
            ])
        }
        self.db = dbPointer
    }

    deinit {
        sqlite3_close(db)
    }

    func query(_ sql: String) throws -> [[String: Any]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "SQLite", code: Int(sqlite3_errcode(db)), userInfo: [
                NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))
            ])
        }
        defer { sqlite3_finalize(stmt) }

        var results: [[String: Any]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: Any] = [:]
            let columnCount = sqlite3_column_count(stmt)
            for i in 0..<columnCount {
                let columnName = String(cString: sqlite3_column_name(stmt, i))
                let columnType = sqlite3_column_type(stmt, i)

                switch columnType {
                case SQLITE_TEXT:
                    if let text = sqlite3_column_text(stmt, i) {
                        row[columnName] = String(cString: text)
                    }
                case SQLITE_INTEGER:
                    row[columnName] = sqlite3_column_int64(stmt, i)
                case SQLITE_FLOAT:
                    row[columnName] = sqlite3_column_double(stmt, i)
                case SQLITE_BLOB:
                    if let bytes = sqlite3_column_blob(stmt, i) {
                        let length = sqlite3_column_bytes(stmt, i)
                        row[columnName] = Data(bytes: bytes, count: Int(length))
                    }
                case SQLITE_NULL:
                    row[columnName] = NSNull()
                default:
                    break
                }
            }
            results.append(row)
        }
        return results
    }

    func execute(_ sql: String, parameters: [Any] = []) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "SQLite", code: Int(sqlite3_errcode(db)), userInfo: [
                NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))
            ])
        }
        defer { sqlite3_finalize(stmt) }

        for (index, param) in parameters.enumerated() {
            let sqlIndex = Int32(index + 1)
            if let text = param as? String {
                sqlite3_bind_text(stmt, sqlIndex, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            } else if let data = param as? Data {
                data.withUnsafeBytes { ptr in
                    sqlite3_bind_blob(stmt, sqlIndex, ptr.baseAddress, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
            } else if let int = param as? Int64 {
                sqlite3_bind_int64(stmt, sqlIndex, int)
            } else if let double = param as? Double {
                sqlite3_bind_double(stmt, sqlIndex, double)
            }
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw NSError(domain: "SQLite", code: Int(sqlite3_errcode(db)), userInfo: [
                NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))
            ])
        }
    }
}

// MARK: - Deduplication Logic
func deduplicateActivities(in jsonData: Data) throws -> (Data, Int, Int) {
    guard var session = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
        return (jsonData, 0, 0)
    }

    guard var activities = session["activities"] as? [[String: Any]], !activities.isEmpty else {
        return (jsonData, 0, 0)
    }

    let originalCount = activities.count

    // Deduplicate by ID, keeping the last occurrence (most recent data)
    var seenIds = Set<String>()
    var deduplicatedActivities: [[String: Any]] = []

    // Process in reverse to keep the last occurrence, then reverse back
    for activity in activities.reversed() {
        if let id = activity["id"] as? String {
            if !seenIds.contains(id) {
                seenIds.insert(id)
                deduplicatedActivities.append(activity)
            }
        } else {
            // Keep activities without IDs (shouldn't happen but be safe)
            deduplicatedActivities.append(activity)
        }
    }

    // Reverse back to restore original order
    deduplicatedActivities = deduplicatedActivities.reversed()

    let newCount = deduplicatedActivities.count
    let duplicatesRemoved = originalCount - newCount

    if duplicatesRemoved > 0 {
        session["activities"] = deduplicatedActivities
        let newJsonData = try JSONSerialization.data(withJSONObject: session)
        return (newJsonData, originalCount, newCount)
    }

    return (jsonData, originalCount, newCount)
}

// MARK: - Main Script
func main() {
    print("🔧 Jules Database Deduplication Script")
    print("======================================\n")

    let dbPath = getDatabasePath()
    print("📁 Database path: \(dbPath)")

    // Check if database exists
    guard FileManager.default.fileExists(atPath: dbPath) else {
        print("❌ Database not found at \(dbPath)")
        print("   Make sure Jules has been run at least once.")
        exit(1)
    }

    // Create backup
    let backupPath = dbPath + ".backup-\(Int(Date().timeIntervalSince1970))"
    do {
        try FileManager.default.copyItem(atPath: dbPath, toPath: backupPath)
        print("💾 Backup created: \(backupPath)\n")
    } catch {
        print("⚠️  Warning: Could not create backup: \(error.localizedDescription)")
        print("   Proceeding anyway...\n")
    }

    do {
        let db = try Database(path: dbPath)

        // Get all sessions
        let sessions = try db.query("SELECT id, json FROM session")
        print("📊 Found \(sessions.count) sessions in database\n")

        var totalDuplicatesRemoved = 0
        var sessionsWithDuplicates = 0

        for session in sessions {
            guard let sessionId = session["id"] as? String,
                  let jsonString = session["json"] as? String,
                  let jsonData = jsonString.data(using: .utf8) else {
                continue
            }

            do {
                let (newJsonData, originalCount, newCount) = try deduplicateActivities(in: jsonData)
                let duplicatesRemoved = originalCount - newCount

                if duplicatesRemoved > 0 {
                    sessionsWithDuplicates += 1
                    totalDuplicatesRemoved += duplicatesRemoved

                    // Update the session
                    if let newJsonString = String(data: newJsonData, encoding: .utf8) {
                        try db.execute("UPDATE session SET json = ? WHERE id = ?", parameters: [newJsonString, sessionId])
                        print("✅ Session \(sessionId.prefix(8))...: removed \(duplicatesRemoved) duplicate activities (\(originalCount) → \(newCount))")
                    }
                }
            } catch {
                print("⚠️  Error processing session \(sessionId.prefix(8))...: \(error.localizedDescription)")
            }
        }

        print("\n======================================")
        print("📈 Summary:")
        print("   Sessions processed: \(sessions.count)")
        print("   Sessions with duplicates: \(sessionsWithDuplicates)")
        print("   Total duplicates removed: \(totalDuplicatesRemoved)")

        if totalDuplicatesRemoved > 0 {
            print("\n✨ Database cleaned successfully!")
            print("   Backup saved at: \(backupPath)")
        } else {
            print("\n✨ No duplicates found. Database is clean!")
            // Remove unnecessary backup
            try? FileManager.default.removeItem(atPath: backupPath)
        }

    } catch {
        print("❌ Error: \(error.localizedDescription)")
        exit(1)
    }
}

main()
