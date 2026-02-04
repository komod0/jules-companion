#pragma once

#include <QMainWindow>
#include <QSplitter>
#include <QToolBar>
#include <QStatusBar>
#include <QSettings>
#include <QMenuBar>
#include <QMenu>
#include <QAction>
#include <QVBoxLayout>
#include "data/settings_manager.h"

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
    QToolBar* mainToolbar() const;
    
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
    
    void showFlashMessage(const QString& message, FlashMessageType type, int durationMs = 3000);

signals:
    void themeChanged(Theme theme);
    void settingsRequested();
    void quitRequested();

private:
    void setupUi();
    void setupMenuBar();
    void setupToolbar();
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
    QToolBar* m_toolbar;
    QMenuBar* m_menuBar;
    FlashMessageWidget* m_flashMessage = nullptr;
    Theme m_theme = Theme::System;
    Theme m_effectiveTheme = Theme::Light;
    
    // Placeholders to remove when real content is set
    QWidget* m_sidebarPlaceholder = nullptr;
    QWidget* m_contentPlaceholder = nullptr;
};

}
