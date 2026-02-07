/**
 * @file session_detail_widget_test.cpp
 * @brief Unit tests for SessionDetailWidget
 *
 * Tests the refactored session detail widget's public interface:
 * - activityCount() returns correct count
 * - clear() resets state completely
 * - isEmpty() behavior
 * - setSession() with different session states
 * - Action bar shows/hides based on state
 * - populateActivities with various activity types
 */

#include <gtest/gtest.h>
#include <QApplication>
#include <QSignalSpy>
#include <QPushButton>
#include <QSplitter>

#include "ui/session_detail_widget.h"
#include "api/jules_api_client.h"

namespace jules {
namespace test {

class SessionDetailWidgetTest : public ::testing::Test {
protected:
    Session createSession(const QString& id,
                          const QString& prompt,
                          SessionState state = SessionState::Queued) {
        Session session;
        session.id = id;
        session.name = "sessions/" + id;
        session.prompt = prompt;
        session.state = state;
        session.createTime = "2026-01-15T10:00:00Z";
        session.updateTime = session.createTime;
        return session;
    }

    Activity createUserActivity(const QString& message) {
        Activity act;
        act.id = "user-act-" + QString::number(++m_activityCounter);
        act.name = "activities/" + act.id;
        act.originator = "USER";
        UserMessaged msg;
        msg.userMessage = message;
        act.userMessaged = msg;
        return act;
    }

    Activity createAgentActivity(const QString& message) {
        Activity act;
        act.id = "agent-act-" + QString::number(++m_activityCounter);
        act.name = "activities/" + act.id;
        act.originator = "AGENT";
        AgentMessaged msg;
        msg.agentMessage = message;
        act.agentMessaged = msg;
        return act;
    }

    Activity createProgressActivity(const QString& title, const QString& desc = QString()) {
        Activity act;
        act.id = "progress-act-" + QString::number(++m_activityCounter);
        act.name = "activities/" + act.id;
        act.originator = "AGENT";
        ProgressUpdated progress;
        progress.title = title;
        if (!desc.isEmpty()) {
            progress.description = desc;
        }
        act.progressUpdated = progress;
        return act;
    }

