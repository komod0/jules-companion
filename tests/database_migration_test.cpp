/**
 * @file database_migration_test.cpp
 * @brief Unit tests for Database migration system
 *
 * Tests the migration upgrade path in database.cpp, verifying:
 * - Fresh database initializes to latest version
 * - Table schemas exist after initialization
 * - Re-initializing an existing database doesn't corrupt data
 * - Correct schema version tracking
 */

#include <gtest/gtest.h>
#include <QApplication>
#include <QTemporaryDir>
#include <QSqlQuery>
#include <QSqlError>

#include "data/database.h"

namespace jules {
namespace test {

class DatabaseMigrationTest : public ::testing::Test {
protected:
    void SetUp() override {
        tmpDir = std::make_unique<QTemporaryDir>();
        ASSERT_TRUE(tmpDir->isValid());
    }

    void TearDown() override {
        tmpDir.reset();
    }

    std::unique_ptr<QTemporaryDir> tmpDir;
};

// Fresh database initializes to latest version (v3)
TEST_F(DatabaseMigrationTest, FreshDatabaseInitializesToLatestVersion) {
    Database db(tmpDir->path());
    ASSERT_TRUE(db.initialize());
    EXPECT_EQ(db.schemaVersion(), 3);
}

// Verify all expected tables exist after initialization
TEST_F(DatabaseMigrationTest, AllTablesExistAfterInitialization) {
    Database db(tmpDir->path());
    ASSERT_TRUE(db.initialize());

    QSqlDatabase sqlDb = db.database();
    QStringList tables = sqlDb.tables();

    EXPECT_TRUE(tables.contains("sessions"));
    EXPECT_TRUE(tables.contains("cached_diffs"));
    EXPECT_TRUE(tables.contains("pending_sessions"));
    EXPECT_TRUE(tables.contains("schema_version"));
}

// Verify sessions table columns from migration v1
TEST_F(DatabaseMigrationTest, SessionsTableHasCorrectSchema) {
    Database db(tmpDir->path());
    ASSERT_TRUE(db.initialize());

    QSqlQuery query(db.database());
    ASSERT_TRUE(query.exec("PRAGMA table_info(sessions)"));

    QStringList columns;
    while (query.next()) {
        columns.append(query.value("name").toString());
    }

    EXPECT_TRUE(columns.contains("id"));
    EXPECT_TRUE(columns.contains("json"));
    EXPECT_TRUE(columns.contains("create_time"));
    EXPECT_TRUE(columns.contains("update_time"));
    EXPECT_TRUE(columns.contains("state"));
    EXPECT_TRUE(columns.contains("has_cached_diffs"));
    EXPECT_TRUE(columns.contains("last_activity_poll_time"));
    EXPECT_TRUE(columns.contains("viewed_post_completion_at"));
}

// Verify cached_diffs table columns from migration v1
TEST_F(DatabaseMigrationTest, CachedDiffsTableHasCorrectSchema) {
    Database db(tmpDir->path());
    ASSERT_TRUE(db.initialize());

    QSqlQuery query(db.database());
    ASSERT_TRUE(query.exec("PRAGMA table_info(cached_diffs)"));

    QStringList columns;
    while (query.next()) {
        columns.append(query.value("name").toString());
    }

    EXPECT_TRUE(columns.contains("id"));
    EXPECT_TRUE(columns.contains("session_id"));
    EXPECT_TRUE(columns.contains("patch"));
    EXPECT_TRUE(columns.contains("language"));
    EXPECT_TRUE(columns.contains("filename"));
    EXPECT_TRUE(columns.contains("order_index"));
}

// Verify pending_sessions table from migration v3
TEST_F(DatabaseMigrationTest, PendingSessionsTableHasCorrectSchema) {
    Database db(tmpDir->path());
    ASSERT_TRUE(db.initialize());

    QSqlQuery query(db.database());
    ASSERT_TRUE(query.exec("PRAGMA table_info(pending_sessions)"));

    QStringList columns;
    while (query.next()) {
        columns.append(query.value("name").toString());
    }

    EXPECT_TRUE(columns.contains("id"));
    EXPECT_TRUE(columns.contains("json_payload"));
    EXPECT_TRUE(columns.contains("created_at"));
    EXPECT_TRUE(columns.contains("retry_count"));
    EXPECT_TRUE(columns.contains("last_retry_at"));
    EXPECT_TRUE(columns.contains("status"));
}

// Re-initializing does not corrupt existing data
TEST_F(DatabaseMigrationTest, ReInitializeDoesNotCorruptData) {
    // First initialization - insert some data
    {
        Database db(tmpDir->path());
        ASSERT_TRUE(db.initialize());

        QSqlQuery query(db.database());
        ASSERT_TRUE(query.exec(
            "INSERT INTO sessions (id, json, state) "
            "VALUES ('test-session-1', '{\"prompt\":\"fix bug\"}', 'COMPLETED')"));
        ASSERT_TRUE(query.exec(
            "INSERT INTO sessions (id, json, state) "
            "VALUES ('test-session-2', '{\"prompt\":\"add feature\"}', 'QUEUED')"));
    }

    // Second initialization - data should still be there
    {
        Database db(tmpDir->path());
        ASSERT_TRUE(db.initialize());
        EXPECT_EQ(db.schemaVersion(), 3);

        QSqlQuery query(db.database());
        ASSERT_TRUE(query.exec("SELECT COUNT(*) FROM sessions"));
        ASSERT_TRUE(query.next());
        EXPECT_EQ(query.value(0).toInt(), 2);

        // Verify specific data
        ASSERT_TRUE(query.exec("SELECT json FROM sessions WHERE id = 'test-session-1'"));
        ASSERT_TRUE(query.next());
        EXPECT_EQ(query.value(0).toString(), QString("{\"prompt\":\"fix bug\"}"));
    }
}

// Schema version is correctly tracked in the database
TEST_F(DatabaseMigrationTest, SchemaVersionIsPersistedCorrectly) {
    {
        Database db(tmpDir->path());
        ASSERT_TRUE(db.initialize());

        QSqlQuery query(db.database());
        ASSERT_TRUE(query.exec("SELECT version FROM schema_version LIMIT 1"));
        ASSERT_TRUE(query.next());
        EXPECT_EQ(query.value(0).toInt(), 3);
    }

    // Re-open and verify version persists
    {
        Database db(tmpDir->path());
        ASSERT_TRUE(db.initialize());
        EXPECT_EQ(db.schemaVersion(), 3);
    }
}

// Database path and file size methods work correctly
TEST_F(DatabaseMigrationTest, DatabasePathAndFileSizeAreValid) {
    Database db(tmpDir->path());
    ASSERT_TRUE(db.initialize());

    EXPECT_FALSE(db.databasePath().isEmpty());
    EXPECT_TRUE(db.databasePath().endsWith("jules.db"));
    EXPECT_GT(db.databaseFileSize(), 0);
}

// Indexes are created from migrations v1 and v2
TEST_F(DatabaseMigrationTest, IndexesExistAfterMigrations) {
    Database db(tmpDir->path());
    ASSERT_TRUE(db.initialize());

    QSqlQuery query(db.database());
    ASSERT_TRUE(query.exec(
        "SELECT name FROM sqlite_master WHERE type='index' AND name LIKE 'idx_%'"));

    QStringList indexes;
    while (query.next()) {
        indexes.append(query.value(0).toString());
    }

    // From migration v1
    EXPECT_TRUE(indexes.contains("idx_sessions_state"));
    EXPECT_TRUE(indexes.contains("idx_sessions_create_time"));
    EXPECT_TRUE(indexes.contains("idx_cached_diffs_session_id"));

    // From migration v2
    EXPECT_TRUE(indexes.contains("idx_sessions_state_create_time"));

    // From migration v3
    EXPECT_TRUE(indexes.contains("idx_pending_sessions_status"));
}

// WAL journal mode is enabled
TEST_F(DatabaseMigrationTest, WALModeIsEnabled) {
    Database db(tmpDir->path());
    ASSERT_TRUE(db.initialize());

    QSqlQuery query(db.database());
    ASSERT_TRUE(query.exec("PRAGMA journal_mode"));
    ASSERT_TRUE(query.next());
    EXPECT_EQ(query.value(0).toString().toLower(), QString("wal"));
}

// Multiple Database instances get unique connection names
TEST_F(DatabaseMigrationTest, MultipleDatabaseInstancesHaveUniqueConnections) {
    QTemporaryDir tmpDir2;
    ASSERT_TRUE(tmpDir2.isValid());

    Database db1(tmpDir->path());
    Database db2(tmpDir2.path());

    ASSERT_TRUE(db1.initialize());
    ASSERT_TRUE(db2.initialize());

    // Both should be at latest version independently
    EXPECT_EQ(db1.schemaVersion(), 3);
    EXPECT_EQ(db2.schemaVersion(), 3);

    // They should have different database paths
    EXPECT_NE(db1.databasePath(), db2.databasePath());
}

// Data directory is created if it does not exist
TEST_F(DatabaseMigrationTest, CreatesDataDirectoryIfMissing) {
    QString nestedPath = tmpDir->path() + "/sub/dir/data";
    Database db(nestedPath);
    ASSERT_TRUE(db.initialize());
    EXPECT_EQ(db.schemaVersion(), 3);
}

} // namespace test
} // namespace jules

int main(int argc, char** argv) {
    QApplication app(argc, argv);
    QCoreApplication::setOrganizationName("JulesLinuxTest");
    QCoreApplication::setApplicationName("DatabaseMigrationTest");
    ::testing::InitGoogleTest(&argc, argv);
    return RUN_ALL_TESTS();
}
