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
#include <QCloseEvent>
#include <QSystemTrayIcon>

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
    , m_sidebarLayout(nullptr)
    , m_contentLayout(nullptr)
    , m_toolbar(nullptr)
    , m_menuBar(nullptr)
    , m_flashMessage(nullptr)
    , m_theme(Theme::System)
    , m_effectiveTheme(Theme::Light)
    , m_sidebarPlaceholder(nullptr)
    , m_contentPlaceholder(nullptr)
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
    
    setupMenuBar();
    setupToolbar();
    setupSplitter();
    setupStatusBar();
}

void MainWindow::setupMenuBar() {
    m_menuBar = menuBar();
    
    QMenu* fileMenu = m_menuBar->addMenu(tr("&File"));
    
    QAction* settingsAction = fileMenu->addAction(tr("&Settings..."));
    settingsAction->setShortcut(QKeySequence::Preferences);
    settingsAction->setMenuRole(QAction::PreferencesRole);
    connect(settingsAction, &QAction::triggered, this, &MainWindow::settingsRequested);
    
    fileMenu->addSeparator();
    
    QAction* quitAction = fileMenu->addAction(tr("&Quit"));
    quitAction->setShortcut(QKeySequence::Quit);
    quitAction->setMenuRole(QAction::QuitRole);
    connect(quitAction, &QAction::triggered, this, &MainWindow::quitRequested);
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

    m_networkIndicator = new QLabel(this);
    m_networkIndicator->setTextFormat(Qt::RichText);
    setNetworkOnline(true);
    status->addPermanentWidget(m_networkIndicator);

    status->showMessage("Ready");
}

void MainWindow::setupSplitter() {
    m_splitter = new QSplitter(Qt::Horizontal, this);
    m_splitter->setChildrenCollapsible(false);
    m_splitter->setHandleWidth(1);
    
    // Sidebar container
    m_sidebar = new QWidget(this);
    m_sidebar->setMinimumWidth(180);
    m_sidebar->setMaximumWidth(400);
    
    m_sidebarLayout = new QVBoxLayout(m_sidebar);
    m_sidebarLayout->setContentsMargins(0, 0, 0, 0);
    m_sidebarLayout->setSpacing(0);
    
    // Create placeholder for sidebar
    m_sidebarPlaceholder = new QWidget(m_sidebar);
    QVBoxLayout* placeholderLayout = new QVBoxLayout(m_sidebarPlaceholder);
    placeholderLayout->setContentsMargins(16, 16, 16, 16);
    QLabel* sessionsLabel = new QLabel("Sessions", m_sidebarPlaceholder);
    sessionsLabel->setStyleSheet("font-weight: bold; font-size: 14px;");
    placeholderLayout->addWidget(sessionsLabel);
    placeholderLayout->addStretch();
    
    m_sidebarLayout->addWidget(m_sidebarPlaceholder);
    
    // Only apply border to the sidebar container itself, not children
    m_sidebar->setObjectName("sidebarContainer");
    m_sidebar->setStyleSheet(R"(
        #sidebarContainer {
            border-right: 1px solid palette(mid);
        }
    )");
    
    // Content container
    m_content = new QWidget(this);
    m_content->setMinimumWidth(300);
    
    m_contentLayout = new QVBoxLayout(m_content);
    m_contentLayout->setContentsMargins(0, 0, 0, 0);
    m_contentLayout->setSpacing(0);
    
    // Create placeholder for content
    m_contentPlaceholder = new QWidget(m_content);
    QVBoxLayout* contentPlaceholderLayout = new QVBoxLayout(m_contentPlaceholder);
    contentPlaceholderLayout->setContentsMargins(24, 24, 24, 24);
    
    QLabel* welcomeLabel = new QLabel("Welcome to Jules", m_contentPlaceholder);
    welcomeLabel->setStyleSheet("font-size: 24px; font-weight: bold;");
    contentPlaceholderLayout->addWidget(welcomeLabel);
    
    QLabel* subtitleLabel = new QLabel("Select a session from the sidebar or create a new one", m_contentPlaceholder);
    subtitleLabel->setStyleSheet("color: palette(placeholderText); font-size: 14px;");
    contentPlaceholderLayout->addWidget(subtitleLabel);
    contentPlaceholderLayout->addStretch();
    
    m_contentLayout->addWidget(m_contentPlaceholder);
    
    m_splitter->addWidget(m_sidebar);
    m_splitter->addWidget(m_content);
    
    m_splitter->setSizes(QList<int>() << DEFAULT_SIDEBAR_WIDTH << (DEFAULT_WIDTH - DEFAULT_SIDEBAR_WIDTH));
    
    setCentralWidget(m_splitter);
}

