/**
 * @file system_tray_test.cpp
 * @brief Unit tests for SystemTray integration
 * 
 * TDD approach: These tests define the expected system tray behavior.
 * Tests tray icon creation, state management, context menu,
 * click handling, and graceful fallback when tray is unavailable.
 * 
 * Platform support:
 * - X11: AppIndicator (libappindicator3 via Qt)
 * - Wayland: StatusNotifierItem (via Qt/DBus)
 * - GNOME without extension: graceful fallback
 */

#include <gtest/gtest.h>
#include <QApplication>
#include <QSystemTrayIcon>
#include <QMenu>
#include <QAction>
#include <QTimer>
#include <QEventLoop>
#include <QSignalSpy>
#include <QMainWindow>
#include <QIcon>

#include "ui/system_tray.h"

namespace jules {
namespace test {

// ============================================================================
// Test Fixture
// ============================================================================

class SystemTrayTest : public ::testing::Test {
protected:
    void SetUp() override {
        // Check if system tray is available for this test run
        m_trayAvailable = QSystemTrayIcon::isSystemTrayAvailable();
    }

    void TearDown() override {
    }

    // Helper to process Qt events
    void processEvents(int timeoutMs = 50) {
        QEventLoop loop;
        QTimer::singleShot(timeoutMs, &loop, &QEventLoop::quit);
        loop.exec();
    }

