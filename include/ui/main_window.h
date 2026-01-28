#pragma once

#include <QMainWindow>
#include <QSplitter>
#include <QToolBar>
#include <QStatusBar>
#include <QSettings>

namespace jules {

enum class Theme {
    Light,
    Dark,
    System
};

class MainWindow : public QMainWindow {
    Q_OBJECT

public:
    explicit MainWindow(QWidget* parent = nullptr);
    ~MainWindow() override;

    QWidget* sidebarWidget() const;
    QWidget* contentWidget() const;
    QToolBar* mainToolbar() const;

    Theme currentTheme() const;
    Theme effectiveTheme() const;
    void setTheme(Theme theme);

    void saveWindowState();
    void restoreWindowState();

    void setSidebarVisible(bool visible);
    void setStatusBarVisible(bool visible);

signals:
    void themeChanged(Theme theme);

private:
    void setupUi();
    void setupToolbar();
    void setupStatusBar();
    void setupSplitter();
    void applyTheme();
    void updateEffectiveTheme();
    bool isSystemDarkMode() const;

    QSplitter* m_splitter;
    QWidget* m_sidebar;
    QWidget* m_content;
    QToolBar* m_toolbar;
    Theme m_theme = Theme::System;
    Theme m_effectiveTheme = Theme::Light;
};

}
