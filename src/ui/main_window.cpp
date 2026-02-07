#include "ui/main_window.h"
#include "ui/flash_message_widget.h"
#include "ui/app_colors.h"

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

QPalette createPaletteFromColors(const ThemeColors& c) {
    QPalette palette;

    palette.setColor(QPalette::Window, c.background);
    palette.setColor(QPalette::WindowText, c.textPrimary);
    palette.setColor(QPalette::Base, c.backgroundDark);
    palette.setColor(QPalette::AlternateBase, c.background);
    palette.setColor(QPalette::ToolTipBase, c.backgroundSecondary);
    palette.setColor(QPalette::ToolTipText, c.textPrimary);
    palette.setColor(QPalette::Text, c.textPrimary);
    palette.setColor(QPalette::Button, c.background);
    palette.setColor(QPalette::ButtonText, c.textPrimary);
    palette.setColor(QPalette::BrightText, c.isDark ? Qt::white : Qt::black);
    palette.setColor(QPalette::Link, c.accent);
    palette.setColor(QPalette::Highlight, c.accent);
    palette.setColor(QPalette::HighlightedText, Qt::white);
    palette.setColor(QPalette::PlaceholderText, c.textSecondary);

    palette.setColor(QPalette::Disabled, QPalette::WindowText, c.textSecondary);
    palette.setColor(QPalette::Disabled, QPalette::Text, c.textSecondary);
    palette.setColor(QPalette::Disabled, QPalette::ButtonText, c.textSecondary);

    return palette;
}

QString generateStylesheet(const ThemeColors& c) {
    // Derived colors for UI elements
    QColor btnBg = c.isDark ? c.backgroundSecondary.lighter(130) : c.backgroundDark;
    QColor btnHover = c.isDark ? btnBg.lighter(120) : btnBg.darker(105);
    QColor btnPressed = c.isDark ? c.backgroundDark : btnBg.darker(110);
    QColor btnDisabledBg = c.isDark ? c.backgroundDark : c.backgroundSecondary;
    QColor inputBorder = c.isDark ? c.separator.lighter(140) : c.separator;
    QColor hoverBg = c.isDark ? btnBg : c.backgroundSecondary;
    QColor tabInactive = c.isDark ? c.textSecondary.lighter(130) : c.textSecondary.lighter(110);
    QColor tabHover = c.isDark ? c.textSecondary.lighter(170) : c.textSecondary.darker(120);
    QColor scrollHandle = c.isDark ? c.separator.lighter(140) : c.separator.darker(110);
    QColor scrollHover = c.isDark ? c.separator.lighter(200) : c.separator.darker(140);
    // Accent with 30% alpha for splitter hover (rgba format for Qt stylesheets)
    QString splitterHoverRgba = QStringLiteral("rgba(%1, %2, %3, 77)")
        .arg(c.accent.red()).arg(c.accent.green()).arg(c.accent.blue());

    auto h = [](const QColor& col) { return col.name(); };

    return QStringLiteral(
        "/* Scrollbars */\n"
        "QScrollBar:vertical { width: 8px; background: transparent; border: none; }\n"
        "QScrollBar::handle:vertical { background: %1; min-height: 20px; border-radius: 4px; }\n"
        "QScrollBar::handle:vertical:hover { background: %2; }\n"
        "QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical { height: 0; }\n"
        "QScrollBar:horizontal { height: 8px; background: transparent; border: none; }\n"
        "QScrollBar::handle:horizontal { background: %1; min-width: 20px; border-radius: 4px; }\n"
        "QScrollBar::handle:horizontal:hover { background: %2; }\n"
        "QScrollBar::add-line:horizontal, QScrollBar::sub-line:horizontal { width: 0; }\n"
        "QScrollBar::add-page, QScrollBar::sub-page { background: none; }\n"

        "/* Buttons */\n"
        "QPushButton { border-radius: 6px; padding: 6px 16px; background-color: %3; color: %4; border: none; }\n"
        "QPushButton:hover { background-color: %5; }\n"
        "QPushButton:pressed { background-color: %6; }\n"
        "QPushButton:disabled { color: %7; background-color: %8; }\n"
        "QPushButton#accentButton { background-color: %9; color: #ffffff; }\n"
        "QPushButton#accentButton:hover { background-color: %10; }\n"
        "QPushButton#accentButton:pressed { background-color: %11; }\n"

        "/* Inputs */\n"
        "QLineEdit { border-radius: 6px; border: 1px solid %12; padding: 6px 10px; background-color: %13; color: %4; }\n"
        "QLineEdit:focus { border: 2px solid %9; }\n"
        "QTextEdit { border-radius: 6px; border: 1px solid %12; padding: 6px 10px; background-color: %13; color: %4; }\n"
        "QTextEdit:focus { border: 2px solid %9; }\n"

        "/* Lists */\n"
        "QListWidget, QTreeWidget { border: none; background-color: %14; }\n"
        "QListWidget::item, QTreeWidget::item { padding: 8px; border-radius: 4px; }\n"
        "QListWidget::item:selected, QTreeWidget::item:selected { background-color: %9; color: #ffffff; }\n"
        "QListWidget::item:hover:!selected, QTreeWidget::item:hover:!selected { background-color: %15; }\n"

        "/* Splitter */\n"
        "QSplitter::handle { width: 4px; background-color: %16; }\n"
        "QSplitter::handle:hover { background-color: %17; }\n"

        "/* Tooltips */\n"
        "QToolTip { border-radius: 6px; padding: 6px 10px; background-color: %18; color: %4; border: 1px solid %12; }\n"

        "/* GroupBox */\n"
        "QGroupBox { font-weight: bold; border: none; border-top: 1px solid %16; margin-top: 12px; padding-top: 12px; }\n"
        "QGroupBox::title { subcontrol-origin: margin; subcontrol-position: top left; padding: 0 4px; }\n"

        "/* ComboBox */\n"
        "QComboBox { border-radius: 6px; padding: 6px 16px; background-color: %3; color: %4; border: none; }\n"
        "QComboBox:hover { background-color: %5; }\n"
        "QComboBox::drop-down { border: none; width: 20px; }\n"
        "QComboBox QAbstractItemView { background-color: %18; color: %4; selection-background-color: %9; selection-color: #ffffff; border: 1px solid %12; border-radius: 6px; }\n"

        "/* Tabs */\n"
        "QTabWidget::pane { border: none; border-top: 1px solid %16; }\n"
        "QTabBar::tab { padding: 8px 16px; background: transparent; color: %19; border: none; border-bottom: 2px solid transparent; }\n"
        "QTabBar::tab:selected { color: %4; border-bottom: 2px solid %9; }\n"
        "QTabBar::tab:hover:!selected { color: %20; }\n"

        "/* Menu */\n"
        "QMenuBar { background-color: %14; color: %4; border-bottom: 1px solid %16; }\n"
        "QMenuBar::item:selected { background-color: %15; border-radius: 4px; }\n"
        "QMenu { background-color: %18; color: %4; border: 1px solid %16; border-radius: 6px; padding: 4px; }\n"
        "QMenu::item { padding: 6px 24px; border-radius: 4px; }\n"
        "QMenu::item:selected { background-color: %15; }\n"
        "QMenu::separator { height: 1px; background-color: %16; margin: 4px 8px; }\n"
    )
    .arg(h(scrollHandle))    // %1
    .arg(h(scrollHover))     // %2
    .arg(h(btnBg))           // %3
    .arg(h(c.textPrimary))   // %4
    .arg(h(btnHover))        // %5
    .arg(h(btnPressed))      // %6
    .arg(h(c.textSecondary)) // %7
    .arg(h(btnDisabledBg))   // %8
    .arg(h(c.accent))        // %9
    // QString::arg only takes up to 9 at a time; chain another call
    .arg(h(c.accent.lighter(115)))  // %10 - accent hover
    .arg(h(c.accent.darker(115)))   // %11 - accent pressed
    .arg(h(inputBorder))            // %12
    .arg(h(c.backgroundDark))       // %13
    .arg(h(c.background))           // %14
    .arg(h(hoverBg))                // %15
    .arg(h(c.separator))            // %16
    .arg(splitterHoverRgba)         // %17 - splitter hover (accent 30% alpha)
    .arg(h(c.backgroundSecondary))  // %18
    .arg(h(tabInactive))            // %19
    .arg(h(tabHover));              // %20
}

}

