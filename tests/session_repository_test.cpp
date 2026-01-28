/**
 * @file session_repository_test.cpp
 * @brief Unit tests for SessionRepository and Database classes
 * 
 * TDD approach: These tests define the expected data layer behavior.
 * Tests database schema, CRUD operations, reactive notifications, and diff storage.
 */

#include <gtest/gtest.h>
#include <QCoreApplication>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QDir>
#include <QFile>
#include <QSqlDatabase>
#include <QSqlQuery>
#include <QSqlError>
#include <QTimer>
#include <QJsonDocument>
#include <QJsonObject>

#include "data/database.h"
#include "data/session_repository.h"
#include "api/jules_api_client.h"

namespace jules {
namespace test {

// ============================================================================
// Test Fixture
// ============================================================================

class SessionRepositoryTest : public ::testing::Test {
protected:
    void SetUp() override {
        m_tempDir = std::make_unique<QTemporaryDir>();
        ASSERT_TRUE(m_tempDir->isValid());
        
        // Initialize database in temp directory
        m_db = std::make_unique<Database>(m_tempDir->path());
        ASSERT_TRUE(m_db->initialize());
        
        m_repository = std::make_unique<SessionRepository>(m_db.get());
    }

    void TearDown() override {
        m_repository.reset();
        m_db.reset();
        m_tempDir.reset();
    }

    // Helper to process Qt events
    void processEvents(int timeoutMs = 50) {
        QEventLoop loop;
        QTimer::singleShot(timeoutMs, &loop, &QEventLoop::quit);
        loop.exec();
    }

    // Helper to create a test session
    Session createTestSession(const QString& id, const QString& prompt, 
                               SessionState state = SessionState::Queued) {
        Session session;
        session.id = id;
        session.name = "sessions/" + id;
        session.prompt = prompt;
        session.state = state;
        session.createTime = QDateTime::currentDateTimeUtc().toString(Qt::ISODate);
        session.updateTime = session.createTime;
        return session;
    }