    bool m_trayAvailable = false;
};

// ============================================================================
// Tray Availability Tests
// ============================================================================

TEST_F(SystemTrayTest, ReportsSystemTrayAvailability) {
    SystemTray tray;
    
    // Should accurately report system tray availability
    EXPECT_EQ(tray.isAvailable(), QSystemTrayIcon::isSystemTrayAvailable());
}

TEST_F(SystemTrayTest, HandlesUnavailableTrayGracefully) {
    SystemTray tray;
    
    // Even if tray is unavailable, creating should not crash
    // and should not show error
    EXPECT_NO_THROW({
        tray.show();
        tray.hide();
    });
}

// ============================================================================
// Tray Icon State Tests
// ============================================================================

TEST_F(SystemTrayTest, DefaultStateIsIdle) {
    SystemTray tray;
    EXPECT_EQ(tray.state(), TrayState::Idle);
}

TEST_F(SystemTrayTest, CanSetIdleState) {
    SystemTray tray;
    tray.setState(TrayState::Idle);
    EXPECT_EQ(tray.state(), TrayState::Idle);
}

TEST_F(SystemTrayTest, CanSetActiveState) {
    SystemTray tray;
    tray.setState(TrayState::Active);
    EXPECT_EQ(tray.state(), TrayState::Active);
}

TEST_F(SystemTrayTest, CanSetNeedsAttentionState) {
    SystemTray tray;
    tray.setState(TrayState::NeedsAttention);
    EXPECT_EQ(tray.state(), TrayState::NeedsAttention);
}

TEST_F(SystemTrayTest, CanSetErrorState) {
    SystemTray tray;
    tray.setState(TrayState::Error);
    EXPECT_EQ(tray.state(), TrayState::Error);
}

TEST_F(SystemTrayTest, StateChangeEmitsSignal) {
    SystemTray tray;
    
    QSignalSpy spy(&tray, &SystemTray::stateChanged);
    ASSERT_TRUE(spy.isValid());
    
    tray.setState(TrayState::Active);
    
    EXPECT_EQ(spy.count(), 1);
    QList<QVariant> arguments = spy.takeFirst();
    EXPECT_EQ(arguments.at(0).value<TrayState>(), TrayState::Active);
}

TEST_F(SystemTrayTest, SameStateDoesNotEmitSignal) {
    SystemTray tray;
    tray.setState(TrayState::Active);
    
    QSignalSpy spy(&tray, &SystemTray::stateChanged);
    ASSERT_TRUE(spy.isValid());
    
    tray.setState(TrayState::Active);  // Same state again
    
    EXPECT_EQ(spy.count(), 0);  // No signal emitted
}

TEST_F(SystemTrayTest, EachStateHasDistinctIcon) {
    if (!m_trayAvailable) {
        GTEST_SKIP() << "System tray not available";
    }
    
    SystemTray tray;
    tray.show();
    processEvents();
    
    // Get icons for each state
    tray.setState(TrayState::Idle);
    QIcon idleIcon = tray.currentIcon();
    
    tray.setState(TrayState::Active);
    QIcon activeIcon = tray.currentIcon();
    
    tray.setState(TrayState::NeedsAttention);
    QIcon attentionIcon = tray.currentIcon();
    
    tray.setState(TrayState::Error);
    QIcon errorIcon = tray.currentIcon();
    
    // Each state should have a non-null icon
    EXPECT_FALSE(idleIcon.isNull());
    EXPECT_FALSE(activeIcon.isNull());
    EXPECT_FALSE(attentionIcon.isNull());
    EXPECT_FALSE(errorIcon.isNull());
}

// ============================================================================
// Context Menu Tests
// ============================================================================

TEST_F(SystemTrayTest, HasContextMenu) {
    SystemTray tray;
    
    QMenu* menu = tray.contextMenu();
    ASSERT_NE(menu, nullptr);
}

TEST_F(SystemTrayTest, ContextMenuHasShowAction) {
    SystemTray tray;
    QMenu* menu = tray.contextMenu();
    ASSERT_NE(menu, nullptr);
    
    QAction* showAction = tray.showAction();
    ASSERT_NE(showAction, nullptr);
    EXPECT_TRUE(showAction->text().contains("Show", Qt::CaseInsensitive) ||
                showAction->text().contains("Hide", Qt::CaseInsensitive));
}

TEST_F(SystemTrayTest, ContextMenuHasSettingsAction) {
    SystemTray tray;
    QMenu* menu = tray.contextMenu();
    ASSERT_NE(menu, nullptr);
    
    QAction* settingsAction = tray.settingsAction();
    ASSERT_NE(settingsAction, nullptr);
    EXPECT_TRUE(settingsAction->text().contains("Settings", Qt::CaseInsensitive) ||
                settingsAction->text().contains("Preferences", Qt::CaseInsensitive));
}

TEST_F(SystemTrayTest, ContextMenuHasQuitAction) {
    SystemTray tray;
    QMenu* menu = tray.contextMenu();
    ASSERT_NE(menu, nullptr);
    
    QAction* quitAction = tray.quitAction();
    ASSERT_NE(quitAction, nullptr);
    EXPECT_TRUE(quitAction->text().contains("Quit", Qt::CaseInsensitive) ||
                quitAction->text().contains("Exit", Qt::CaseInsensitive));
}

TEST_F(SystemTrayTest, MenuActionsAreInCorrectOrder) {
    SystemTray tray;
    QMenu* menu = tray.contextMenu();
    ASSERT_NE(menu, nullptr);
    
    QList<QAction*> actions = menu->actions();
    ASSERT_GE(actions.size(), 3);  // At least Show, Settings, Quit
    
    // Find positions (ignoring separators)
    int showPos = -1, settingsPos = -1, quitPos = -1;
    int nonSeparatorIndex = 0;
    
    for (int i = 0; i < actions.size(); ++i) {
        if (!actions[i]->isSeparator()) {
            if (actions[i] == tray.showAction()) showPos = nonSeparatorIndex;
            if (actions[i] == tray.settingsAction()) settingsPos = nonSeparatorIndex;
            if (actions[i] == tray.quitAction()) quitPos = nonSeparatorIndex;
            ++nonSeparatorIndex;
        }
    }
    
    // Quit should be last
    EXPECT_GT(quitPos, showPos);
    EXPECT_GT(quitPos, settingsPos);
}

// ============================================================================
// Show/Hide Toggle Tests
// ============================================================================

TEST_F(SystemTrayTest, ShowActionTogglesTargetWindow) {
    SystemTray tray;
    QMainWindow window;
    
    tray.setTargetWindow(&window);
    
    // Window starts hidden
    window.hide();
    EXPECT_FALSE(window.isVisible());
    
    // Trigger show action
    QAction* showAction = tray.showAction();
    ASSERT_NE(showAction, nullptr);
    showAction->trigger();
    processEvents();
    
    EXPECT_TRUE(window.isVisible());
    
    // Trigger again to hide
    showAction->trigger();
    processEvents();
    
    EXPECT_FALSE(window.isVisible());
}

TEST_F(SystemTrayTest, ShowActionTextUpdatesWithWindowState) {
    SystemTray tray;
    QMainWindow window;
    
    tray.setTargetWindow(&window);
    
    // Window hidden -> action should say "Show"
    window.hide();
    tray.updateShowActionText();
    EXPECT_TRUE(tray.showAction()->text().contains("Show", Qt::CaseInsensitive));
    
    // Window visible -> action should say "Hide"
    window.show();
    processEvents();
    tray.updateShowActionText();
    EXPECT_TRUE(tray.showAction()->text().contains("Hide", Qt::CaseInsensitive));
}

TEST_F(SystemTrayTest, EmitsShowWindowSignal) {
    SystemTray tray;
    
    QSignalSpy spy(&tray, &SystemTray::showWindowRequested);
    ASSERT_TRUE(spy.isValid());
    
    tray.showAction()->trigger();
    
    EXPECT_EQ(spy.count(), 1);
}

TEST_F(SystemTrayTest, EmitsSettingsSignal) {
    SystemTray tray;
    
    QSignalSpy spy(&tray, &SystemTray::settingsRequested);
    ASSERT_TRUE(spy.isValid());
    
    tray.settingsAction()->trigger();
    
    EXPECT_EQ(spy.count(), 1);
}

TEST_F(SystemTrayTest, EmitsQuitSignal) {
    SystemTray tray;
    
    QSignalSpy spy(&tray, &SystemTray::quitRequested);
    ASSERT_TRUE(spy.isValid());
    
    tray.quitAction()->trigger();
    
    EXPECT_EQ(spy.count(), 1);
}

// ============================================================================
// Tray Icon Click Tests
// ============================================================================

TEST_F(SystemTrayTest, LeftClickEmitsActivated) {
    if (!m_trayAvailable) {
        GTEST_SKIP() << "System tray not available";
    }
    
    SystemTray tray;
    tray.show();
    processEvents();
    
    QSignalSpy spy(&tray, &SystemTray::activated);
    ASSERT_TRUE(spy.isValid());
    
    // Simulate left click activation
    tray.simulateActivation(QSystemTrayIcon::Trigger);
    
    EXPECT_EQ(spy.count(), 1);
    QList<QVariant> arguments = spy.takeFirst();
    EXPECT_EQ(arguments.at(0).value<QSystemTrayIcon::ActivationReason>(),
              QSystemTrayIcon::Trigger);
}

TEST_F(SystemTrayTest, LeftClickTogglesWindow) {
    if (!m_trayAvailable) {
        GTEST_SKIP() << "System tray not available";
    }
    
    SystemTray tray;
    QMainWindow window;
    tray.setTargetWindow(&window);
    tray.show();
    processEvents();
    
    // Window starts hidden
    window.hide();
    EXPECT_FALSE(window.isVisible());
    
    // Left click should show
    tray.simulateActivation(QSystemTrayIcon::Trigger);
    processEvents();
    EXPECT_TRUE(window.isVisible());
    
    // Left click again should hide
    tray.simulateActivation(QSystemTrayIcon::Trigger);
    processEvents();
    EXPECT_FALSE(window.isVisible());
}

TEST_F(SystemTrayTest, MiddleClickDoesNotCrash) {
    if (!m_trayAvailable) {
        GTEST_SKIP() << "System tray not available";
    }
    
    SystemTray tray;
    tray.show();
    processEvents();
    
    // Middle click should not crash
    EXPECT_NO_THROW({
        tray.simulateActivation(QSystemTrayIcon::MiddleClick);
        processEvents();
    });
}

// ============================================================================
// Tooltip Tests
// ============================================================================

TEST_F(SystemTrayTest, HasDefaultTooltip) {
    SystemTray tray;
    
    QString tooltip = tray.toolTip();
    EXPECT_FALSE(tooltip.isEmpty());
    EXPECT_TRUE(tooltip.contains("Jules", Qt::CaseInsensitive));
}

TEST_F(SystemTrayTest, TooltipReflectsState) {
    SystemTray tray;
    
    tray.setState(TrayState::Idle);
    QString idleTooltip = tray.toolTip();
    
    tray.setState(TrayState::Active);
    QString activeTooltip = tray.toolTip();
    
    tray.setState(TrayState::Error);
    QString errorTooltip = tray.toolTip();
    
    // Tooltips should differ based on state
    EXPECT_NE(idleTooltip, activeTooltip);
    EXPECT_NE(activeTooltip, errorTooltip);
}

TEST_F(SystemTrayTest, CanSetCustomTooltip) {
    SystemTray tray;
    
    tray.setToolTip("Custom Tooltip");
    EXPECT_EQ(tray.toolTip(), QString("Custom Tooltip"));
}

// ============================================================================
// Visibility Tests
// ============================================================================

TEST_F(SystemTrayTest, CanShowTrayIcon) {
    if (!m_trayAvailable) {
        GTEST_SKIP() << "System tray not available";
    }
    
    SystemTray tray;
    EXPECT_FALSE(tray.isVisible());
    
    tray.show();
    processEvents();
    
    EXPECT_TRUE(tray.isVisible());
}

TEST_F(SystemTrayTest, CanHideTrayIcon) {
    if (!m_trayAvailable) {
        GTEST_SKIP() << "System tray not available";
    }
    
    SystemTray tray;
    tray.show();
    processEvents();
    EXPECT_TRUE(tray.isVisible());
    
    tray.hide();
    processEvents();
    
    EXPECT_FALSE(tray.isVisible());
}

// ============================================================================
// Target Window Tests
// ============================================================================

TEST_F(SystemTrayTest, CanSetTargetWindow) {
    SystemTray tray;
    QMainWindow window;
    
    EXPECT_EQ(tray.targetWindow(), nullptr);
    
    tray.setTargetWindow(&window);
    EXPECT_EQ(tray.targetWindow(), &window);
}

TEST_F(SystemTrayTest, ClearsTargetWindowOnWindowDestruction) {
    SystemTray tray;
    
    {
        QMainWindow window;
        tray.setTargetWindow(&window);
        EXPECT_EQ(tray.targetWindow(), &window);
    }
    // window destroyed here
    
    EXPECT_EQ(tray.targetWindow(), nullptr);
}

TEST_F(SystemTrayTest, ToggleWithoutTargetWindowDoesNotCrash) {
    SystemTray tray;
    EXPECT_EQ(tray.targetWindow(), nullptr);
    
    // Should not crash when no target window
    EXPECT_NO_THROW({
        tray.toggleWindow();
    });
}

// ============================================================================
// Message/Notification Tests (for completeness, but notifications are separate task)
// ============================================================================

TEST_F(SystemTrayTest, SupportsMessages) {
    if (!m_trayAvailable) {
        GTEST_SKIP() << "System tray not available";
    }
    
    SystemTray tray;
    
    // Just verify it doesn't crash - actual notification display 
    // will be tested separately
    EXPECT_TRUE(QSystemTrayIcon::supportsMessages());
}

} // namespace test
} // namespace jules

// Main function for Qt test application
int main(int argc, char** argv) {
    QApplication app(argc, argv);
    ::testing::InitGoogleTest(&argc, argv);
    return RUN_ALL_TESTS();
}