void MainWindow::setSidebarContent(QWidget* widget) {
    if (!widget || !m_sidebarLayout) return;
    
    // Remove placeholder if it exists
    if (m_sidebarPlaceholder) {
        m_sidebarLayout->removeWidget(m_sidebarPlaceholder);
        m_sidebarPlaceholder->deleteLater();
        m_sidebarPlaceholder = nullptr;
    }
    
    // Clear existing content
    while (m_sidebarLayout->count() > 0) {
        QLayoutItem* item = m_sidebarLayout->takeAt(0);
        if (item->widget() && item->widget() != widget) {
            item->widget()->deleteLater();
        }
        delete item;
    }
    
    widget->setParent(m_sidebar);
    m_sidebarLayout->addWidget(widget);
}

void MainWindow::setMainContent(QWidget* widget) {
    if (!widget || !m_contentLayout) return;
    
    // Remove placeholder if it exists
    if (m_contentPlaceholder) {
        m_contentLayout->removeWidget(m_contentPlaceholder);
        m_contentPlaceholder->deleteLater();
        m_contentPlaceholder = nullptr;
    }
    
    // Clear existing content
    while (m_contentLayout->count() > 0) {
        QLayoutItem* item = m_contentLayout->takeAt(0);
        if (item->widget() && item->widget() != widget) {
            item->widget()->deleteLater();
        }
        delete item;
    }
    
    widget->setParent(m_content);
    m_contentLayout->addWidget(widget);
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
    bool dark = (m_effectiveTheme == Theme::Dark);

    if (dark) {
        palette = createDarkPalette();
    } else {
        palette = createLightPalette();
    }

    setPalette(palette);
    QApplication::setPalette(palette);

    // --- Comprehensive global stylesheet ---
    QString stylesheet;
    if (dark) {
        stylesheet = QStringLiteral(R"(
            /* Scrollbars */
            QScrollBar:vertical {
                width: 8px;
                background: #2a2a2e;
                border: none;
            }
            QScrollBar::handle:vertical {
                background: #555;
                min-height: 20px;
                border-radius: 4px;
            }
            QScrollBar::handle:vertical:hover {
                background: #777;
            }
            QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical {
                height: 0;
            }
            QScrollBar:horizontal {
                height: 8px;
                background: #2a2a2e;
                border: none;
            }
            QScrollBar::handle:horizontal {
                background: #555;
                min-width: 20px;
                border-radius: 4px;
            }
            QScrollBar::handle:horizontal:hover {
                background: #777;
            }
            QScrollBar::add-line:horizontal, QScrollBar::sub-line:horizontal {
                width: 0;
            }
            QScrollBar::add-page, QScrollBar::sub-page {
                background: none;
            }

            /* Buttons */
            QPushButton {
                border-radius: 6px;
                padding: 6px 16px;
                background-color: #3a3a3e;
                color: #f0f0f0;
                border: none;
            }
            QPushButton:hover {
                background-color: #4a4a4e;
            }
            QPushButton:pressed {
                background-color: #2a2a2e;
            }
            QPushButton:disabled {
                color: #666;
                background-color: #2a2a2e;
            }
            QPushButton#accentButton {
                background-color: #7B61FF;
                color: #ffffff;
            }
            QPushButton#accentButton:hover {
                background-color: #9580FF;
            }
            QPushButton#accentButton:pressed {
                background-color: #6350D8;
            }

            /* Inputs */
            QLineEdit {
                border-radius: 6px;
                border: 1px solid #555;
                padding: 6px 10px;
                background-color: #16161a;
                color: #f0f0f0;
            }
            QLineEdit:focus {
                border: 2px solid #B2A3FF;
            }
            QTextEdit {
                border-radius: 6px;
                border: 1px solid #555;
                padding: 6px 10px;
                background-color: #16161a;
                color: #f0f0f0;
            }
            QTextEdit:focus {
                border: 2px solid #B2A3FF;
            }

            /* Lists */
            QListWidget, QTreeWidget {
                border: none;
                background-color: #202124;
            }
            QListWidget::item, QTreeWidget::item {
                padding: 8px;
                border-radius: 4px;
            }
            QListWidget::item:selected, QTreeWidget::item:selected {
                background-color: #7B61FF;
                color: #ffffff;
            }
            QListWidget::item:hover:!selected, QTreeWidget::item:hover:!selected {
                background-color: #3a3a3e;
            }

            /* Splitter */
            QSplitter::handle {
                width: 1px;
                background-color: #3a3a3e;
            }

            /* Tooltips */
            QToolTip {
                border-radius: 6px;
                padding: 6px 10px;
                background-color: #3a3a3e;
                color: #f0f0f0;
                border: 1px solid #555;
            }

            /* GroupBox */
            QGroupBox {
                font-weight: bold;
                border: none;
                border-top: 1px solid #3a3a3e;
                margin-top: 12px;
                padding-top: 12px;
            }
            QGroupBox::title {
                subcontrol-origin: margin;
                subcontrol-position: top left;
                padding: 0 4px;
            }

            /* ComboBox */
            QComboBox {
                border-radius: 6px;
                padding: 6px 16px;
                background-color: #3a3a3e;
                color: #f0f0f0;
                border: none;
            }
            QComboBox:hover {
                background-color: #4a4a4e;
            }
            QComboBox::drop-down {
                border: none;
                width: 20px;
            }
            QComboBox QAbstractItemView {
                background-color: #2a2a2e;
                color: #f0f0f0;
                selection-background-color: #7B61FF;
                selection-color: #ffffff;
                border: 1px solid #555;
                border-radius: 6px;
            }

            /* Tabs */
            QTabWidget::pane {
                border: none;
                border-top: 1px solid #3a3a3e;
            }
            QTabBar::tab {
                padding: 8px 16px;
                background: transparent;
                color: #aaa;
                border: none;
                border-bottom: 2px solid transparent;
            }
            QTabBar::tab:selected {
                color: #f0f0f0;
                border-bottom: 2px solid #B2A3FF;
            }
            QTabBar::tab:hover:!selected {
                color: #ccc;
            }

            /* Menu */
            QMenuBar {
                background-color: #202124;
                color: #f0f0f0;
                border-bottom: 1px solid #3a3a3e;
            }
            QMenuBar::item:selected {
                background-color: #3a3a3e;
                border-radius: 4px;
            }
            QMenu {
                background-color: #2a2a2e;
                color: #f0f0f0;
                border: 1px solid #3a3a3e;
                border-radius: 6px;
                padding: 4px;
            }
            QMenu::item {
                padding: 6px 24px;
                border-radius: 4px;
            }
            QMenu::item:selected {
                background-color: #3a3a3e;
            }
            QMenu::separator {
                height: 1px;
                background-color: #3a3a3e;
                margin: 4px 8px;
            }
        )");
    } else {
        stylesheet = QStringLiteral(R"(
            /* Scrollbars */
            QScrollBar:vertical {
                width: 8px;
                background: #f0f0f2;
                border: none;
            }
            QScrollBar::handle:vertical {
                background: #bbb;
                min-height: 20px;
                border-radius: 4px;
            }
            QScrollBar::handle:vertical:hover {
                background: #999;
            }
            QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical {
                height: 0;
            }
            QScrollBar:horizontal {
                height: 8px;
                background: #f0f0f2;
                border: none;
            }
            QScrollBar::handle:horizontal {
                background: #bbb;
                min-width: 20px;
                border-radius: 4px;
            }
            QScrollBar::handle:horizontal:hover {
                background: #999;
            }
            QScrollBar::add-line:horizontal, QScrollBar::sub-line:horizontal {
                width: 0;
            }
            QScrollBar::add-page, QScrollBar::sub-page {
                background: none;
            }

            /* Buttons */
            QPushButton {
                border-radius: 6px;
                padding: 6px 16px;
                background-color: #e8e8ec;
                color: #1d1d1f;
                border: none;
            }
            QPushButton:hover {
                background-color: #dddde1;
            }
            QPushButton:pressed {
                background-color: #d0d0d4;
            }
            QPushButton:disabled {
                color: #aaa;
                background-color: #f0f0f2;
            }
            QPushButton#accentButton {
                background-color: #7B61FF;
                color: #ffffff;
            }
            QPushButton#accentButton:hover {
                background-color: #6A52E0;
            }
            QPushButton#accentButton:pressed {
                background-color: #5A44C0;
            }

            /* Inputs */
            QLineEdit {
                border-radius: 6px;
                border: 1px solid #ccc;
                padding: 6px 10px;
                background-color: #ffffff;
                color: #1d1d1f;
            }
            QLineEdit:focus {
                border: 2px solid #7B61FF;
            }
            QTextEdit {
                border-radius: 6px;
                border: 1px solid #ccc;
                padding: 6px 10px;
                background-color: #ffffff;
                color: #1d1d1f;
            }
            QTextEdit:focus {
                border: 2px solid #7B61FF;
            }

            /* Lists */
            QListWidget, QTreeWidget {
                border: none;
                background-color: #ffffff;
            }
            QListWidget::item, QTreeWidget::item {
                padding: 8px;
                border-radius: 4px;
            }
            QListWidget::item:selected, QTreeWidget::item:selected {
                background-color: #7B61FF;
                color: #ffffff;
            }
            QListWidget::item:hover:!selected, QTreeWidget::item:hover:!selected {
                background-color: #f0f0f2;
            }

            /* Splitter */
            QSplitter::handle {
                width: 1px;
                background-color: #e0e0e0;
            }

            /* Tooltips */
            QToolTip {
                border-radius: 6px;
                padding: 6px 10px;
                background-color: #f5f5f7;
                color: #1d1d1f;
                border: 1px solid #ccc;
            }

            /* GroupBox */
            QGroupBox {
                font-weight: bold;
                border: none;
                border-top: 1px solid #e0e0e0;
                margin-top: 12px;
                padding-top: 12px;
            }
            QGroupBox::title {
                subcontrol-origin: margin;
                subcontrol-position: top left;
                padding: 0 4px;
            }

            /* ComboBox */
            QComboBox {
                border-radius: 6px;
                padding: 6px 16px;
                background-color: #e8e8ec;
                color: #1d1d1f;
                border: none;
            }
            QComboBox:hover {
                background-color: #dddde1;
            }
            QComboBox::drop-down {
                border: none;
                width: 20px;
            }
            QComboBox QAbstractItemView {
                background-color: #ffffff;
                color: #1d1d1f;
                selection-background-color: #7B61FF;
                selection-color: #ffffff;
                border: 1px solid #ccc;
                border-radius: 6px;
            }

            /* Tabs */
            QTabWidget::pane {
                border: none;
                border-top: 1px solid #e0e0e0;
            }
            QTabBar::tab {
                padding: 8px 16px;
                background: transparent;
                color: #888;
                border: none;
                border-bottom: 2px solid transparent;
            }
            QTabBar::tab:selected {
                color: #1d1d1f;
                border-bottom: 2px solid #7B61FF;
            }
            QTabBar::tab:hover:!selected {
                color: #555;
            }

            /* Menu */
            QMenuBar {
                background-color: #ffffff;
                color: #1d1d1f;
                border-bottom: 1px solid #e0e0e0;
            }
            QMenuBar::item:selected {
                background-color: #f0f0f2;
                border-radius: 4px;
            }
            QMenu {
                background-color: #ffffff;
                color: #1d1d1f;
                border: 1px solid #e0e0e0;
                border-radius: 6px;
                padding: 4px;
            }
            QMenu::item {
                padding: 6px 24px;
                border-radius: 4px;
            }
            QMenu::item:selected {
                background-color: #f0f0f2;
            }
            QMenu::separator {
                height: 1px;
                background-color: #e0e0e0;
                margin: 4px 8px;
            }
        )");
    }

    qApp->setStyleSheet(stylesheet);

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

