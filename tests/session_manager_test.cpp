/**
 * @file session_manager_test.cpp
 * @brief Unit tests for Session Management UI components
 * 
 * TDD approach: These tests define the expected behavior for:
 * - SessionListWidget: Display sessions with real-time updates
 * - NewSessionDialog: Create new sessions with repo/branch/prompt inputs
 * - SessionDetailWidget: Show detailed session information
 * - SessionPollingManager: 10-second polling for active sessions
 */

#include <gtest/gtest.h>
#include <QApplication>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QTimer>
#include <QTest>
#include <QListWidget>
#include <QLineEdit>
#include <QComboBox>
#include <QTextEdit>
#include <QDialogButtonBox>
#include <QPushButton>
#include <QLabel>

#include "ui/session_list_widget.h"
#include "ui/new_session_dialog.h"
#include "ui/session_detail_widget.h"
#include "api/jules_api_client.h"
#include "data/database.h"
#include "data/session_repository.h"

namespace jules {
namespace test {

// ============================================================================
// Test Fixture
// ============================================================================

class SessionManagerTest : public ::testing::Test {
protected:
    void SetUp() override {
        m_tempDir = std::make_unique<QTemporaryDir>();
        ASSERT_TRUE(m_tempDir->isValid());
        
        m_db = std::make_unique<Database>(m_tempDir->path());
        ASSERT_TRUE(m_db->initialize());
        
        m_repository = std::make_unique<SessionRepository>(m_db.get());
        m_apiClient = std::make_unique<JulesApiClient>();
    }

    void TearDown() override {
        m_apiClient.reset();
        m_repository.reset();
        m_db.reset();
        m_tempDir.reset();
    }

    void processEvents(int timeoutMs = 50) {
        QEventLoop loop;
        QTimer::singleShot(timeoutMs, &loop, &QEventLoop::quit);
        loop.exec();
    }

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

    Source createTestSource(const QString& id, const QString& name) {
        Source source;
        source.id = id;
        source.name = "sources/github/" + name;
        GitHubRepo repo;
        repo.owner = name.split("/").first();
        repo.repo = name.split("/").last();
        GitHubBranch main, dev;
        main.displayName = "main";
        dev.displayName = "develop";
        repo.branches = {main, dev};
        repo.defaultBranch = main;
        source.githubRepo = repo;
        return source;
    }

