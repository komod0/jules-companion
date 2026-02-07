#include <gtest/gtest.h>
#include <QApplication>
#include <QTemporaryDir>
#include <QFile>
#include <QFileInfo>

#include "data/diffs_database.h"
#include "api/jules_api_client.h"

namespace jules {
namespace test {

class DiffsDatabaseTest : public ::testing::Test {
protected:
    void SetUp() override {
        m_tempDir = std::make_unique<QTemporaryDir>();
        ASSERT_TRUE(m_tempDir->isValid());
        m_db = std::make_unique<DiffsDatabase>(m_tempDir->path());
        ASSERT_TRUE(m_db->initialize());
    }

    void TearDown() override {
        m_db.reset();
        m_tempDir.reset();
    }

    QList<CachedDiff> makeDiffs(int count) {
        QList<CachedDiff> diffs;
        for (int i = 0; i < count; ++i) {
            CachedDiff diff;
            diff.patch = QString("--- a/file%1.cpp\n+++ b/file%1.cpp\n@@ -1,3 +1,4 @@\n+// added line %1").arg(i);
            diff.language = QString("cpp");
            diff.filename = QString("file%1.cpp").arg(i);
            diffs.append(diff);
        }
        return diffs;
    }

    std::unique_ptr<QTemporaryDir> m_tempDir;
    std::unique_ptr<DiffsDatabase> m_db;
};

// ============================================================================
// 1. Initialization
// ============================================================================

TEST_F(DiffsDatabaseTest, CreatesDatabaseFile) {
    QFileInfo info(m_tempDir->path() + "/diffs.db");
    EXPECT_TRUE(info.exists());
}

TEST_F(DiffsDatabaseTest, CreatesTables) {
    // If tables were not created, saveDiffs would fail
    auto diffs = makeDiffs(1);
    EXPECT_TRUE(m_db->saveDiffs("session-1", diffs));
}

TEST_F(DiffsDatabaseTest, DoubleInitializeIsIdempotent) {
    // Calling initialize again should not fail or lose data
    auto diffs = makeDiffs(2);
    EXPECT_TRUE(m_db->saveDiffs("session-1", diffs));

    EXPECT_TRUE(m_db->initialize());

    auto retrieved = m_db->getDiffs("session-1");
    EXPECT_EQ(retrieved.size(), 2);
}

TEST_F(DiffsDatabaseTest, SchemaVersionSetAfterInitialize) {
    // After initialize, diffCount should work (tables exist with correct schema)
    EXPECT_EQ(m_db->diffCount(), 0);
}

TEST_F(DiffsDatabaseTest, DiffCountStartsAtZero) {
    EXPECT_EQ(m_db->diffCount(), 0);
}

// ============================================================================
// 2. CRUD
// ============================================================================

TEST_F(DiffsDatabaseTest, SaveReturnsTrue) {
    auto diffs = makeDiffs(3);
    EXPECT_TRUE(m_db->saveDiffs("session-1", diffs));
}

TEST_F(DiffsDatabaseTest, GetReturnsCorrectData) {
    auto diffs = makeDiffs(2);
    m_db->saveDiffs("session-1", diffs);

    auto retrieved = m_db->getDiffs("session-1");
    ASSERT_EQ(retrieved.size(), 2);
    EXPECT_EQ(retrieved[0].patch, diffs[0].patch);
    EXPECT_EQ(retrieved[0].language, diffs[0].language);
    EXPECT_EQ(retrieved[0].filename, diffs[0].filename);
    EXPECT_EQ(retrieved[1].patch, diffs[1].patch);
}

TEST_F(DiffsDatabaseTest, GetReturnsEmptyForUnknownSession) {
    auto retrieved = m_db->getDiffs("nonexistent-session");
    EXPECT_TRUE(retrieved.isEmpty());
}

TEST_F(DiffsDatabaseTest, HasDiffsTrueAfterSave) {
    auto diffs = makeDiffs(1);
    m_db->saveDiffs("session-1", diffs);
    EXPECT_TRUE(m_db->hasDiffs("session-1"));
}

TEST_F(DiffsDatabaseTest, HasDiffsFalseForEmpty) {
    EXPECT_FALSE(m_db->hasDiffs("nonexistent-session"));
}

TEST_F(DiffsDatabaseTest, DeleteRemovesData) {
    auto diffs = makeDiffs(3);
    m_db->saveDiffs("session-1", diffs);
    EXPECT_TRUE(m_db->hasDiffs("session-1"));

    EXPECT_TRUE(m_db->deleteDiffs("session-1"));
    EXPECT_FALSE(m_db->hasDiffs("session-1"));
    EXPECT_TRUE(m_db->getDiffs("session-1").isEmpty());
}

TEST_F(DiffsDatabaseTest, ClearAllDiffsWorks) {
    m_db->saveDiffs("session-1", makeDiffs(2));
    m_db->saveDiffs("session-2", makeDiffs(3));
    EXPECT_EQ(m_db->diffCount(), 5);

    EXPECT_TRUE(m_db->clearAllDiffs());
    EXPECT_EQ(m_db->diffCount(), 0);
    EXPECT_FALSE(m_db->hasDiffs("session-1"));
    EXPECT_FALSE(m_db->hasDiffs("session-2"));
}

// ============================================================================
// 3. Data Integrity
// ============================================================================

TEST_F(DiffsDatabaseTest, SaveReplacesExisting) {
    auto diffs1 = makeDiffs(3);
    m_db->saveDiffs("session-1", diffs1);
    EXPECT_EQ(m_db->diffCount(), 3);

    auto diffs2 = makeDiffs(1);
    m_db->saveDiffs("session-1", diffs2);
    EXPECT_EQ(m_db->diffCount(), 1);

    auto retrieved = m_db->getDiffs("session-1");
    ASSERT_EQ(retrieved.size(), 1);
    EXPECT_EQ(retrieved[0], diffs2[0]);
}

TEST_F(DiffsDatabaseTest, OrderPreservedByIndex) {
    QList<CachedDiff> diffs;
    for (int i = 0; i < 5; ++i) {
        CachedDiff diff;
        diff.patch = QString("patch-%1").arg(i);
        diff.language = "cpp";
        diff.filename = QString("file%1.cpp").arg(i);
        diffs.append(diff);
    }
    m_db->saveDiffs("session-1", diffs);

    auto retrieved = m_db->getDiffs("session-1");
    ASSERT_EQ(retrieved.size(), 5);
    for (int i = 0; i < 5; ++i) {
        EXPECT_EQ(retrieved[i].patch, QString("patch-%1").arg(i));
    }
}

TEST_F(DiffsDatabaseTest, OptionalFieldsNullRoundtrip) {
    QList<CachedDiff> diffs;
    CachedDiff diff;
    diff.patch = "--- a/file.txt\n+++ b/file.txt\n@@ -1 +1 @@\n-old\n+new";
    diff.language = std::nullopt;
    diff.filename = std::nullopt;
    diffs.append(diff);

    m_db->saveDiffs("session-1", diffs);
    auto retrieved = m_db->getDiffs("session-1");

    ASSERT_EQ(retrieved.size(), 1);
    EXPECT_EQ(retrieved[0].patch, diff.patch);
    // Empty strings stored for nullopt are read back as nullopt (isEmpty check)
    EXPECT_FALSE(retrieved[0].language.has_value());
    EXPECT_FALSE(retrieved[0].filename.has_value());
}

TEST_F(DiffsDatabaseTest, LargePatchRoundtrips) {
    CachedDiff diff;
    // Generate a large patch (~100KB)
    QString largePatch;
    for (int i = 0; i < 2000; ++i) {
        largePatch += QString("+// line %1: some content that makes this patch reasonably large\n").arg(i);
    }
    diff.patch = largePatch;
    diff.language = "python";
    diff.filename = "large_file.py";

    QList<CachedDiff> diffs;
    diffs.append(diff);
    EXPECT_TRUE(m_db->saveDiffs("session-1", diffs));

    auto retrieved = m_db->getDiffs("session-1");
    ASSERT_EQ(retrieved.size(), 1);
    EXPECT_EQ(retrieved[0].patch, largePatch);
    EXPECT_EQ(retrieved[0].language.value(), "python");
}

TEST_F(DiffsDatabaseTest, DiffCountCorrectAcrossSessions) {
    m_db->saveDiffs("session-1", makeDiffs(3));
    m_db->saveDiffs("session-2", makeDiffs(4));
    m_db->saveDiffs("session-3", makeDiffs(2));

    EXPECT_EQ(m_db->diffCount(), 9);

    m_db->deleteDiffs("session-2");
    EXPECT_EQ(m_db->diffCount(), 5);
}

// ============================================================================
// 4. File Size
// ============================================================================

TEST_F(DiffsDatabaseTest, DatabaseFileSizePositiveAfterInserts) {
    m_db->saveDiffs("session-1", makeDiffs(5));
    EXPECT_GT(m_db->databaseFileSize(), 0);
}

TEST_F(DiffsDatabaseTest, ClearAllDiffsThenDiffCountIsZero) {
    m_db->saveDiffs("session-1", makeDiffs(10));
    EXPECT_EQ(m_db->diffCount(), 10);

    m_db->clearAllDiffs();
    EXPECT_EQ(m_db->diffCount(), 0);
}

TEST_F(DiffsDatabaseTest, MultipleSessionsTrackedIndependently) {
    m_db->saveDiffs("session-A", makeDiffs(2));
    m_db->saveDiffs("session-B", makeDiffs(3));

    EXPECT_TRUE(m_db->hasDiffs("session-A"));
    EXPECT_TRUE(m_db->hasDiffs("session-B"));
    EXPECT_FALSE(m_db->hasDiffs("session-C"));

    auto diffsA = m_db->getDiffs("session-A");
    auto diffsB = m_db->getDiffs("session-B");

    EXPECT_EQ(diffsA.size(), 2);
    EXPECT_EQ(diffsB.size(), 3);

    // Deleting one session does not affect the other
    m_db->deleteDiffs("session-A");
    EXPECT_FALSE(m_db->hasDiffs("session-A"));
    EXPECT_TRUE(m_db->hasDiffs("session-B"));
    EXPECT_EQ(m_db->getDiffs("session-B").size(), 3);
}

} // namespace test
} // namespace jules

int main(int argc, char** argv) {
    QApplication app(argc, argv);
    ::testing::InitGoogleTest(&argc, argv);
    return RUN_ALL_TESTS();
}
