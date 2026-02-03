#include "ui/main_window.h"
#include "ui/flash_message_widget.h"

#include <QApplication>
#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QLabel>
#include <QFrame>
#include <QStyleHints>
#include <QPalette>
#include <QScreen>

namespace jules {

namespace {

const QString SETTINGS_GROUP = "MainWindow";
const QString SETTINGS_GEOMETRY = "geometry";
const QString SETTINGS_STATE = "state";
const QString SETTINGS_SPLITTER = "splitter";
const QString SETTINGS_MAXIMIZED = "maximized";

const int DEFAULT_WIDTH = 1200;
const int DEFAULT_HEIGHT = 800;
const int MIN_WIDTH = 600;
const int MIN_HEIGHT = 400;
const int DEFAULT_SIDEBAR_WIDTH = 280;

QPalette createDarkPalette() {
    QPalette palette;
    
    // Match macOS AppColors.swift dark mode colors
    QColor darkBg(32, 33, 36);          // #202124 - background
    QColor darkerBg(22, 22, 26);        // #16161a - backgroundDark
    QColor lightText(240, 240, 240);    // white equivalent
    QColor dimText(122, 115, 132);      // #7a7384 - textSecondary
    QColor accent(178, 163, 255);       // #B2A3FF - purple accent (dark mode)
    QColor highlight(178, 163, 255);    // Same purple for selection
    
    palette.setColor(QPalette::Window, darkBg);
    palette.setColor(QPalette::WindowText, lightText);
    palette.setColor(QPalette::Base, darkerBg);
    palette.setColor(QPalette::AlternateBase, darkBg);
    palette.setColor(QPalette::ToolTipBase, darkBg);
    palette.setColor(QPalette::ToolTipText, lightText);
    palette.setColor(QPalette::Text, lightText);
    palette.setColor(QPalette::Button, darkBg);
    palette.setColor(QPalette::ButtonText, lightText);
    palette.setColor(QPalette::BrightText, Qt::white);
    palette.setColor(QPalette::Link, accent);
    palette.setColor(QPalette::Highlight, highlight);
    palette.setColor(QPalette::HighlightedText, Qt::white);
    palette.setColor(QPalette::PlaceholderText, dimText);
    
    palette.setColor(QPalette::Disabled, QPalette::WindowText, dimText);
    palette.setColor(QPalette::Disabled, QPalette::Text, dimText);
    palette.setColor(QPalette::Disabled, QPalette::ButtonText, dimText);
    
    return palette;
}

QPalette createLightPalette() {
    QPalette palette;
    
    // Match macOS AppColors.swift light mode colors
    QColor lightBg(255, 255, 255);      // #FFFFFF - background
    QColor white(245, 245, 247);        // #F5F5F7 - backgroundSecondary
    QColor darkText(29, 29, 31);        // #1D1D1F - textPrimary
    QColor dimText(110, 110, 115);      // #6E6E73 - textSecondary
    QColor accent(123, 97, 255);        // #7B61FF - purple accent (light mode)
    QColor highlight(123, 97, 255);     // Same purple for selection
    
    palette.setColor(QPalette::Window, lightBg);
    palette.setColor(QPalette::WindowText, darkText);
    palette.setColor(QPalette::Base, white);
    palette.setColor(QPalette::AlternateBase, lightBg);
    palette.setColor(QPalette::ToolTipBase, white);
    palette.setColor(QPalette::ToolTipText, darkText);
    palette.setColor(QPalette::Text, darkText);
    palette.setColor(QPalette::Button, lightBg);
    palette.setColor(QPalette::ButtonText, darkText);
    palette.setColor(QPalette::BrightText, Qt::black);
    palette.setColor(QPalette::Link, accent);
    palette.setColor(QPalette::Highlight, highlight);
    palette.setColor(QPalette::HighlightedText, Qt::white);
    palette.setColor(QPalette::PlaceholderText, dimText);
    
    palette.setColor(QPalette::Disabled, QPalette::WindowText, dimText);
    palette.setColor(QPalette::Disabled, QPalette::Text, dimText);
    palette.setColor(QPalette::Disabled, QPalette::ButtonText, dimText);
    
    return palette;
}

}

MainWindow::MainWindow(QWidget* parent)
    : QMainWindow(parent)
    , m_splitter(nullptr)
    , m_sidebar(nullptr)
    , m_content(nullptr)
    , m_toolbar(nullptr)
    , m_flashMessage(nullptr)
    , m_theme(Theme::System)
    , m_effectiveTheme(Theme::Light)
{
    setupUi();
    updateEffectiveTheme();
    applyTheme();
    
#if QT_VERSION >= QT_VERSION_CHECK(6, 5, 0)
    if (QGuiApplication::styleHints()) {
        connect(QGuiApplication::styleHints(), &QStyleHints::colorSchemeChanged,
                this, [this]() {
            if (m_theme == Theme::System) {
                updateEffectiveTheme();
                applyTheme();
            }
        });
    }
#endif
}

MainWindow::~MainWindow() = default;

void MainWindow::setupUi() {
    setWindowTitle("Jules - Linux");
    setMinimumSize(MIN_WIDTH, MIN_HEIGHT);
    resize(DEFAULT_WIDTH, DEFAULT_HEIGHT);
    
    setupToolbar();
    setupSplitter();
    setupStatusBar();
}

void MainWindow::setupToolbar() {
    m_toolbar = addToolBar("Main Toolbar");
    m_toolbar->setMovable(false);
    m_toolbar->setFloatable(false);
    m_toolbar->setToolButtonStyle(Qt::ToolButtonTextBesideIcon);
    
    m_toolbar->setStyleSheet(R"(
        QToolBar {
            spacing: 8px;
            padding: 4px 8px;
            border: none;
            border-bottom: 1px solid palette(mid);
        }
        QToolButton {
            padding: 6px 12px;
            border-radius: 4px;
        }
        QToolButton:hover {
            background-color: palette(midlight);
        }
    )");
}

void MainWindow::setupStatusBar() {
    QStatusBar* status = statusBar();
    status->setStyleSheet(R"(
        QStatusBar {
            border-top: 1px solid palette(mid);
            padding: 2px 8px;
        }
    )");
    status->showMessage("Ready");
}

void MainWindow::setupSplitter() {
    m_splitter = new QSplitter(Qt::Horizontal, this);
    m_splitter->setChildrenCollapsible(false);
    m_splitter->setHandleWidth(1);
    
    m_sidebar = new QWidget(this);
    m_sidebar->setMinimumWidth(180);
    m_sidebar->setMaximumWidth(400);
    
    QVBoxLayout* sidebarLayout = new QVBoxLayout(m_sidebar);
    sidebarLayout->setContentsMargins(0, 0, 0, 0);
    sidebarLayout->setSpacing(0);
    
    QFrame* sidebarHeader = new QFrame(m_sidebar);
    sidebarHeader->setFrameShape(QFrame::NoFrame);
    QVBoxLayout* headerLayout = new QVBoxLayout(sidebarHeader);
    headerLayout->setContentsMargins(16, 16, 16, 16);
    QLabel* sessionsLabel = new QLabel("Sessions", sidebarHeader);
    sessionsLabel->setStyleSheet("font-weight: bold; font-size: 14px;");
    headerLayout->addWidget(sessionsLabel);
    
    sidebarLayout->addWidget(sidebarHeader);
    sidebarLayout->addStretch();
    
    m_sidebar->setStyleSheet(R"(
        QWidget {
            border-right: 1px solid palette(mid);
        }
    )");
    
    m_content = new QWidget(this);
    m_content->setMinimumWidth(300);
    
    QVBoxLayout* contentLayout = new QVBoxLayout(m_content);
    contentLayout->setContentsMargins(0, 0, 0, 0);
    contentLayout->setSpacing(0);
    
    QFrame* contentHeader = new QFrame(m_content);
    contentHeader->setFrameShape(QFrame::NoFrame);
    QVBoxLayout* contentHeaderLayout = new QVBoxLayout(contentHeader);
    contentHeaderLayout->setContentsMargins(24, 24, 24, 24);
    
    QLabel* welcomeLabel = new QLabel("Welcome to Jules", contentHeader);
    welcomeLabel->setStyleSheet("font-size: 24px; font-weight: bold;");
    contentHeaderLayout->addWidget(welcomeLabel);
    
    QLabel* subtitleLabel = new QLabel("Select a session from the sidebar or create a new one", contentHeader);
    subtitleLabel->setStyleSheet("color: palette(placeholderText); font-size: 14px;");
    contentHeaderLayout->addWidget(subtitleLabel);
    
    contentLayout->addWidget(contentHeader);
    contentLayout->addStretch();
    
    m_splitter->addWidget(m_sidebar);
    m_splitter->addWidget(m_content);
    
    m_splitter->setSizes(QList<int>() << DEFAULT_SIDEBAR_WIDTH << (DEFAULT_WIDTH - DEFAULT_SIDEBAR_WIDTH));
    
    setCentralWidget(m_splitter);
}

QWidget* MainWindow::sidebarWidget() const {
    return m_sidebar;
}

QWidget* MainWindow::contentWidget() const {
    return m_content;
}

QToolBar* MainWindow::mainToolbar() const {
    return m_toolbar;
}

Theme MainWindow::currentTheme() const {
    return m_theme;
}

Theme MainWindow::effectiveTheme() const {
    return m_effectiveTheme;
}

void MainWindow::setTheme(Theme theme) {
    if (m_theme != theme) {
        m_theme = theme;
        updateEffectiveTheme();
        applyTheme();
        emit themeChanged(theme);
    }
}

void MainWindow::updateEffectiveTheme() {
    if (m_theme == Theme::System) {
        m_effectiveTheme = isSystemDarkMode() ? Theme::Dark : Theme::Light;
    } else {
        m_effectiveTheme = m_theme;
    }
}

bool MainWindow::isSystemDarkMode() const {
#if QT_VERSION >= QT_VERSION_CHECK(6, 5, 0)
    if (QGuiApplication::styleHints()) {
        auto scheme = QGuiApplication::styleHints()->colorScheme();
        return scheme == Qt::ColorScheme::Dark;
    }
#endif
    
    QPalette systemPalette = QGuiApplication::palette();
    QColor windowColor = systemPalette.color(QPalette::Window);
    return windowColor.lightnessF() < 0.5;
}

void MainWindow::applyTheme() {
    QPalette palette;
    
    if (m_effectiveTheme == Theme::Dark) {
        palette = createDarkPalette();
    } else {
        palette = createLightPalette();
    }
    
    setPalette(palette);
    QApplication::setPalette(palette);
    
    update();
}

void MainWindow::saveWindowState() {
    QSettings settings;
    settings.beginGroup(SETTINGS_GROUP);
    
    settings.setValue(SETTINGS_GEOMETRY, saveGeometry());
    settings.setValue(SETTINGS_STATE, saveState());
    settings.setValue(SETTINGS_MAXIMIZED, isMaximized());
    
    if (m_splitter) {
        settings.setValue(SETTINGS_SPLITTER, m_splitter->saveState());
    }
    
    settings.endGroup();
}

void MainWindow::restoreWindowState() {
    QSettings settings;
    settings.beginGroup(SETTINGS_GROUP);
    
    if (settings.contains(SETTINGS_GEOMETRY)) {
        restoreGeometry(settings.value(SETTINGS_GEOMETRY).toByteArray());
    }
    
    if (settings.contains(SETTINGS_STATE)) {
        restoreState(settings.value(SETTINGS_STATE).toByteArray());
    }
    
    if (m_splitter && settings.contains(SETTINGS_SPLITTER)) {
        m_splitter->restoreState(settings.value(SETTINGS_SPLITTER).toByteArray());
    }
    
    if (settings.value(SETTINGS_MAXIMIZED, false).toBool()) {
        showMaximized();
    }
    
    settings.endGroup();
}

void MainWindow::setSidebarVisible(bool visible) {
    if (m_sidebar) {
        m_sidebar->setVisible(visible);
    }
}

void MainWindow::setStatusBarVisible(bool visible) {
    statusBar()->setVisible(visible);
}

void MainWindow::showFlashMessage(const QString& message, FlashMessageType type, int durationMs) {
    if (!m_flashMessage) {
        m_flashMessage = new FlashMessageWidget(this);
        m_flashMessage->setGeometry(0, 0, width(), 80);
    }
    m_flashMessage->setFixedWidth(width());
    m_flashMessage->move(0, 0);
    m_flashMessage->raise();
    m_flashMessage->showMessage(message, type, durationMs);
}

}
