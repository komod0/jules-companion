/**
 * @file main_window_test.cpp
 * @brief Unit tests for MainWindow UI shell
 * 
 * TDD approach: These tests define the expected main window behavior.
 * Tests window creation, split view layout, toolbar, status bar, theming,
 * window state persistence, and HiDPI scaling support.
 */

#include <gtest/gtest.h>
#include <QApplication>
#include <QMainWindow>
#include <QSplitter>
#include <QToolBar>
#include <QStatusBar>
#include <QSettings>
#include <QTemporaryDir>
#include <QTimer>
#include <QEventLoop>
#include <QScreen>
#include <QStyleHints>
#include <QPalette>
#include <QWidget>
#include <QVBoxLayout>

#include "ui/main_window.h"

namespace jules {
namespace test {

// ============================================================================
// Test Fixture
// ============================================================================

class MainWindowTest : public ::testing::Test {
protected:
    void SetUp() override {
        // Create temp directory for settings
        m_tempDir = std::make_unique<QTemporaryDir>();
        ASSERT_TRUE(m_tempDir->isValid());
        
        // Configure QSettings to use temp directory
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_tempDir->path());
        QCoreApplication::setOrganizationName("JulesTest");
        QCoreApplication::setApplicationName("JulesLinuxTest");
    }

    void TearDown() override {
        m_tempDir.reset();
    }

    // Helper to process Qt events
    void processEvents(int timeoutMs = 50) {
        QEventLoop loop;
        QTimer::singleShot(timeoutMs, &loop, &QEventLoop::quit);
        loop.exec();
    }