void MainWindow::setNetworkOnline(bool online) {
    if (!m_networkIndicator) return;
    if (online) {
        m_networkIndicator->setText(
            QStringLiteral("<span style='color:#34c759; font-size:10px;'>\u2B24</span> "
                           "<span style='font-size:11px;'>Online</span>"));
    } else {
        m_networkIndicator->setText(
            QStringLiteral("<span style='color:#ff3b30; font-size:10px;'>\u2B24</span> "
                           "<span style='font-size:11px;'>Offline</span>"));
    }
}

void MainWindow::showFlashMessage(const QString& message, FlashMessageType type, int durationMs) {
    if (!m_flashMessage) {
        m_flashMessage = new FlashMessageWidget(this);
        m_flashMessage->setGeometry(0, 0, width(), 80);
    }
    m_flashMessage->setFixedWidth(width());
    // Position below toolbar so it doesn't cover the settings button
    int topOffset = m_toolbar ? (m_toolbar->y() + m_toolbar->height()) : 0;
    m_flashMessage->move(0, topOffset);
    m_flashMessage->raise();
    m_flashMessage->showMessage(message, type, durationMs);
}

void MainWindow::closeEvent(QCloseEvent* event) {
    if (QSystemTrayIcon::isSystemTrayAvailable()) {
        hide();
        event->ignore();
    } else {
        event->accept();
    }
}

}