    int m_activityCounter = 0;
};

// ============================================================================
// isEmpty / clear
// ============================================================================

TEST_F(SessionDetailWidgetTest, IsEmptyWhenCreated) {
    SessionDetailWidget widget;
    EXPECT_TRUE(widget.isEmpty());
}

TEST_F(SessionDetailWidgetTest, IsNotEmptyAfterSetSession) {
    SessionDetailWidget widget;
    widget.setSession(createSession("s1", "Fix bug"));
    EXPECT_FALSE(widget.isEmpty());
}

TEST_F(SessionDetailWidgetTest, ClearResetsToEmpty) {
    SessionDetailWidget widget;
    widget.setSession(createSession("s1", "Fix bug"));
    EXPECT_FALSE(widget.isEmpty());

    widget.clear();
    EXPECT_TRUE(widget.isEmpty());
}

TEST_F(SessionDetailWidgetTest, ClearResetsDisplayedText) {
    SessionDetailWidget widget;
    widget.setSession(createSession("s1", "Fix bug"));
    EXPECT_FALSE(widget.displayedText().isEmpty());

    widget.clear();
    EXPECT_TRUE(widget.displayedText().isEmpty());
}

TEST_F(SessionDetailWidgetTest, ClearResetsActivityCount) {
    SessionDetailWidget widget;

    Session session = createSession("s1", "Test");
    session.activities = QList<Activity>{
        createAgentActivity("Hello"),
        createAgentActivity("World")
    };
    widget.setSession(session);
    EXPECT_GT(widget.activityCount(), 0);

    widget.clear();
    EXPECT_EQ(widget.activityCount(), 0);
}

// ============================================================================
// activityCount
// ============================================================================

TEST_F(SessionDetailWidgetTest, ActivityCountZeroWithNoActivities) {
    SessionDetailWidget widget;
    widget.resize(800, 600);

    Session session = createSession("s1", "");  // Empty prompt => no prompt bubble
    session.activities = QList<Activity>{};
    widget.setSession(session);

    EXPECT_EQ(widget.activityCount(), 0);
}

TEST_F(SessionDetailWidgetTest, ActivityCountIncludesPromptBubble) {
    SessionDetailWidget widget;
    widget.resize(800, 600);

    Session session = createSession("s1", "Fix the bug");
    session.activities = QList<Activity>{};
    widget.setSession(session);

    // Prompt bubble counts as 1
    EXPECT_EQ(widget.activityCount(), 1);
}

TEST_F(SessionDetailWidgetTest, ActivityCountWithMultipleActivities) {
    SessionDetailWidget widget;
    widget.resize(800, 600);

    Session session = createSession("s1", "Fix bug");
    session.activities = QList<Activity>{
        createUserActivity("Please fix"),
        createAgentActivity("On it"),
        createProgressActivity("Analyzing"),
        createAgentActivity("Done!")
    };
    widget.setSession(session);

    // 1 prompt + 2 user/agent + 1 agent = 4 (progress updates are hidden)
    EXPECT_EQ(widget.activityCount(), 4);
}

TEST_F(SessionDetailWidgetTest, ActivityCountSkipsEmptyAgentMessages) {
    SessionDetailWidget widget;
    widget.resize(800, 600);

    Session session = createSession("s1", "Test");

    Activity emptyAct;
    emptyAct.id = "empty";
    emptyAct.name = "activities/empty";
    emptyAct.originator = "AGENT";
    AgentMessaged emptyMsg;
    emptyMsg.agentMessage = "";
    emptyAct.agentMessaged = emptyMsg;

    session.activities = QList<Activity>{
        createAgentActivity("Real message"),
        emptyAct  // should be skipped (empty text)
    };
    widget.setSession(session);

    // 1 prompt + 1 real agent message = 2 (empty one skipped)
    EXPECT_EQ(widget.activityCount(), 2);
}

// ============================================================================
// setSession with different states
// ============================================================================

TEST_F(SessionDetailWidgetTest, SetSessionCompletedState) {
    SessionDetailWidget widget;
    widget.setSession(createSession("s1", "Done", SessionState::Completed));

    EXPECT_EQ(widget.stateIndicatorText(), QString("Completed"));
    EXPECT_FALSE(widget.isEmpty());
}

TEST_F(SessionDetailWidgetTest, SetSessionFailedState) {
    SessionDetailWidget widget;
    widget.setSession(createSession("s1", "Oops", SessionState::Failed));

    EXPECT_EQ(widget.stateIndicatorText(), QString("Failed"));
}

TEST_F(SessionDetailWidgetTest, SetSessionInProgressState) {
    SessionDetailWidget widget;
    widget.setSession(createSession("s1", "Working", SessionState::InProgress));

    EXPECT_EQ(widget.stateIndicatorText(), QString("In Progress"));
}

TEST_F(SessionDetailWidgetTest, SetSessionPlanningState) {
    SessionDetailWidget widget;
    widget.setSession(createSession("s1", "Planning", SessionState::Planning));

    EXPECT_EQ(widget.stateIndicatorText(), QString("Planning..."));
}

TEST_F(SessionDetailWidgetTest, SetSessionQueuedState) {
    SessionDetailWidget widget;
    widget.setSession(createSession("s1", "Waiting", SessionState::Queued));

    EXPECT_EQ(widget.stateIndicatorText(), QString("Queued"));
}

TEST_F(SessionDetailWidgetTest, SetSessionPausedState) {
    SessionDetailWidget widget;
    widget.setSession(createSession("s1", "Paused", SessionState::Paused));

    EXPECT_EQ(widget.stateIndicatorText(), QString("Paused"));
}

TEST_F(SessionDetailWidgetTest, StateChangesWhenSessionIsReplaced) {
    SessionDetailWidget widget;

    widget.setSession(createSession("s1", "First", SessionState::Queued));
    EXPECT_EQ(widget.stateIndicatorText(), QString("Queued"));

    widget.setSession(createSession("s2", "Second", SessionState::Completed));
    EXPECT_EQ(widget.stateIndicatorText(), QString("Completed"));
}

// ============================================================================
// Action bar visibility based on state
// ============================================================================

TEST_F(SessionDetailWidgetTest, ActionBarVisibleForPlanApproval) {
    SessionDetailWidget widget;
    widget.setSession(createSession("s1", "Plan", SessionState::AwaitingPlanApproval));

    // Find action bar buttons
    auto* approveBtn = widget.findChild<QPushButton*>(QString(), Qt::FindChildrenRecursively);
    QList<QPushButton*> buttons = widget.findChildren<QPushButton*>();

    bool hasApprove = false;
    bool hasFeedback = false;
    for (auto* btn : buttons) {
        if (btn->text() == "Approve Plan") hasApprove = true;
        if (btn->text() == "Request Changes") hasFeedback = true;
    }

    EXPECT_TRUE(hasApprove) << "Approve Plan button should be visible";
    EXPECT_TRUE(hasFeedback) << "Request Changes button should be visible";
}

TEST_F(SessionDetailWidgetTest, ActionBarVisibleForUserFeedback) {
    SessionDetailWidget widget;
    widget.setSession(createSession("s1", "Feedback", SessionState::AwaitingUserFeedback));

    QList<QPushButton*> buttons = widget.findChildren<QPushButton*>();

    bool hasFeedback = false;
    for (auto* btn : buttons) {
        if (btn->text() == "Provide Feedback") hasFeedback = true;
    }

    EXPECT_TRUE(hasFeedback) << "Provide Feedback button should be visible";
}

TEST_F(SessionDetailWidgetTest, ActionBarHiddenForCompletedState) {
    SessionDetailWidget widget;
    widget.setSession(createSession("s1", "Done", SessionState::Completed));

    // Find the action bar widget (parent of approve/feedback buttons)
    QList<QPushButton*> buttons = widget.findChildren<QPushButton*>();
    bool hasActionButton = false;
    for (auto* btn : buttons) {
        if (btn->text() == "Approve Plan" && btn->isVisible()) hasActionButton = true;
        if (btn->text() == "Provide Feedback" && btn->isVisible()) hasActionButton = true;
    }

    EXPECT_FALSE(hasActionButton) << "No action buttons should be visible for completed state";
}

// ============================================================================
// Pull request link
// ============================================================================

TEST_F(SessionDetailWidgetTest, NoPullRequestLinkByDefault) {
    SessionDetailWidget widget;
    widget.setSession(createSession("s1", "No PR"));

    EXPECT_FALSE(widget.hasPullRequestLink());
    EXPECT_TRUE(widget.pullRequestUrl().isEmpty());
}

TEST_F(SessionDetailWidgetTest, PullRequestLinkWhenPresent) {
    Session session = createSession("s1", "With PR", SessionState::Completed);
    SessionOutput output;
    PullRequest pr;
    pr.url = "https://github.com/owner/repo/pull/42";
    pr.title = "Fix bug";
    output.pullRequest = pr;
    session.outputs = QList<SessionOutput>{output};

    SessionDetailWidget widget;
    widget.setSession(session);

    EXPECT_TRUE(widget.hasPullRequestLink());
    EXPECT_EQ(widget.pullRequestUrl(), QString("https://github.com/owner/repo/pull/42"));
}

// ============================================================================
// Signals
// ============================================================================

TEST_F(SessionDetailWidgetTest, PlanApprovedSignalEmitted) {
    SessionDetailWidget widget;
    widget.setSession(createSession("s1", "Plan", SessionState::AwaitingPlanApproval));

    QSignalSpy spy(&widget, &SessionDetailWidget::planApproved);

    // Find and click the approve button
    QList<QPushButton*> buttons = widget.findChildren<QPushButton*>();
    for (auto* btn : buttons) {
        if (btn->text() == "Approve Plan") {
            btn->click();
            break;
        }
    }

    ASSERT_EQ(spy.count(), 1);
    EXPECT_EQ(spy.at(0).at(0).toString(), QString("s1"));
}

TEST_F(SessionDetailWidgetTest, OpenUrlSignalEmitted) {
    Session session = createSession("s1", "URL test");
    session.url = "https://jules.google.com/session/s1";

    SessionDetailWidget widget;
    widget.setSession(session);

    QSignalSpy spy(&widget, &SessionDetailWidget::openUrlRequested);

    widget.requestOpenInBrowser();

    ASSERT_EQ(spy.count(), 1);
    EXPECT_EQ(spy.at(0).at(0).toString(), QString("https://jules.google.com/session/s1"));
}

// ============================================================================
// Displayed text and state indicator
// ============================================================================

TEST_F(SessionDetailWidgetTest, DisplayedTextContainsSessionTitle) {
    Session session = createSession("s1", "Fix the authentication bug");
    session.title = "Auth Bug Fix";

    SessionDetailWidget widget;
    widget.setSession(session);

    EXPECT_TRUE(widget.displayedText().contains("Auth Bug Fix"));
}

TEST_F(SessionDetailWidgetTest, DisplayedTextContainsPrompt) {
    Session session = createSession("s1", "Fix the authentication bug");

    SessionDetailWidget widget;
    widget.setSession(session);

    EXPECT_TRUE(widget.displayedText().contains("Fix the authentication bug"));
}

TEST_F(SessionDetailWidgetTest, StateIndicatorTextIsEmptyWhenNoSession) {
    SessionDetailWidget widget;
    EXPECT_TRUE(widget.stateIndicatorText().isEmpty());
}

// ============================================================================
// Plan generated activities
// ============================================================================

TEST_F(SessionDetailWidgetTest, PlanGeneratedActivityCreatesWidget) {
    SessionDetailWidget widget;
    widget.resize(800, 600);

    Session session = createSession("s1", "Plan test");

    Activity planAct;
    planAct.id = "plan-act";
    planAct.name = "activities/plan-act";
    planAct.originator = "AGENT";
    PlanGenerated planGen;
    planGen.plan.id = "plan-1";
    PlanStep step1;
    step1.id = "step-1";
    step1.title = "Analyze code";
    step1.description = "Look at the codebase";
    PlanStep step2;
    step2.id = "step-2";
    step2.title = "Make changes";
    planGen.plan.steps = {step1, step2};
    planAct.planGenerated = planGen;

    session.activities = QList<Activity>{planAct};
    widget.setSession(session);

    // 1 prompt + 1 plan widget = 2
    EXPECT_EQ(widget.activityCount(), 2);
}

// ============================================================================
// Session completed / failed activities
// ============================================================================

TEST_F(SessionDetailWidgetTest, SessionCompletedActivityIsDisplayed) {
    SessionDetailWidget widget;
    widget.resize(800, 600);

    Session session = createSession("s1", "Done");

    Activity completedAct;
    completedAct.id = "completed-act";
    completedAct.name = "activities/completed-act";
    completedAct.originator = "AGENT";
    completedAct.sessionCompleted = SessionCompleted{};

    session.activities = QList<Activity>{completedAct};
    widget.setSession(session);

    // 1 prompt + 1 completed = 2
    EXPECT_EQ(widget.activityCount(), 2);
}

TEST_F(SessionDetailWidgetTest, SessionFailedActivityIsDisplayed) {
    SessionDetailWidget widget;
    widget.resize(800, 600);

    Session session = createSession("s1", "Failed");

    Activity failedAct;
    failedAct.id = "failed-act";
    failedAct.name = "activities/failed-act";
    failedAct.originator = "AGENT";
    SessionFailed failed;
    failed.reason = "Out of memory";
    failedAct.sessionFailed = failed;

    session.activities = QList<Activity>{failedAct};
    widget.setSession(session);

    // 1 prompt + 1 failed = 2
    EXPECT_EQ(widget.activityCount(), 2);
}

// ============================================================================
// Diff panel collapse toggle
// ============================================================================

TEST_F(SessionDetailWidgetTest, DiffToggleButtonExists) {
    SessionDetailWidget widget;
    widget.setSession(createSession("s1", "Test"));

    QList<QPushButton*> buttons = widget.findChildren<QPushButton*>();
    bool hasToggle = false;
    for (auto* btn : buttons) {
        if (btn->toolTip() == "Hide Diff Panel" || btn->toolTip() == "Toggle Diff Panel") {
            hasToggle = true;
            break;
        }
    }
    EXPECT_TRUE(hasToggle) << "Diff toggle button should exist in session detail header";
}

// ============================================================================
// Switching sessions replaces content
// ============================================================================

TEST_F(SessionDetailWidgetTest, SwitchingSessionsReplacesActivities) {
    SessionDetailWidget widget;
    widget.resize(800, 600);

    // First session with 3 activities
    Session s1 = createSession("s1", "First");
    s1.activities = QList<Activity>{
        createAgentActivity("A"),
        createAgentActivity("B"),
        createAgentActivity("C")
    };
    widget.setSession(s1);
    EXPECT_EQ(widget.activityCount(), 4);  // 1 prompt + 3

    // Second session with 1 activity
    Session s2 = createSession("s2", "Second");
    s2.activities = QList<Activity>{
        createAgentActivity("Only one")
    };
    widget.setSession(s2);
    EXPECT_EQ(widget.activityCount(), 2);  // 1 prompt + 1
}

} // namespace test
} // namespace jules

int main(int argc, char** argv) {
    QApplication app(argc, argv);
    QCoreApplication::setOrganizationName("JulesLinuxTest");
    QCoreApplication::setApplicationName("SessionDetailWidgetTest");
    ::testing::InitGoogleTest(&argc, argv);
    return RUN_ALL_TESTS();
}