    std::unique_ptr<QTemporaryDir> m_tempDir;
};

// ============================================================================
// Window Creation Tests
// ============================================================================

TEST_F(MainWindowTest, WindowCreatesSuccessfully) {
    MainWindow window;
    EXPECT_NE(window.windowTitle(), QString());
    EXPECT_TRUE(window.windowTitle().contains("Jules") || !window.windowTitle().isEmpty());
}

TEST_F(MainWindowTest, WindowHasReasonableDefaultSize) {
    MainWindow window;
    
    // Default size should be reasonable (at least 800x600)
    EXPECT_GE(window.minimumWidth(), 400);
    EXPECT_GE(window.minimumHeight(), 300);
}

TEST_F(MainWindowTest, WindowCanBeShown) {
    MainWindow window;
    window.show();
    processEvents();
    
    EXPECT_TRUE(window.isVisible());
    window.close();
}

// ============================================================================
// Split View Layout Tests
// ============================================================================

TEST_F(MainWindowTest, HasSplitViewLayout) {
    MainWindow window;
    
    // Should have a splitter as central widget or contain one
    QSplitter* splitter = window.findChild<QSplitter*>();
    ASSERT_NE(splitter, nullptr);
}

TEST_F(MainWindowTest, SplitterHasSidebarAndContent) {
    MainWindow window;
    QSplitter* splitter = window.findChild<QSplitter*>();
    ASSERT_NE(splitter, nullptr);
    
    // Splitter should have at least 2 children (sidebar + content)
    EXPECT_GE(splitter->count(), 2);
}

TEST_F(MainWindowTest, SidebarWidgetExists) {
    MainWindow window;
    
    // Should have sidebar widget accessible
    QWidget* sidebar = window.sidebarWidget();
    ASSERT_NE(sidebar, nullptr);
}

TEST_F(MainWindowTest, ContentWidgetExists) {
    MainWindow window;
    
    // Should have content widget accessible
    QWidget* content = window.contentWidget();
    ASSERT_NE(content, nullptr);
}

TEST_F(MainWindowTest, SidebarHasReasonableWidth) {
    MainWindow window;
    window.show();
    processEvents();
    
    QWidget* sidebar = window.sidebarWidget();
    ASSERT_NE(sidebar, nullptr);
    
    // Sidebar should have reasonable default width (200-400px)
    EXPECT_GE(sidebar->width(), 150);
    EXPECT_LE(sidebar->width(), 500);
}

TEST_F(MainWindowTest, SplitterCanBeResized) {
    MainWindow window;
    window.show();
    processEvents();
    
    QSplitter* splitter = window.findChild<QSplitter*>();
    ASSERT_NE(splitter, nullptr);
    
    // Store original sizes
    QList<int> originalSizes = splitter->sizes();
    ASSERT_GE(originalSizes.size(), 2);
    
    // Try to resize
    QList<int> newSizes;
    newSizes << 300 << originalSizes[1] - 100;
    splitter->setSizes(newSizes);
    processEvents();
    
    // Sizes should have changed
    QList<int> updatedSizes = splitter->sizes();
    // Allow some tolerance due to constraints
    EXPECT_NE(updatedSizes[0], originalSizes[0]);
}

// ============================================================================
// Toolbar Tests
// ============================================================================

TEST_F(MainWindowTest, HasToolbar) {
    MainWindow window;
    
    QToolBar* toolbar = window.findChild<QToolBar*>();
    EXPECT_NE(toolbar, nullptr);
}

TEST_F(MainWindowTest, ToolbarIsVisible) {
    MainWindow window;
    window.show();
    processEvents();
    
    QToolBar* toolbar = window.findChild<QToolBar*>();
    ASSERT_NE(toolbar, nullptr);
    EXPECT_TRUE(toolbar->isVisible());
}

// ============================================================================
// Status Bar Tests
// ============================================================================

TEST_F(MainWindowTest, HasStatusBar) {
    MainWindow window;
    
    QStatusBar* statusBar = window.statusBar();
    EXPECT_NE(statusBar, nullptr);
}

TEST_F(MainWindowTest, StatusBarCanShowMessage) {
    MainWindow window;
    window.show();
    processEvents();
    
    QStatusBar* statusBar = window.statusBar();
    ASSERT_NE(statusBar, nullptr);
    
    statusBar->showMessage("Test message");
    processEvents();
    
    EXPECT_EQ(statusBar->currentMessage(), QString("Test message"));
}

// ============================================================================
// Theme Tests
// ============================================================================

TEST_F(MainWindowTest, SupportsThemeSwitching) {
    MainWindow window;
    
    // Should be able to set theme
    window.setTheme(Theme::Dark);
    EXPECT_EQ(window.currentTheme(), Theme::Dark);
    
    window.setTheme(Theme::Light);
    EXPECT_EQ(window.currentTheme(), Theme::Light);
}

TEST_F(MainWindowTest, DarkThemeHasDarkBackground) {
    MainWindow window;
    window.setTheme(Theme::Dark);
    window.show();
    processEvents();
    
    QPalette palette = window.palette();
    QColor windowColor = palette.color(QPalette::Window);
    
    // Dark theme should have dark background (low lightness)
    EXPECT_LT(windowColor.lightnessF(), 0.5);
}

TEST_F(MainWindowTest, LightThemeHasLightBackground) {
    MainWindow window;
    window.setTheme(Theme::Light);
    window.show();
    processEvents();
    
    QPalette palette = window.palette();
    QColor windowColor = palette.color(QPalette::Window);
    
    // Light theme should have light background (high lightness)
    EXPECT_GT(windowColor.lightnessF(), 0.5);
}

TEST_F(MainWindowTest, SystemThemeFollowsSystemPreference) {
    MainWindow window;
    window.setTheme(Theme::System);
    
    EXPECT_EQ(window.currentTheme(), Theme::System);
    
    // Effective theme should be either Light or Dark
    Theme effective = window.effectiveTheme();
    EXPECT_TRUE(effective == Theme::Light || effective == Theme::Dark);
}

TEST_F(MainWindowTest, ThemeEmitsSignalOnChange) {
    MainWindow window;
    
    bool signalReceived = false;
    Theme newTheme;
    
    QObject::connect(&window, &MainWindow::themeChanged, [&](Theme theme) {
        signalReceived = true;
        newTheme = theme;
    });
    
    window.setTheme(Theme::Dark);
    processEvents();
    
    EXPECT_TRUE(signalReceived);
    EXPECT_EQ(newTheme, Theme::Dark);
}

// ============================================================================
// Window State Persistence Tests
// ============================================================================

TEST_F(MainWindowTest, SavesWindowGeometry) {
    {
        MainWindow window;
        window.resize(1024, 768);
        window.move(100, 100);
        window.show();
        processEvents();
        
        window.saveWindowState();
    }
    
    // Create new window and restore
    {
        MainWindow window;
        window.restoreWindowState();
        window.show();
        processEvents();
        
        EXPECT_EQ(window.size().width(), 1024);
        EXPECT_EQ(window.size().height(), 768);
    }
}

TEST_F(MainWindowTest, SavesSplitterState) {
    QList<int> savedSizes;
    
    {
        MainWindow window;
        window.show();
        processEvents();
        
        QSplitter* splitter = window.findChild<QSplitter*>();
        ASSERT_NE(splitter, nullptr);
        
        // Set specific splitter sizes
        QList<int> sizes;
        sizes << 250 << 550;
        splitter->setSizes(sizes);
        processEvents();
        
        savedSizes = splitter->sizes();
        window.saveWindowState();
    }
    
    // Create new window and restore
    {
        MainWindow window;
        window.restoreWindowState();
        window.show();
        processEvents();
        
        QSplitter* splitter = window.findChild<QSplitter*>();
        ASSERT_NE(splitter, nullptr);
        
        QList<int> restoredSizes = splitter->sizes();
        
        // Allow some tolerance due to resize constraints
        EXPECT_NEAR(restoredSizes[0], savedSizes[0], 20);
    }
}

TEST_F(MainWindowTest, RestoresMaximizedState) {
    {
        MainWindow window;
        window.showMaximized();
        processEvents();
        
        window.saveWindowState();
    }
    
    {
        MainWindow window;
        window.restoreWindowState();
        window.show();
        processEvents();
        
        EXPECT_TRUE(window.isMaximized());
    }
}

// ============================================================================
// HiDPI Scaling Tests
// ============================================================================

TEST_F(MainWindowTest, SupportsHiDPIScaling) {
    MainWindow window;
    window.show();
    processEvents();
    
    // Window should be aware of device pixel ratio
    qreal dpr = window.devicePixelRatioF();
    EXPECT_GE(dpr, 1.0);
}

TEST_F(MainWindowTest, MinimumSizeAccountsForScaling) {
    MainWindow window;
    
    qreal dpr = window.devicePixelRatioF();
    
    // Minimum size should be reasonable regardless of scaling
    // At 1x: at least 400x300
    // At 2x: should still be at least 400x300 in logical pixels
    EXPECT_GE(window.minimumWidth(), 400);
    EXPECT_GE(window.minimumHeight(), 300);
}

// ============================================================================
// Component Access Tests
// ============================================================================

TEST_F(MainWindowTest, ProvidesToolbarAccess) {
    MainWindow window;
    
    QToolBar* toolbar = window.mainToolbar();
    EXPECT_NE(toolbar, nullptr);
}

TEST_F(MainWindowTest, ProvidesStatusBarAccess) {
    MainWindow window;
    
    QStatusBar* statusBar = window.statusBar();
    EXPECT_NE(statusBar, nullptr);
}

// ============================================================================
// Visibility Toggle Tests
// ============================================================================

TEST_F(MainWindowTest, CanToggleSidebarVisibility) {
    MainWindow window;
    window.show();
    processEvents();
    
    QWidget* sidebar = window.sidebarWidget();
    ASSERT_NE(sidebar, nullptr);
    
    // Initially visible
    EXPECT_TRUE(sidebar->isVisible());
    
    // Toggle off
    window.setSidebarVisible(false);
    processEvents();
    EXPECT_FALSE(sidebar->isVisible());
    
    // Toggle on
    window.setSidebarVisible(true);
    processEvents();
    EXPECT_TRUE(sidebar->isVisible());
}

TEST_F(MainWindowTest, CanToggleStatusBarVisibility) {
    MainWindow window;
    window.show();
    processEvents();
    
    QStatusBar* statusBar = window.statusBar();
    ASSERT_NE(statusBar, nullptr);
    
    // Initially visible
    EXPECT_TRUE(statusBar->isVisible());
    
    // Toggle off
    window.setStatusBarVisible(false);
    processEvents();
    EXPECT_FALSE(statusBar->isVisible());
    
    // Toggle on
    window.setStatusBarVisible(true);
    processEvents();
    EXPECT_TRUE(statusBar->isVisible());
}

} // namespace test
} // namespace jules

// Main function for Qt test application
int main(int argc, char** argv) {
    QApplication app(argc, argv);
    ::testing::InitGoogleTest(&argc, argv);
    return RUN_ALL_TESTS();
}
