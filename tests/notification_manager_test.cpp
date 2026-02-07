#include <gtest/gtest.h>
#include <QApplication>
#include <QSignalSpy>

#include "ui/notification_manager.h"
#include "api/jules_api_client.h"

namespace jules {
namespace test {

class NotificationManagerTest : public ::testing::Test {
protected:
    Session makeTestSession(const QString& id, const QString& title) {
        Session s;
        s.id = id;
        s.name = "sessions/" + id;
        s.title = title;
        s.prompt = "test prompt";
        s.state = SessionState::Completed;
        return s;
    }
};

// ============================================================================
// Construction
// ============================================================================

TEST_F(NotificationManagerTest, CanConstruct) {
    EXPECT_NO_THROW({
        NotificationManager mgr;
    });
}

TEST_F(NotificationManagerTest, DefaultEnabled) {
    NotificationManager mgr;
    EXPECT_TRUE(mgr.isEnabled());
}

TEST_F(NotificationManagerTest, IsAvailableDoesNotCrash) {
    NotificationManager mgr;
    EXPECT_NO_THROW({
        mgr.isAvailable();
    });
}

// ============================================================================
// Enable / Disable
// ============================================================================

TEST_F(NotificationManagerTest, SetEnabledFalse) {
    NotificationManager mgr;
    mgr.setEnabled(false);
    EXPECT_FALSE(mgr.isEnabled());
}

TEST_F(NotificationManagerTest, SetEnabledTrue) {
    NotificationManager mgr;
    mgr.setEnabled(false);
    mgr.setEnabled(true);
    EXPECT_TRUE(mgr.isEnabled());
}

TEST_F(NotificationManagerTest, DisabledManagerNotifySessionCompletedDoesNotCrash) {
    NotificationManager mgr;
    mgr.setEnabled(false);
    Session s = makeTestSession("abc123", "Test Session");
    EXPECT_NO_THROW({
        mgr.notifySessionCompleted(s);
    });
}

// ============================================================================
// Notification methods (skip if no DBus)
// ============================================================================

TEST_F(NotificationManagerTest, NotifySessionCompletedDoesNotCrash) {
    NotificationManager mgr;
    if (!mgr.isAvailable()) {
        GTEST_SKIP() << "DBus notifications not available";
    }
    Session s = makeTestSession("sess-1", "Completed Session");
    s.state = SessionState::Completed;
    EXPECT_NO_THROW({
        mgr.notifySessionCompleted(s);
    });
}

TEST_F(NotificationManagerTest, NotifySessionFailedDoesNotCrash) {
    NotificationManager mgr;
    if (!mgr.isAvailable()) {
        GTEST_SKIP() << "DBus notifications not available";
    }
    Session s = makeTestSession("sess-2", "Failed Session");
    s.state = SessionState::Failed;
    EXPECT_NO_THROW({
        mgr.notifySessionFailed(s, "Something went wrong");
    });
}

TEST_F(NotificationManagerTest, NotifyAwaitingApprovalDoesNotCrash) {
    NotificationManager mgr;
    if (!mgr.isAvailable()) {
        GTEST_SKIP() << "DBus notifications not available";
    }
    Session s = makeTestSession("sess-3", "Awaiting Session");
    s.state = SessionState::AwaitingPlanApproval;
    EXPECT_NO_THROW({
        mgr.notifyAwaitingApproval(s);
    });
}

TEST_F(NotificationManagerTest, ShowNotificationDoesNotCrash) {
    NotificationManager mgr;
    if (!mgr.isAvailable()) {
        GTEST_SKIP() << "DBus notifications not available";
    }
    EXPECT_NO_THROW({
        mgr.showNotification("Test Title", "Test body", "sess-4");
    });
}

// ============================================================================
// Signal verification
// ============================================================================

TEST_F(NotificationManagerTest, NotificationClickedSignalIsValid) {
    NotificationManager mgr;
    QSignalSpy spy(&mgr, &NotificationManager::notificationClicked);
    EXPECT_TRUE(spy.isValid());
}

TEST_F(NotificationManagerTest, NotificationDismissedSignalIsValid) {
    NotificationManager mgr;
    QSignalSpy spy(&mgr, &NotificationManager::notificationDismissed);
    EXPECT_TRUE(spy.isValid());
}

// ============================================================================
// Disabled state behavior
// ============================================================================

TEST_F(NotificationManagerTest, DisabledSkipsAllNotificationTypes) {
    NotificationManager mgr;
    mgr.setEnabled(false);
    Session s = makeTestSession("sess-5", "Disabled Test");

    EXPECT_NO_THROW({
        mgr.notifySessionCompleted(s);
        mgr.notifySessionFailed(s, "error");
        mgr.notifyAwaitingApproval(s);
        mgr.notifyAwaitingFeedback(s);
        mgr.showNotification("Title", "Body", "sess-5");
    });
}

TEST_F(NotificationManagerTest, ReenablingAllowsNotifications) {
    NotificationManager mgr;
    mgr.setEnabled(false);
    EXPECT_FALSE(mgr.isEnabled());

    mgr.setEnabled(true);
    EXPECT_TRUE(mgr.isEnabled());

    if (!mgr.isAvailable()) {
        GTEST_SKIP() << "DBus notifications not available";
    }
    Session s = makeTestSession("sess-6", "Re-enabled Session");
    EXPECT_NO_THROW({
        mgr.notifySessionCompleted(s);
    });
}

} // namespace test
} // namespace jules

int main(int argc, char** argv) {
    QApplication app(argc, argv);
    ::testing::InitGoogleTest(&argc, argv);
    return RUN_ALL_TESTS();
}
