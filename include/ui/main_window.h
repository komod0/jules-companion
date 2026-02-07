#pragma once

#include <QMainWindow>
#include <QSplitter>

#include <QStatusBar>
#include <QSettings>
#include <QMenuBar>
#include <QMenu>
#include <QAction>
#include <QVBoxLayout>
#include <QLabel>
#include "data/settings_manager.h"

class QCloseEvent;

namespace jules {

class FlashMessageWidget;
enum class FlashMessageType;

// Use Theme from settings_manager.h (global scope)

class MainWindow : public QMainWindow {
    Q_OBJECT

public:
    explicit MainWindow(QWidget* parent = nullptr);
    ~MainWindow() override;

    QWidget* sidebarWidget() const;
    QWidget* contentWidget() const;
    // Set content for sidebar and main content area
    void setSidebarContent(QWidget* widget);
    void setMainContent(QWidget* widget);

    Theme currentTheme() const;
    Theme effectiveTheme() const;
    void setTheme(Theme theme);

    void saveWindowState();
    void restoreWindowState();

    void setSidebarVisible(bool visible);
    void setStatusBarVisible(bool visible);
    void setNetworkOnline(bool online);

    void showFlashMessage(const QString& message, FlashMessageType type, int durationMs = 3000);

public slots:
    void toggleSidebar();

signals:
    void themeChanged(Theme theme);
    void settingsRequested();
    void quitRequested();

protected:
    void closeEvent(QCloseEvent* event) override;

private:
    void setupUi();
    void setupMenuBar();
    void setupStatusBar();
    void setupSplitter();
    void applyTheme();
    void updateEffectiveTheme();
    bool isSystemDarkMode() const;

    QSplitter* m_splitter;
    QWidget* m_sidebar;
    QWidget* m_content;
    QVBoxLayout* m_sidebarLayout;
    QVBoxLayout* m_contentLayout;
    QMenuBar* m_menuBar;
    FlashMessageWidget* m_flashMessage = nullptr;
    QLabel* m_networkIndicator = nullptr;
    Theme m_theme = Theme::System;
    Theme m_effectiveTheme = Theme::Light;

    // View menu
    QMenu* m_viewMenu = nullptr;
    QAction* m_toggleSidebarAction = nullptr;
    bool m_sidebarCollapsed = false;
    QList<int> m_savedSplitterSizes;

    // Placeholders to remove when real content is set
    QWidget* m_sidebarPlaceholder = nullptr;
    QWidget* m_contentPlaceholder = nullptr;
};

}