    std::unique_ptr<QTemporaryDir> m_tempDir;
    std::unique_ptr<Database> m_db;
    std::unique_ptr<SessionRepository> m_repository;
};

// ============================================================================
// Database Initialization Tests
// ============================================================================

TEST_F(SessionRepositoryTest, DatabaseCreatesFileAtExpectedLocation) {
    QString dbPath = m_tempDir->path() + "/jules.db";
    EXPECT_TRUE(QFile::exists(dbPath));
}

TEST_F(SessionRepositoryTest, DatabaseCreatesSessionsTable) {
    QSqlDatabase sqlDb = m_db->database();
    ASSERT_TRUE(sqlDb.isOpen());
    
    QSqlQuery query(sqlDb);
    ASSERT_TRUE(query.exec("SELECT name FROM sqlite_master WHERE type='table' AND name='sessions'"));
    ASSERT_TRUE(query.next());
    EXPECT_EQ(query.value(0).toString(), QString("sessions"));
}

TEST_F(SessionRepositoryTest, DatabaseCreatesDiffsTable) {
    QSqlDatabase sqlDb = m_db->database();
    ASSERT_TRUE(sqlDb.isOpen());
    
    QSqlQuery query(sqlDb);
    ASSERT_TRUE(query.exec("SELECT name FROM sqlite_master WHERE type='table' AND name='cached_diffs'"));
    ASSERT_TRUE(query.next());
    EXPECT_EQ(query.value(0).toString(), QString("cached_diffs"));
}

TEST_F(SessionRepositoryTest, SessionsTableHasExpectedColumns) {
    QSqlDatabase sqlDb = m_db->database();
    QSqlQuery query(sqlDb);
    
    ASSERT_TRUE(query.exec("PRAGMA table_info(sessions)"));
    
    QStringList columns;
    while (query.next()) {
        columns << query.value(1).toString();
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

TEST_F(SessionRepositoryTest, CachedDiffsTableHasExpectedColumns) {
    QSqlDatabase sqlDb = m_db->database();
    QSqlQuery query(sqlDb);
    
    ASSERT_TRUE(query.exec("PRAGMA table_info(cached_diffs)"));
    
    QStringList columns;
    while (query.next()) {
        columns << query.value(1).toString();
    }
    
    EXPECT_TRUE(columns.contains("id"));
    EXPECT_TRUE(columns.contains("session_id"));
    EXPECT_TRUE(columns.contains("patch"));
    EXPECT_TRUE(columns.contains("language"));
    EXPECT_TRUE(columns.contains("filename"));
    EXPECT_TRUE(columns.contains("order_index"));
}

TEST_F(SessionRepositoryTest, DatabaseVersionTrackingExists) {
    int version = m_db->schemaVersion();
    EXPECT_GE(version, 1);
}

// ============================================================================
// Session CRUD Tests
// ============================================================================

TEST_F(SessionRepositoryTest, SaveAndRetrieveSession) {
    Session session = createTestSession("test-123", "Fix the bug");
    
    bool saved = m_repository->saveSession(session);
    ASSERT_TRUE(saved);
    
    auto retrieved = m_repository->getSession("test-123");
    ASSERT_TRUE(retrieved.has_value());
    EXPECT_EQ(retrieved->id, QString("test-123"));
    EXPECT_EQ(retrieved->prompt, QString("Fix the bug"));
    EXPECT_EQ(retrieved->state, SessionState::Queued);
}

TEST_F(SessionRepositoryTest, GetSessionReturnsNulloptForNonexistent) {
    auto session = m_repository->getSession("nonexistent-id");
    EXPECT_FALSE(session.has_value());
}

TEST_F(SessionRepositoryTest, UpdateExistingSession) {
    Session session = createTestSession("update-test", "Original prompt");
    m_repository->saveSession(session);
    
    session.prompt = "Updated prompt";
    session.state = SessionState::InProgress;
    m_repository->saveSession(session);
    
    auto retrieved = m_repository->getSession("update-test");
    ASSERT_TRUE(retrieved.has_value());
    EXPECT_EQ(retrieved->prompt, QString("Updated prompt"));
    EXPECT_EQ(retrieved->state, SessionState::InProgress);
}

TEST_F(SessionRepositoryTest, DeleteSession) {
    Session session = createTestSession("delete-test", "To be deleted");
    m_repository->saveSession(session);
    
    bool deleted = m_repository->deleteSession("delete-test");
    EXPECT_TRUE(deleted);
    
    auto retrieved = m_repository->getSession("delete-test");
    EXPECT_FALSE(retrieved.has_value());
}

TEST_F(SessionRepositoryTest, DeleteNonexistentSessionReturnsFalse) {
    bool deleted = m_repository->deleteSession("nonexistent");
    EXPECT_FALSE(deleted);
}

TEST_F(SessionRepositoryTest, GetAllSessionsReturnsEmpty) {
    QList<Session> sessions = m_repository->getAllSessions();
    EXPECT_TRUE(sessions.isEmpty());
}

TEST_F(SessionRepositoryTest, GetAllSessionsReturnsSaved) {
    m_repository->saveSession(createTestSession("sess-1", "First"));
    m_repository->saveSession(createTestSession("sess-2", "Second"));
    m_repository->saveSession(createTestSession("sess-3", "Third"));
    
    QList<Session> sessions = m_repository->getAllSessions();
    EXPECT_EQ(sessions.size(), 3);
}

TEST_F(SessionRepositoryTest, GetAllSessionsOrderedByCreateTimeDesc) {
    Session s1 = createTestSession("old", "Old session");
    s1.createTime = "2024-01-01T00:00:00Z";
    
    Session s2 = createTestSession("mid", "Mid session");
    s2.createTime = "2024-06-15T12:00:00Z";
    
    Session s3 = createTestSession("new", "New session");
    s3.createTime = "2024-12-31T23:59:59Z";
    
    // Save in random order
    m_repository->saveSession(s2);
    m_repository->saveSession(s1);
    m_repository->saveSession(s3);
    
    QList<Session> sessions = m_repository->getAllSessions();
    ASSERT_EQ(sessions.size(), 3);
    EXPECT_EQ(sessions[0].id, QString("new"));
    EXPECT_EQ(sessions[1].id, QString("mid"));
    EXPECT_EQ(sessions[2].id, QString("old"));
}

TEST_F(SessionRepositoryTest, GetSessionsWithLimit) {
    for (int i = 0; i < 10; ++i) {
        m_repository->saveSession(createTestSession(
            QString("sess-%1").arg(i), 
            QString("Session %1").arg(i)
        ));
    }
    
    QList<Session> sessions = m_repository->getSessions(5);
    EXPECT_EQ(sessions.size(), 5);
}

TEST_F(SessionRepositoryTest, GetSessionsWithLimitAndOffset) {
    for (int i = 0; i < 10; ++i) {
        Session s = createTestSession(QString("sess-%1").arg(i), QString("Session %1").arg(i));
        s.createTime = QString("2024-01-%1T00:00:00Z").arg(10 - i, 2, 10, QChar('0'));
        m_repository->saveSession(s);
    }
    
    QList<Session> sessions = m_repository->getSessions(3, 2);
    EXPECT_EQ(sessions.size(), 3);
}

TEST_F(SessionRepositoryTest, GetSessionCount) {
    EXPECT_EQ(m_repository->sessionCount(), 0);
    
    m_repository->saveSession(createTestSession("s1", "One"));
    m_repository->saveSession(createTestSession("s2", "Two"));
    
    EXPECT_EQ(m_repository->sessionCount(), 2);
}

// ============================================================================
// Session State Filtering Tests
// ============================================================================

TEST_F(SessionRepositoryTest, GetActiveSessions) {
    m_repository->saveSession(createTestSession("queued", "Q", SessionState::Queued));
    m_repository->saveSession(createTestSession("progress", "P", SessionState::InProgress));
    m_repository->saveSession(createTestSession("completed", "C", SessionState::Completed));
    m_repository->saveSession(createTestSession("failed", "F", SessionState::Failed));
    m_repository->saveSession(createTestSession("awaiting", "A", SessionState::AwaitingUserFeedback));
    
    QList<Session> active = m_repository->getActiveSessions();
    EXPECT_EQ(active.size(), 3);
    
    for (const auto& s : active) {
        EXPECT_TRUE(s.isActive());
    }
}

TEST_F(SessionRepositoryTest, GetNewestSession) {
    Session s1 = createTestSession("old", "Old");
    s1.createTime = "2024-01-01T00:00:00Z";
    
    Session s2 = createTestSession("new", "New");
    s2.createTime = "2024-12-31T23:59:59Z";
    
    m_repository->saveSession(s1);
    m_repository->saveSession(s2);
    
    auto newest = m_repository->getNewestSession();
    ASSERT_TRUE(newest.has_value());
    EXPECT_EQ(newest->id, QString("new"));
}

// ============================================================================
// Diff Storage Tests
// ============================================================================

TEST_F(SessionRepositoryTest, SaveAndRetrieveDiffs) {
    Session session = createTestSession("diff-test", "Test diffs");
    m_repository->saveSession(session);
    
    QList<CachedDiff> diffs;
    CachedDiff diff1;
    diff1.patch = "--- a/file.cpp\n+++ b/file.cpp\n@@ -1,1 +1,2 @@\n+added line";
    diff1.filename = "file.cpp";
    diff1.language = "cpp";
    diffs.append(diff1);
    
    CachedDiff diff2;
    diff2.patch = "--- a/other.py\n+++ b/other.py\n@@ -1,1 +1,2 @@\n+print('hello')";
    diff2.filename = "other.py";
    diff2.language = "python";
    diffs.append(diff2);
    
    bool saved = m_repository->saveDiffs("diff-test", diffs);
    ASSERT_TRUE(saved);
    
    QList<CachedDiff> retrieved = m_repository->getDiffs("diff-test");
    ASSERT_EQ(retrieved.size(), 2);
    EXPECT_EQ(retrieved[0].filename, QString("file.cpp"));
    EXPECT_EQ(retrieved[0].language, QString("cpp"));
    EXPECT_EQ(retrieved[1].filename, QString("other.py"));
}

TEST_F(SessionRepositoryTest, GetDiffsReturnsEmptyForNoDiffs) {
    Session session = createTestSession("no-diffs", "No diffs");
    m_repository->saveSession(session);
    
    QList<CachedDiff> diffs = m_repository->getDiffs("no-diffs");
    EXPECT_TRUE(diffs.isEmpty());
}

TEST_F(SessionRepositoryTest, HasDiffsReturnsTrueWhenDiffsExist) {
    Session session = createTestSession("has-diffs", "Has diffs");
    m_repository->saveSession(session);
    
    EXPECT_FALSE(m_repository->hasDiffs("has-diffs"));
    
    QList<CachedDiff> diffs;
    CachedDiff diff;
    diff.patch = "some patch";
    diffs.append(diff);
    m_repository->saveDiffs("has-diffs", diffs);
    
    EXPECT_TRUE(m_repository->hasDiffs("has-diffs"));
}

TEST_F(SessionRepositoryTest, DeleteDiffsWhenSessionDeleted) {
    Session session = createTestSession("delete-diffs", "Delete diffs test");
    m_repository->saveSession(session);
    
    QList<CachedDiff> diffs;
    CachedDiff diff;
    diff.patch = "some patch";
    diffs.append(diff);
    m_repository->saveDiffs("delete-diffs", diffs);
    
    EXPECT_TRUE(m_repository->hasDiffs("delete-diffs"));
    
    m_repository->deleteSession("delete-diffs");
    
    // Diffs should be deleted along with session
    EXPECT_FALSE(m_repository->hasDiffs("delete-diffs"));
}

TEST_F(SessionRepositoryTest, ReplaceDiffsOnSave) {
    Session session = createTestSession("replace-diffs", "Replace test");
    m_repository->saveSession(session);
    
    // Save initial diffs
    QList<CachedDiff> initial;
    CachedDiff d1;
    d1.patch = "first";
    initial.append(d1);
    m_repository->saveDiffs("replace-diffs", initial);
    
    EXPECT_EQ(m_repository->getDiffs("replace-diffs").size(), 1);
    
    QList<CachedDiff> replacement;
    CachedDiff d2, d3;
    d2.patch = "second";
    d3.patch = "third";
    replacement.append(d2);
    replacement.append(d3);
    m_repository->saveDiffs("replace-diffs", replacement);
    
    QList<CachedDiff> retrieved = m_repository->getDiffs("replace-diffs");
    EXPECT_EQ(retrieved.size(), 2);
    EXPECT_EQ(retrieved[0].patch, QString("second"));
}

TEST_F(SessionRepositoryTest, DiffOrderPreserved) {
    Session session = createTestSession("order-test", "Order test");
    m_repository->saveSession(session);
    
    QList<CachedDiff> diffs;
    for (int i = 0; i < 5; ++i) {
        CachedDiff d;
        d.patch = QString("patch-%1").arg(i);
        d.filename = QString("file%1.txt").arg(i);
        diffs.append(d);
    }
    m_repository->saveDiffs("order-test", diffs);
    
    QList<CachedDiff> retrieved = m_repository->getDiffs("order-test");
    ASSERT_EQ(retrieved.size(), 5);
    for (int i = 0; i < 5; ++i) {
        EXPECT_EQ(retrieved[i].patch, QString("patch-%1").arg(i));
    }
}

// ============================================================================
// Reactive Notification Tests
// ============================================================================

TEST_F(SessionRepositoryTest, EmitsSessionChangedOnSave) {
    QSignalSpy spy(m_repository.get(), &SessionRepository::sessionChanged);
    
    Session session = createTestSession("signal-test", "Signal test");
    m_repository->saveSession(session);
    
    processEvents();
    
    ASSERT_GE(spy.count(), 1);
    QString changedId = spy.at(0).at(0).toString();
    EXPECT_EQ(changedId, QString("signal-test"));
}

TEST_F(SessionRepositoryTest, EmitsSessionChangedOnUpdate) {
    Session session = createTestSession("update-signal", "Initial");
    m_repository->saveSession(session);
    
    QSignalSpy spy(m_repository.get(), &SessionRepository::sessionChanged);
    
    session.prompt = "Updated";
    m_repository->saveSession(session);
    
    processEvents();
    
    ASSERT_GE(spy.count(), 1);
}

TEST_F(SessionRepositoryTest, EmitsSessionDeletedOnDelete) {
    Session session = createTestSession("delete-signal", "To delete");
    m_repository->saveSession(session);
    
    QSignalSpy spy(m_repository.get(), &SessionRepository::sessionDeleted);
    
    m_repository->deleteSession("delete-signal");
    
    processEvents();
    
    ASSERT_EQ(spy.count(), 1);
    QString deletedId = spy.at(0).at(0).toString();
    EXPECT_EQ(deletedId, QString("delete-signal"));
}

TEST_F(SessionRepositoryTest, EmitsSessionsReloadedOnBulkLoad) {
    QSignalSpy spy(m_repository.get(), &SessionRepository::sessionsReloaded);
    
    QList<Session> sessions;
    sessions.append(createTestSession("bulk-1", "First"));
    sessions.append(createTestSession("bulk-2", "Second"));
    
    m_repository->saveSessions(sessions);
    
    processEvents();
    
    ASSERT_GE(spy.count(), 1);
}

// ============================================================================
// JSON Serialization Tests
// ============================================================================

TEST_F(SessionRepositoryTest, PreservesSessionSourceContext) {
    Session session = createTestSession("context-test", "Context test");
    SourceContext ctx;
    ctx.source = "sources/github/owner/repo";
    GitHubRepoContext ghCtx;
    ghCtx.startingBranch = "main";
    ctx.githubRepoContext = ghCtx;
    session.sourceContext = ctx;
    
    m_repository->saveSession(session);
    
    auto retrieved = m_repository->getSession("context-test");
    ASSERT_TRUE(retrieved.has_value());
    ASSERT_TRUE(retrieved->sourceContext.has_value());
    EXPECT_EQ(retrieved->sourceContext->source, QString("sources/github/owner/repo"));
    ASSERT_TRUE(retrieved->sourceContext->githubRepoContext.has_value());
    EXPECT_EQ(retrieved->sourceContext->githubRepoContext->startingBranch.value(), QString("main"));
}

TEST_F(SessionRepositoryTest, PreservesSessionOutputs) {
    Session session = createTestSession("output-test", "Output test");
    session.state = SessionState::Completed;
    
    SessionOutput output;
    PullRequest pr;
    pr.url = "https://github.com/owner/repo/pull/123";
    pr.title = "Fix bug";
    pr.description = "This fixes the bug";
    output.pullRequest = pr;
    session.outputs = QList<SessionOutput>{output};
    
    m_repository->saveSession(session);
    
    auto retrieved = m_repository->getSession("output-test");
    ASSERT_TRUE(retrieved.has_value());
    ASSERT_TRUE(retrieved->outputs.has_value());
    ASSERT_EQ(retrieved->outputs->size(), 1);
    ASSERT_TRUE(retrieved->outputs->at(0).pullRequest.has_value());
    EXPECT_EQ(retrieved->outputs->at(0).pullRequest->url, QString("https://github.com/owner/repo/pull/123"));
}

// ============================================================================
// Client-Side Only Properties Tests
// ============================================================================

TEST_F(SessionRepositoryTest, PreservesLastActivityPollTime) {
    Session session = createTestSession("poll-time-test", "Poll time test");
    session.lastActivityPollTime = QDateTime::currentDateTimeUtc();
    
    m_repository->saveSession(session);
    
    auto retrieved = m_repository->getSession("poll-time-test");
    ASSERT_TRUE(retrieved.has_value());
    ASSERT_TRUE(retrieved->lastActivityPollTime.has_value());
}

// ============================================================================
// Database Migration Tests
// ============================================================================

TEST_F(SessionRepositoryTest, MigrationCreatesIndices) {
    QSqlDatabase sqlDb = m_db->database();
    QSqlQuery query(sqlDb);
    
    ASSERT_TRUE(query.exec("SELECT name FROM sqlite_master WHERE type='index'"));
    
    QStringList indices;
    while (query.next()) {
        indices << query.value(0).toString();
    }
    
    // Should have index on state for active session queries
    EXPECT_TRUE(indices.contains("idx_sessions_state") || 
                std::any_of(indices.begin(), indices.end(), 
                           [](const QString& idx) { return idx.contains("state"); }));
}

// ============================================================================
// Concurrent Access Tests
// ============================================================================

TEST_F(SessionRepositoryTest, ConcurrentReadsDontBlock) {
    // Save some sessions first
    for (int i = 0; i < 100; ++i) {
        m_repository->saveSession(createTestSession(
            QString("concurrent-%1").arg(i), 
            QString("Session %1").arg(i)
        ));
    }
    
    // Multiple reads should complete quickly
    QList<Session> result1 = m_repository->getAllSessions();
    QList<Session> result2 = m_repository->getAllSessions();
    
    EXPECT_EQ(result1.size(), 100);
    EXPECT_EQ(result2.size(), 100);
}

// ============================================================================
// Error Handling Tests
// ============================================================================

TEST_F(SessionRepositoryTest, HandlesMalformedJsonGracefully) {
    // Directly insert malformed JSON into database
    QSqlDatabase sqlDb = m_db->database();
    QSqlQuery query(sqlDb);
    
    query.prepare("INSERT INTO sessions (id, json, create_time, update_time, state, has_cached_diffs) "
                  "VALUES (?, ?, ?, ?, ?, ?)");
    query.addBindValue("malformed-id");
    query.addBindValue("{this is not valid json}");
    query.addBindValue("2024-01-01T00:00:00Z");
    query.addBindValue("2024-01-01T00:00:00Z");
    query.addBindValue("QUEUED");
    query.addBindValue(0);
    query.exec();
    
    // Should not crash, just return nullopt
    auto session = m_repository->getSession("malformed-id");
    EXPECT_FALSE(session.has_value());
}

} // namespace test
} // namespace jules

// Main function for Qt test application
int main(int argc, char** argv) {
    QCoreApplication app(argc, argv);
    ::testing::InitGoogleTest(&argc, argv);
    return RUN_ALL_TESTS();
}