MainWindow::MainWindow(QWidget* parent)
    : QMainWindow(parent)
    , m_splitter(nullptr)
    , m_sidebar(nullptr)
    , m_content(nullptr)
    , m_sidebarLayout(nullptr)
    , m_contentLayout(nullptr)
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

    // View menu
    m_viewMenu = m_menuBar->addMenu(tr("&View"));

    m_toggleSidebarAction = m_viewMenu->addAction(tr("Toggle Sidebar"));
    m_toggleSidebarAction->setShortcut(QKeySequence(Qt::CTRL | Qt::Key_B));
    m_toggleSidebarAction->setCheckable(true);
    m_toggleSidebarAction->setChecked(true);
    connect(m_toggleSidebarAction, &QAction::triggered, this, &MainWindow::toggleSidebar);
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
    m_splitter->setHandleWidth(4);
    
    // Sidebar container
    m_sidebar = new QWidget(this);
    m_sidebar->setMinimumWidth(0);
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
    AppColors::setCurrentTheme(m_effectiveTheme);
    ThemeColors colors = AppColors::colorsForTheme(m_effectiveTheme);

    QPalette palette = createPaletteFromColors(colors);
    setPalette(palette);
    QApplication::setPalette(palette);

    qApp->setStyleSheet(generateStylesheet(colors));

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
    // Position below menu bar
    int topOffset = menuBar()->height();
    m_flashMessage->move(0, topOffset);
    m_flashMessage->raise();
    m_flashMessage->showMessage(message, type, durationMs);
}

void MainWindow::toggleSidebar() {
    if (m_sidebarCollapsed) {
        // Expand: restore saved sizes
        m_sidebar->setMaximumWidth(400);
        if (!m_savedSplitterSizes.isEmpty()) {
            m_splitter->setSizes(m_savedSplitterSizes);
        }
        m_sidebarCollapsed = false;
    } else {
        // Collapse: save current sizes then hide
        m_savedSplitterSizes = m_splitter->sizes();
        m_sidebar->setMaximumWidth(0);
        m_sidebarCollapsed = true;
    }
    if (m_toggleSidebarAction) {
        m_toggleSidebarAction->setChecked(!m_sidebarCollapsed);
    }
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