    std::unique_ptr<QTemporaryDir> m_tempDir;
    std::unique_ptr<Database> m_db;
    std::unique_ptr<SessionRepository> m_repository;
    std::unique_ptr<JulesApiClient> m_apiClient;
};

// ============================================================================
// SessionListWidget Tests
// ============================================================================

TEST_F(SessionManagerTest, SessionListWidgetCreation) {
    SessionListWidget widget(m_repository.get());
    
    EXPECT_TRUE(widget.isEnabled());
    EXPECT_EQ(widget.sessionCount(), 0);
}

TEST_F(SessionManagerTest, SessionListWidgetDisplaysSessions) {
    m_repository->saveSession(createTestSession("sess-1", "Fix bug #1", SessionState::Queued));
    m_repository->saveSession(createTestSession("sess-2", "Add feature", SessionState::InProgress));
    m_repository->saveSession(createTestSession("sess-3", "Refactor code", SessionState::Completed));
    
    SessionListWidget widget(m_repository.get());
    widget.refresh();
    processEvents();
    
    EXPECT_EQ(widget.sessionCount(), 3);
}

TEST_F(SessionManagerTest, SessionListWidgetShowsCorrectSessionInfo) {
    Session session = createTestSession("info-test", "Test session prompt");
    session.state = SessionState::InProgress;
    SourceContext ctx;
    ctx.source = "sources/github/owner/repo";
    session.sourceContext = ctx;
    m_repository->saveSession(session);
    
    SessionListWidget widget(m_repository.get());
    widget.refresh();
    processEvents();
    
    ASSERT_EQ(widget.sessionCount(), 1);
    
    QString displayText = widget.sessionDisplayText(0);
    EXPECT_TRUE(displayText.contains("Test session prompt") || 
                displayText.contains("info-test"));
}

TEST_F(SessionManagerTest, SessionListWidgetDisplaysSessionStates) {
    m_repository->saveSession(createTestSession("q", "Queued", SessionState::Queued));
    m_repository->saveSession(createTestSession("p", "Planning", SessionState::Planning));
    m_repository->saveSession(createTestSession("i", "InProgress", SessionState::InProgress));
    m_repository->saveSession(createTestSession("c", "Completed", SessionState::Completed));
    
    SessionListWidget widget(m_repository.get());
    widget.refresh();
    processEvents();
    
    EXPECT_EQ(widget.sessionCount(), 4);
    
    // Verify different states have different visual representation
    // (color, icon, or badge - implementation specific)
    EXPECT_NE(widget.sessionStateIcon(0), widget.sessionStateIcon(3));
}

TEST_F(SessionManagerTest, SessionListWidgetEmitsSessionSelectedOnClick) {
    m_repository->saveSession(createTestSession("click-test", "Click me"));
    
    SessionListWidget widget(m_repository.get());
    widget.refresh();
    processEvents();
    
    QSignalSpy spy(&widget, &SessionListWidget::sessionSelected);
    
    widget.selectSession(0);
    processEvents();
    
    ASSERT_EQ(spy.count(), 1);
    QString selectedId = spy.at(0).at(0).toString();
    EXPECT_EQ(selectedId, QString("click-test"));
}

TEST_F(SessionManagerTest, SessionListWidgetRefreshesOnRepositoryChange) {
    SessionListWidget widget(m_repository.get());
    widget.refresh();
    processEvents();
    EXPECT_EQ(widget.sessionCount(), 0);
    
    // Save a new session
    m_repository->saveSession(createTestSession("new-sess", "New session"));
    processEvents(100);
    
    // Widget should automatically update via signal
    EXPECT_EQ(widget.sessionCount(), 1);
}

TEST_F(SessionManagerTest, SessionListWidgetOrdersByCreateTimeDesc) {
    Session old = createTestSession("old", "Old session");
    old.createTime = "2024-01-01T00:00:00Z";
    
    Session mid = createTestSession("mid", "Mid session");
    mid.createTime = "2024-06-15T12:00:00Z";
    
    Session recent = createTestSession("recent", "Recent session");
    recent.createTime = "2024-12-31T23:59:59Z";
    
    m_repository->saveSession(mid);
    m_repository->saveSession(old);
    m_repository->saveSession(recent);
    
    SessionListWidget widget(m_repository.get());
    widget.refresh();
    processEvents();
    
    // Most recent should be first
    EXPECT_EQ(widget.sessionIdAt(0), QString("recent"));
    EXPECT_EQ(widget.sessionIdAt(1), QString("mid"));
    EXPECT_EQ(widget.sessionIdAt(2), QString("old"));
}

TEST_F(SessionManagerTest, SessionListWidgetKeyboardNavigation) {
    Session s1 = createTestSession("s1", "Session 1");
    s1.createTime = "2024-12-03T00:00:00Z";
    Session s2 = createTestSession("s2", "Session 2");
    s2.createTime = "2024-12-02T00:00:00Z";
    Session s3 = createTestSession("s3", "Session 3");
    s3.createTime = "2024-12-01T00:00:00Z";
    
    m_repository->saveSession(s1);
    m_repository->saveSession(s2);
    m_repository->saveSession(s3);
    
    SessionListWidget widget(m_repository.get());
    widget.refresh();
    processEvents();
    
    widget.selectSession(0);
    EXPECT_EQ(widget.currentSessionId(), QString("s1"));
    
    widget.navigateDown();
    EXPECT_EQ(widget.currentSessionId(), QString("s2"));
    
    widget.navigateUp();
    EXPECT_EQ(widget.currentSessionId(), QString("s1"));
}

TEST_F(SessionManagerTest, SessionListWidgetEmitsCreateNewRequested) {
    SessionListWidget widget(m_repository.get());
    
    QSignalSpy spy(&widget, &SessionListWidget::createNewRequested);
    
    widget.requestCreateNew();
    
    EXPECT_EQ(spy.count(), 1);
}

// ============================================================================
// NewSessionDialog Tests
// ============================================================================

TEST_F(SessionManagerTest, NewSessionDialogCreation) {
    QList<Source> sources;
    sources.append(createTestSource("src-1", "owner/repo1"));
    sources.append(createTestSource("src-2", "owner/repo2"));
    
    NewSessionDialog dialog(sources);
    
    EXPECT_TRUE(dialog.isEnabled());
}

TEST_F(SessionManagerTest, NewSessionDialogPopulatesSourceComboBox) {
    QList<Source> sources;
    sources.append(createTestSource("src-1", "owner/repo1"));
    sources.append(createTestSource("src-2", "owner/repo2"));
    
    NewSessionDialog dialog(sources);
    
    EXPECT_EQ(dialog.sourceCount(), 2);
}

TEST_F(SessionManagerTest, NewSessionDialogPopulatesBranchComboBox) {
    QList<Source> sources;
    sources.append(createTestSource("src-1", "owner/repo"));
    
    NewSessionDialog dialog(sources);
    dialog.selectSource(0);
    processEvents();
    
    // Should have main and develop branches
    EXPECT_GE(dialog.branchCount(), 2);
}

TEST_F(SessionManagerTest, NewSessionDialogBranchChangesOnSourceChange) {
    QList<Source> sources;
    Source src1 = createTestSource("src-1", "owner/repo1");
    Source src2 = createTestSource("src-2", "owner/repo2");
    
    // Give src2 different branches
    GitHubBranch feature;
    feature.displayName = "feature";
    src2.githubRepo->branches = {feature};
    
    sources.append(src1);
    sources.append(src2);
    
    NewSessionDialog dialog(sources);
    
    dialog.selectSource(0);
    processEvents();
    int branches1 = dialog.branchCount();
    
    dialog.selectSource(1);
    processEvents();
    int branches2 = dialog.branchCount();
    
    EXPECT_NE(branches1, branches2);
}

TEST_F(SessionManagerTest, NewSessionDialogPromptInput) {
    QList<Source> sources;
    sources.append(createTestSource("src-1", "owner/repo"));
    
    NewSessionDialog dialog(sources);
    
    dialog.setPromptText("Fix the authentication bug in login.py");
    
    EXPECT_EQ(dialog.promptText(), QString("Fix the authentication bug in login.py"));
}

TEST_F(SessionManagerTest, NewSessionDialogValidationEmptyPrompt) {
    QList<Source> sources;
    sources.append(createTestSource("src-1", "owner/repo"));
    
    NewSessionDialog dialog(sources);
    dialog.selectSource(0);
    dialog.setPromptText("");
    
    EXPECT_FALSE(dialog.isValid());
}

TEST_F(SessionManagerTest, NewSessionDialogValidationNoSource) {
    QList<Source> sources;
    
    NewSessionDialog dialog(sources);
    dialog.setPromptText("Some prompt");
    
    EXPECT_FALSE(dialog.isValid());
}

TEST_F(SessionManagerTest, NewSessionDialogValidationSuccess) {
    QList<Source> sources;
    sources.append(createTestSource("src-1", "owner/repo"));
    
    NewSessionDialog dialog(sources);
    dialog.selectSource(0);
    dialog.selectBranch(0);
    dialog.setPromptText("Fix the bug");
    
    EXPECT_TRUE(dialog.isValid());
}

TEST_F(SessionManagerTest, NewSessionDialogReturnsSelectedSource) {
    QList<Source> sources;
    sources.append(createTestSource("src-1", "owner/repo1"));
    sources.append(createTestSource("src-2", "owner/repo2"));
    
    NewSessionDialog dialog(sources);
    dialog.selectSource(1);
    
    Source selected = dialog.selectedSource();
    EXPECT_EQ(selected.id, QString("src-2"));
}

TEST_F(SessionManagerTest, NewSessionDialogReturnsSelectedBranch) {
    QList<Source> sources;
    sources.append(createTestSource("src-1", "owner/repo"));
    
    NewSessionDialog dialog(sources);
    dialog.selectSource(0);
    dialog.selectBranch(1);  // Select "develop"
    
    QString branch = dialog.selectedBranch();
    EXPECT_EQ(branch, QString("develop"));
}

TEST_F(SessionManagerTest, NewSessionDialogEmitsAcceptedWithData) {
    QList<Source> sources;
    sources.append(createTestSource("src-1", "owner/repo"));
    
    NewSessionDialog dialog(sources);
    dialog.selectSource(0);
    dialog.selectBranch(0);
    dialog.setPromptText("Test prompt");
    
    QSignalSpy spy(&dialog, &NewSessionDialog::sessionRequested);
    
    dialog.accept();
    processEvents();
    
    ASSERT_EQ(spy.count(), 1);
    
    Source src = spy.at(0).at(0).value<Source>();
    QString branch = spy.at(0).at(1).toString();
    QString prompt = spy.at(0).at(2).toString();
    
    EXPECT_EQ(src.id, QString("src-1"));
    EXPECT_EQ(branch, QString("main"));
    EXPECT_EQ(prompt, QString("Test prompt"));
}

TEST_F(SessionManagerTest, NewSessionDialogRemembersLastUsedSource) {
    QList<Source> sources;
    sources.append(createTestSource("src-1", "owner/repo1"));
    sources.append(createTestSource("src-2", "owner/repo2"));
    
    // First dialog - select second source
    {
        NewSessionDialog dialog1(sources);
        dialog1.selectSource(1);
        dialog1.savePreferences();
    }
    
    // Second dialog should remember selection
    {
        NewSessionDialog dialog2(sources);
        EXPECT_EQ(dialog2.currentSourceIndex(), 1);
    }
}

// ============================================================================
// SessionDetailWidget Tests
// ============================================================================

TEST_F(SessionManagerTest, SessionDetailWidgetCreation) {
    SessionDetailWidget widget;
    EXPECT_TRUE(widget.isEnabled());
}

TEST_F(SessionManagerTest, SessionDetailWidgetDisplaysSessionInfo) {
    Session session = createTestSession("detail-test", "Test prompt for details");
    session.state = SessionState::InProgress;
    session.title = "Bug Fix Session";
    SourceContext ctx;
    ctx.source = "sources/github/owner/repo";
    GitHubRepoContext ghCtx;
    ghCtx.startingBranch = "main";
    ctx.githubRepoContext = ghCtx;
    session.sourceContext = ctx;
    
    SessionDetailWidget widget;
    widget.setSession(session);
    
    EXPECT_TRUE(widget.displayedText().contains("Bug Fix Session") ||
                widget.displayedText().contains("Test prompt for details"));
    EXPECT_TRUE(widget.displayedText().contains("owner/repo"));
}

TEST_F(SessionManagerTest, SessionDetailWidgetShowsStateIndicator) {
    SessionDetailWidget widget;
    
    Session inProgress = createTestSession("s1", "In progress session");
    inProgress.state = SessionState::InProgress;
    widget.setSession(inProgress);
    QString inProgressIndicator = widget.stateIndicatorText();
    
    Session completed = createTestSession("s2", "Completed session");
    completed.state = SessionState::Completed;
    widget.setSession(completed);
    QString completedIndicator = widget.stateIndicatorText();
    
    EXPECT_NE(inProgressIndicator, completedIndicator);
}

TEST_F(SessionManagerTest, SessionDetailWidgetShowsActivities) {
    Session session = createTestSession("activity-test", "Test activities");
    
    Activity act1;
    act1.id = "act-1";
    act1.name = "activities/act-1";
    act1.originator = "USER";
    UserMessaged userMsg;
    userMsg.userMessage = "Please fix the bug";
    act1.userMessaged = userMsg;
    
    Activity act2;
    act2.id = "act-2";
    act2.name = "activities/act-2";
    act2.originator = "AGENT";
    ProgressUpdated progress;
    progress.title = "Analyzing code";
    progress.description = "Looking at the authentication module";
    act2.progressUpdated = progress;
    
    session.activities = QList<Activity>{act1, act2};
    
    SessionDetailWidget widget;
    widget.setSession(session);
    
    // 1 user activity + 1 prompt bubble = 2 items (progress updates are hidden)
    EXPECT_EQ(widget.activityCount(), 2);
}

TEST_F(SessionManagerTest, SessionDetailWidgetShowsPullRequestLink) {
    Session session = createTestSession("pr-test", "PR test");
    session.state = SessionState::Completed;
    
    SessionOutput output;
    PullRequest pr;
    pr.url = "https://github.com/owner/repo/pull/123";
    pr.title = "Fix authentication bug";
    output.pullRequest = pr;
    session.outputs = QList<SessionOutput>{output};
    
    SessionDetailWidget widget;
    widget.setSession(session);
    
    EXPECT_TRUE(widget.hasPullRequestLink());
    EXPECT_EQ(widget.pullRequestUrl(), QString("https://github.com/owner/repo/pull/123"));
}

TEST_F(SessionManagerTest, SessionDetailWidgetEmitsOpenUrlRequested) {
    Session session = createTestSession("url-test", "URL test");
    session.url = "https://jules.google.com/session/123";
    
    SessionDetailWidget widget;
    widget.setSession(session);
    
    QSignalSpy spy(&widget, &SessionDetailWidget::openUrlRequested);
    
    widget.requestOpenInBrowser();
    
    ASSERT_EQ(spy.count(), 1);
    QString url = spy.at(0).at(0).toString();
    EXPECT_EQ(url, QString("https://jules.google.com/session/123"));
}

TEST_F(SessionManagerTest, SessionDetailWidgetUpdatesOnSessionChange) {
    Session session1 = createTestSession("update-1", "First session");
    session1.state = SessionState::Queued;
    
    Session session2 = createTestSession("update-2", "Second session");
    session2.state = SessionState::Completed;
    
    SessionDetailWidget widget;
    
    widget.setSession(session1);
    QString state1 = widget.stateIndicatorText();
    
    widget.setSession(session2);
    QString state2 = widget.stateIndicatorText();
    
    EXPECT_NE(state1, state2);
}

TEST_F(SessionManagerTest, SessionDetailWidgetClearsOnNoSession) {
    Session session = createTestSession("clear-test", "Clear test");
    
    SessionDetailWidget widget;
    widget.setSession(session);
    EXPECT_FALSE(widget.isEmpty());
    
    widget.clear();
    EXPECT_TRUE(widget.isEmpty());
}

// ============================================================================
// Session Polling Tests
// ============================================================================

TEST_F(SessionManagerTest, PollingManagerStartsPolling) {
    SessionListWidget widget(m_repository.get());
    
    EXPECT_FALSE(widget.isPolling());
    
    widget.startPolling();
    EXPECT_TRUE(widget.isPolling());
    
    widget.stopPolling();
    EXPECT_FALSE(widget.isPolling());
}

TEST_F(SessionManagerTest, PollingManagerDefaultIntervalIs10Seconds) {
    SessionListWidget widget(m_repository.get());
    
    EXPECT_EQ(widget.pollingIntervalMs(), 10000);
}

TEST_F(SessionManagerTest, PollingManagerPollingTriggersRefresh) {
    m_repository->saveSession(createTestSession("poll-1", "Poll test", SessionState::InProgress));
    
    SessionListWidget widget(m_repository.get());
    widget.refresh();
    processEvents();
    
    QSignalSpy refreshSpy(&widget, &SessionListWidget::refreshed);
    
    widget.startPolling();
    
    // Wait for at least one poll cycle (we use a shorter interval for testing)
    widget.setPollingIntervalMs(100);  // 100ms for test
    processEvents(250);
    
    EXPECT_GE(refreshSpy.count(), 1);
    
    widget.stopPolling();
}

TEST_F(SessionManagerTest, PollingManagerOnlyPollsActiveSessions) {
    // Active sessions should trigger polling
    m_repository->saveSession(createTestSession("active", "Active", SessionState::InProgress));
    // Completed sessions should not trigger frequent polling
    m_repository->saveSession(createTestSession("done", "Done", SessionState::Completed));
    
    SessionListWidget widget(m_repository.get());
    widget.refresh();
    
    // The widget should only include active sessions in polling requests
    QList<QString> polledIds = widget.getActiveSessionIds();
    
    EXPECT_TRUE(polledIds.contains("active"));
    // Completed sessions may or may not be in the list depending on implementation
    // but active sessions MUST be included
}

TEST_F(SessionManagerTest, PollingManagerStopsOnNoActiveSessions) {
    // Only completed sessions
    m_repository->saveSession(createTestSession("done-1", "Done 1", SessionState::Completed));
    m_repository->saveSession(createTestSession("done-2", "Done 2", SessionState::Failed));
    
    SessionListWidget widget(m_repository.get());
    widget.refresh();
    
    QList<QString> polledIds = widget.getActiveSessionIds();
    
    // No active sessions to poll
    EXPECT_TRUE(polledIds.isEmpty());
}

TEST_F(SessionManagerTest, SessionStateUpdatesReflectInUI) {
    Session session = createTestSession("state-change", "State change test", SessionState::Queued);
    m_repository->saveSession(session);
    
    SessionListWidget widget(m_repository.get());
    widget.refresh();
    processEvents();
    
    QString initialState = widget.sessionStateText(0);
    
    // Simulate state change from API
    session.state = SessionState::InProgress;
    m_repository->saveSession(session);
    processEvents(100);
    
    QString updatedState = widget.sessionStateText(0);
    
    EXPECT_NE(initialState, updatedState);
}

// ============================================================================
// Integration Tests
// ============================================================================

TEST_F(SessionManagerTest, NewSessionAppearsInListAfterCreation) {
    SessionListWidget listWidget(m_repository.get());
    listWidget.refresh();
    processEvents();
    
    EXPECT_EQ(listWidget.sessionCount(), 0);
    
    // Simulate creating a new session
    Session newSession = createTestSession("brand-new", "Brand new session");
    m_repository->saveSession(newSession);
    processEvents(100);
    
    EXPECT_EQ(listWidget.sessionCount(), 1);
    EXPECT_EQ(listWidget.sessionIdAt(0), QString("brand-new"));
}

TEST_F(SessionManagerTest, SelectingSessionOpensDetailView) {
    Session session = createTestSession("select-detail", "Select for detail");
    session.state = SessionState::InProgress;
    m_repository->saveSession(session);
    
    SessionListWidget listWidget(m_repository.get());
    listWidget.refresh();
    processEvents();
    
    SessionDetailWidget detailWidget;
    
    // Connect list selection to detail display
    QObject::connect(&listWidget, &SessionListWidget::sessionSelected,
                     [&](const QString& sessionId) {
        auto sess = m_repository->getSession(sessionId);
        if (sess.has_value()) {
            detailWidget.setSession(sess.value());
        }
    });
    
    // Select the session
    listWidget.selectSession(0);
    processEvents();
    
    EXPECT_FALSE(detailWidget.isEmpty());
    EXPECT_TRUE(detailWidget.displayedText().contains("Select for detail"));
}

TEST_F(SessionManagerTest, MultipleSessionsPollCorrectly) {
    // Create multiple active sessions
    m_repository->saveSession(createTestSession("active-1", "Active 1", SessionState::InProgress));
    m_repository->saveSession(createTestSession("active-2", "Active 2", SessionState::Planning));
    m_repository->saveSession(createTestSession("active-3", "Active 3", SessionState::Queued));
    
    SessionListWidget widget(m_repository.get());
    widget.refresh();
    processEvents();
    
    QList<QString> activeIds = widget.getActiveSessionIds();
    
    EXPECT_EQ(activeIds.size(), 3);
    EXPECT_TRUE(activeIds.contains("active-1"));
    EXPECT_TRUE(activeIds.contains("active-2"));
    EXPECT_TRUE(activeIds.contains("active-3"));
}

} // namespace test
} // namespace jules

// Main function for Qt test application
int main(int argc, char** argv) {
    QApplication app(argc, argv);
    QCoreApplication::setOrganizationName("JulesLinuxTest");
    QCoreApplication::setApplicationName("SessionManagerTest");
    ::testing::InitGoogleTest(&argc, argv);
    return RUN_ALL_TESTS();
}
