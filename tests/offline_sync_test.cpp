#include <gtest/gtest.h>
#include <QApplication>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QJsonObject>
#include <QDir>

#include "data/database.h"
#include "data/offline_sync_manager.h"
#include "api/jules_api_client.h"

namespace jules {
namespace test {

class OfflineSyncTest : public ::testing::Test {
protected:
    void SetUp() override {
        m_tempDir = std::make_unique<QTemporaryDir>();
        ASSERT_TRUE(m_tempDir->isValid());

        m_db = std::make_unique<Database>(m_tempDir->path());
        ASSERT_TRUE(m_db->initialize());

        m_syncManager = std::make_unique<OfflineSyncManager>(m_db.get());
    }

    void TearDown() override {
        m_syncManager.reset();
        m_db.reset();
        m_tempDir.reset();
    }

    QJsonObject makePayload(const QString& prompt) {
        QJsonObject obj;
        obj["sourceName"] = "test-repo";
        obj["sourceId"] = "sources/github/test-repo";
        obj["branchName"] = "main";
        obj["prompt"] = prompt;
        return obj;
    }

    std::unique_ptr<QTemporaryDir> m_tempDir;
    std::unique_ptr<Database> m_db;
    std::unique_ptr<OfflineSyncManager> m_syncManager;
};

TEST_F(OfflineSyncTest, InitialPendingCountIsZero) {
    EXPECT_EQ(m_syncManager->pendingCount(), 0);
}

TEST_F(OfflineSyncTest, QueuePendingSessionIncrementsCount) {
    m_syncManager->queuePendingSession(makePayload("Fix the bug"));
    EXPECT_EQ(m_syncManager->pendingCount(), 1);

    m_syncManager->queuePendingSession(makePayload("Add feature"));
    EXPECT_EQ(m_syncManager->pendingCount(), 2);
}

TEST_F(OfflineSyncTest, ClearPendingQueueResetsCount) {
    m_syncManager->queuePendingSession(makePayload("Fix the bug"));
    m_syncManager->queuePendingSession(makePayload("Add feature"));
    EXPECT_EQ(m_syncManager->pendingCount(), 2);

    m_syncManager->clearPendingQueue();
    EXPECT_EQ(m_syncManager->pendingCount(), 0);
}

TEST_F(OfflineSyncTest, QueueChangedSignalEmitted) {
    QSignalSpy spy(m_syncManager.get(), &OfflineSyncManager::queueChanged);
    ASSERT_TRUE(spy.isValid());

    m_syncManager->queuePendingSession(makePayload("Fix the bug"));
    EXPECT_EQ(spy.count(), 1);
    EXPECT_EQ(spy.takeFirst().at(0).toInt(), 1);
}

TEST_F(OfflineSyncTest, ClearQueueEmitsZeroCount) {
    m_syncManager->queuePendingSession(makePayload("Fix the bug"));

    QSignalSpy spy(m_syncManager.get(), &OfflineSyncManager::queueChanged);
    ASSERT_TRUE(spy.isValid());

    m_syncManager->clearPendingQueue();
    EXPECT_EQ(spy.count(), 1);
    EXPECT_EQ(spy.takeFirst().at(0).toInt(), 0);
}

TEST_F(OfflineSyncTest, SyncWithoutApiClientDoesNotCrash) {
    m_syncManager->queuePendingSession(makePayload("Fix the bug"));
    EXPECT_NO_THROW({
        m_syncManager->syncPendingQueue();
    });
}

TEST_F(OfflineSyncTest, MultipleQueuesAreIndependent) {
    m_syncManager->queuePendingSession(makePayload("task 1"));
    m_syncManager->queuePendingSession(makePayload("task 2"));
    m_syncManager->queuePendingSession(makePayload("task 3"));
    EXPECT_EQ(m_syncManager->pendingCount(), 3);

    m_syncManager->clearPendingQueue();
    EXPECT_EQ(m_syncManager->pendingCount(), 0);

    m_syncManager->queuePendingSession(makePayload("task 4"));
    EXPECT_EQ(m_syncManager->pendingCount(), 1);
}

TEST_F(OfflineSyncTest, QueuedSessionsSurviveRecreation) {
    m_syncManager->queuePendingSession(makePayload("persistent task"));
    EXPECT_EQ(m_syncManager->pendingCount(), 1);

    // Destroy sync manager, recreate from same db
    m_syncManager.reset();
    m_syncManager = std::make_unique<OfflineSyncManager>(m_db.get());
    EXPECT_EQ(m_syncManager->pendingCount(), 1);
}

TEST_F(OfflineSyncTest, SetApiClientDoesNotCrash) {
    JulesApiClient client;
    EXPECT_NO_THROW({
        m_syncManager->setApiClient(&client);
    });
}

TEST_F(OfflineSyncTest, QueueTenSessionsReportsCorrectCount) {
    for (int i = 0; i < 10; ++i) {
        m_syncManager->queuePendingSession(makePayload(QString("task %1").arg(i)));
    }
    EXPECT_EQ(m_syncManager->pendingCount(), 10);
}

TEST_F(OfflineSyncTest, ClearThenQueueAgainWorks) {
    m_syncManager->queuePendingSession(makePayload("first"));
    EXPECT_EQ(m_syncManager->pendingCount(), 1);

    m_syncManager->clearPendingQueue();
    EXPECT_EQ(m_syncManager->pendingCount(), 0);

    m_syncManager->queuePendingSession(makePayload("second"));
    EXPECT_EQ(m_syncManager->pendingCount(), 1);
}

TEST_F(OfflineSyncTest, QueueChangedEmitsOnEveryQueue) {
    QSignalSpy spy(m_syncManager.get(), &OfflineSyncManager::queueChanged);
    ASSERT_TRUE(spy.isValid());

    m_syncManager->queuePendingSession(makePayload("a"));
    m_syncManager->queuePendingSession(makePayload("b"));
    m_syncManager->queuePendingSession(makePayload("c"));
    EXPECT_EQ(spy.count(), 3);
}

TEST_F(OfflineSyncTest, QueueEmptyPayload) {
    EXPECT_NO_THROW({
        m_syncManager->queuePendingSession(QJsonObject{});
    });
    EXPECT_EQ(m_syncManager->pendingCount(), 1);
}

TEST_F(OfflineSyncTest, SyncEmptyQueueDoesNotCrash) {
    EXPECT_EQ(m_syncManager->pendingCount(), 0);
    EXPECT_NO_THROW({
        m_syncManager->syncPendingQueue();
    });
}

TEST_F(OfflineSyncTest, DestructorWithPendingQueueDoesNotCrash) {
    EXPECT_NO_THROW({
        auto tempDb = std::make_unique<Database>(m_tempDir->path() + "/destructor_test");
        // Database needs its directory to exist
        QDir().mkpath(m_tempDir->path() + "/destructor_test");
        tempDb->initialize();
        auto tempSync = std::make_unique<OfflineSyncManager>(tempDb.get());
        tempSync->queuePendingSession(makePayload("will be abandoned"));
        tempSync->queuePendingSession(makePayload("also abandoned"));
        // tempSync destroyed here with pending items
    });
}

TEST_F(OfflineSyncTest, SyncFailedSignalIsValid) {
    QSignalSpy spy(m_syncManager.get(), &OfflineSyncManager::syncFailed);
    ASSERT_TRUE(spy.isValid());
}

TEST_F(OfflineSyncTest, MultipleQueueClearCycles) {
    for (int cycle = 0; cycle < 5; ++cycle) {
        m_syncManager->queuePendingSession(makePayload(QString("cycle %1").arg(cycle)));
        EXPECT_EQ(m_syncManager->pendingCount(), 1) << "Failed at cycle " << cycle;
        m_syncManager->clearPendingQueue();
        EXPECT_EQ(m_syncManager->pendingCount(), 0) << "Failed clearing at cycle " << cycle;
    }
}

} // namespace test
} // namespace jules

int main(int argc, char** argv) {
    QApplication app(argc, argv);
    ::testing::InitGoogleTest(&argc, argv);
    return RUN_ALL_TESTS();
}
