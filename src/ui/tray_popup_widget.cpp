#include "ui/tray_popup_widget.h"
#include "ui/app_colors.h"
#include "data/session_repository.h"
#include "api/jules_api_client.h"

#include <QApplication>
#include <QScreen>
#include <QKeyEvent>
#include <algorithm>
#include <QPainter>
#include <QPainterPath>
#include <QTimer>
#include <QScrollBar>
#include <QDateTime>
#include <QGuiApplication>

namespace jules {

// Helper to detect if running on Wayland
static bool isWayland() {
    return QGuiApplication::platformName().contains("wayland", Qt::CaseInsensitive);
}

TrayPopupWidget::TrayPopupWidget(SessionRepository* repository, QWidget* parent)
    : QWidget(parent, Qt::Window | Qt::FramelessWindowHint | Qt::NoDropShadowWindowHint | Qt::WindowStaysOnTopHint)
    , m_repository(repository)
    , m_opacity(0.0)
    , m_fadeAnimation(nullptr)
{
    // On X11, we can use Qt::Popup for auto-close behavior
    // On Wayland, Qt::Popup requires a transient parent with focus, which tray popups don't have
    // So we use Qt::Window + Qt::WindowStaysOnTopHint and handle close manually
    if (!isWayland()) {
        // X11: use Popup flag for native click-outside-to-close
        setWindowFlags(Qt::Popup | Qt::FramelessWindowHint | Qt::NoDropShadowWindowHint);
    }
    
    setAttribute(Qt::WA_TranslucentBackground);
    setAttribute(Qt::WA_ShowWithoutActivating, false);
    setFocusPolicy(Qt::StrongFocus);
    
    setFixedSize(POPUP_WIDTH, POPUP_HEIGHT);
    
    setupUi();
    setupStyling();
}

TrayPopupWidget::~TrayPopupWidget() {
    if (m_fadeAnimation) {
        m_fadeAnimation->stop();
        delete m_fadeAnimation;
    }
}

void TrayPopupWidget::setupUi() {
    m_mainLayout = new QVBoxLayout(this);
    m_mainLayout->setContentsMargins(12, 12, 12, 12);
    m_mainLayout->setSpacing(12);
    
    // ========== HEADER ==========
    m_headerWidget = new QWidget(this);
    auto* headerLayout = new QHBoxLayout(m_headerWidget);
    headerLayout->setContentsMargins(4, 0, 4, 0);
    headerLayout->setSpacing(8);
    
    // Logo
    m_logoLabel = new QLabel(m_headerWidget);
    m_logoLabel->setPixmap(QPixmap(":/icons/jules-tray-idle.png").scaled(24, 24, Qt::KeepAspectRatio, Qt::SmoothTransformation));
    m_logoLabel->setFixedSize(24, 24);
    
    // Title
    m_titleLabel = new QLabel("Jules", m_headerWidget);
    QFont titleFont = m_titleLabel->font();
    titleFont.setPointSize(14);
    titleFont.setWeight(QFont::DemiBold);
    m_titleLabel->setFont(titleFont);
    
    // Minimize button
    m_minimizeBtn = new QPushButton("\u2922", m_headerWidget);
    m_minimizeBtn->setFixedSize(28, 28);
    m_minimizeBtn->setCursor(Qt::PointingHandCursor);
    m_minimizeBtn->setToolTip("Minimize");
    connect(m_minimizeBtn, &QPushButton::clicked, this, &TrayPopupWidget::hide);

    // Settings button
    m_settingsBtn = new QPushButton("⚙", m_headerWidget);
    m_settingsBtn->setFixedSize(28, 28);
    m_settingsBtn->setCursor(Qt::PointingHandCursor);
    m_settingsBtn->setToolTip("Settings");
    connect(m_settingsBtn, &QPushButton::clicked, this, &TrayPopupWidget::onSettingsClicked);

    headerLayout->addWidget(m_logoLabel);
    headerLayout->addWidget(m_titleLabel);
    headerLayout->addStretch();
    headerLayout->addWidget(m_minimizeBtn);
    headerLayout->addWidget(m_settingsBtn);
    
    // ========== NEW TASK INPUT ==========
    m_inputWidget = new QWidget(this);
    auto* inputLayout = new QHBoxLayout(m_inputWidget);
    inputLayout->setContentsMargins(0, 0, 0, 0);
    inputLayout->setSpacing(8);
    
    m_promptInput = new QLineEdit(m_inputWidget);
    m_promptInput->setPlaceholderText("What would you like Jules to do?");
    m_promptInput->setMinimumHeight(36);
    connect(m_promptInput, &QLineEdit::returnPressed, this, &TrayPopupWidget::onNewSessionSubmit);
    
    m_submitBtn = new QPushButton("→", m_inputWidget);
    m_submitBtn->setFixedSize(36, 36);
    m_submitBtn->setCursor(Qt::PointingHandCursor);
    m_submitBtn->setToolTip("Create new task");
    connect(m_submitBtn, &QPushButton::clicked, this, &TrayPopupWidget::onNewSessionSubmit);
    
    inputLayout->addWidget(m_promptInput);
    inputLayout->addWidget(m_submitBtn);
    
    // ========== SESSION LIST ==========
    m_sessionList = new QListWidget(this);
    m_sessionList->setVerticalScrollMode(QAbstractItemView::ScrollPerPixel);
    m_sessionList->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
    m_sessionList->setSelectionMode(QAbstractItemView::SingleSelection);
    m_sessionList->setFocusPolicy(Qt::NoFocus);
    connect(m_sessionList, &QListWidget::itemClicked, this, &TrayPopupWidget::onSessionClicked);
    connect(m_sessionList, &QListWidget::itemDoubleClicked, this, &TrayPopupWidget::onSessionClicked);
    
    // ========== FOOTER ==========
    m_footerWidget = new QWidget(this);
    auto* footerLayout = new QHBoxLayout(m_footerWidget);
    footerLayout->setContentsMargins(4, 0, 4, 0);
    
    m_quitBtn = new QPushButton("Quit Jules", m_footerWidget);
    m_quitBtn->setCursor(Qt::PointingHandCursor);
    connect(m_quitBtn, &QPushButton::clicked, this, &TrayPopupWidget::quitRequested);
    
    footerLayout->addStretch();
    footerLayout->addWidget(m_quitBtn);
    footerLayout->addStretch();
    
    // ========== ADD TO MAIN LAYOUT ==========
    m_mainLayout->addWidget(m_headerWidget);
    m_mainLayout->addWidget(m_inputWidget);
    m_mainLayout->addWidget(m_sessionList, 1); // Stretch factor 1
    m_mainLayout->addWidget(m_footerWidget);
}

void TrayPopupWidget::setupStyling() {
    bool isDark = palette().window().color().lightness() < 128;
    
    // Main widget background is painted in paintEvent()
    
    // Header styling
    m_titleLabel->setStyleSheet(QString("color: %1;").arg(
        AppColors::textPrimary(isDark).name()));
    
    // Header button style (shared by minimize and settings)
    QString headerBtnStyle = QString(R"(
        QPushButton {
            background-color: transparent;
            border: none;
            border-radius: 14px;
            font-size: 16px;
            color: %1;
        }
        QPushButton:hover {
            background-color: %2;
        }
    )").arg(
        AppColors::textSecondary(isDark).name(),
        AppColors::backgroundSecondary(isDark).name()
    );

    // Minimize button
    m_minimizeBtn->setStyleSheet(headerBtnStyle);

    // Settings button
    m_settingsBtn->setStyleSheet(headerBtnStyle);
    
    // Input field styling
    m_promptInput->setStyleSheet(QString(R"(
        QLineEdit {
            background-color: %1;
            border: 1px solid %2;
            border-radius: 8px;
            padding: 8px 12px;
            color: %3;
            font-size: 13px;
        }
        QLineEdit:focus {
            border-color: %4;
        }
    )").arg(
        AppColors::backgroundSecondary(isDark).name(),
        AppColors::separator(isDark).name(),
        AppColors::textPrimary(isDark).name(),
        AppColors::accent(isDark).name()
    ));
    
    // Submit button
    m_submitBtn->setStyleSheet(QString(R"(
        QPushButton {
            background-color: %1;
            border: none;
            border-radius: 8px;
            font-size: 18px;
            font-weight: bold;
            color: %2;
        }
        QPushButton:hover {
            background-color: %3;
        }
    )").arg(
        AppColors::accent(isDark).name(),
        AppColors::buttonText(isDark).name(),
        AppColors::accentLight(isDark).name()
    ));
    
    // Session list styling
    m_sessionList->setStyleSheet(QString(R"(
        QListWidget {
            background-color: transparent;
            border: none;
            outline: none;
        }
        QListWidget::item {
            background-color: %1;
            border: 1px solid transparent;
            border-radius: 8px;
            padding: 10px;
            margin: 2px 0px;
            color: %2;
        }
        QListWidget::item:hover {
            background-color: %3;
            border-color: %4;
        }
        QListWidget::item:selected {
            background-color: %5;
            border-color: %4;
        }
    )").arg(
        AppColors::backgroundSecondary(isDark).name(),
        AppColors::textPrimary(isDark).name(),
        AppColors::hoverBackground(isDark).name(),
        AppColors::accent(isDark).name(),
        AppColors::selectionBackground(isDark).name()
    ));
    
    // Scrollbar styling
    m_sessionList->verticalScrollBar()->setStyleSheet(QString(R"(
        QScrollBar:vertical {
            background: transparent;
            width: 8px;
            margin: 0px;
        }
        QScrollBar::handle:vertical {
            background: %1;
            border-radius: 4px;
            min-height: 20px;
        }
        QScrollBar::handle:vertical:hover {
            background: %2;
        }
        QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical {
            height: 0px;
        }
        QScrollBar::add-page:vertical, QScrollBar::sub-page:vertical {
            background: transparent;
        }
    )").arg(
        AppColors::separator(isDark).name(),
        AppColors::textSecondary(isDark).name()
    ));
    
    // Quit button
    m_quitBtn->setStyleSheet(QString(R"(
        QPushButton {
            background-color: transparent;
            border: none;
            padding: 6px 16px;
            color: %1;
            font-size: 12px;
        }
        QPushButton:hover {
            color: %2;
        }
    )").arg(
        AppColors::textSecondary(isDark).name(),
        AppColors::destructive(isDark).name()
    ));
}

void TrayPopupWidget::paintEvent(QPaintEvent* event) {
    Q_UNUSED(event)
    
    QPainter painter(this);
    painter.setRenderHint(QPainter::Antialiasing);
    painter.setOpacity(m_opacity);
    
    bool isDark = palette().window().color().lightness() < 128;
    
    // Draw shadow
    QColor shadowColor = isDark ? QColor(0, 0, 0, 80) : QColor(0, 0, 0, 40);
    for (int i = 0; i < 8; ++i) {
        QPainterPath shadowPath;
        int offset = 8 - i;
        shadowPath.addRoundedRect(
            rect().adjusted(offset, offset, -offset, -offset),
            CORNER_RADIUS + i, CORNER_RADIUS + i
        );
        painter.setPen(Qt::NoPen);
        painter.setBrush(QColor(0, 0, 0, 3 + i * 2));
        painter.drawPath(shadowPath);
    }
    
    // Draw background
    QPainterPath bgPath;
    bgPath.addRoundedRect(rect().adjusted(4, 4, -4, -4), CORNER_RADIUS, CORNER_RADIUS);
    
    QColor bgColor = AppColors::background(isDark);
    painter.setBrush(bgColor);
    painter.setPen(Qt::NoPen);
    painter.drawPath(bgPath);
    
    // Draw border
    painter.setPen(QPen(AppColors::separator(isDark), 1));
    painter.setBrush(Qt::NoBrush);
    painter.drawPath(bgPath);
}

void TrayPopupWidget::showNearPosition(const QPoint& globalPos) {
    positionOnScreen(globalPos);
    refreshSessions();
    show();
    raise();
    activateWindow();
    m_promptInput->setFocus();
    animateShow();
}

void TrayPopupWidget::positionOnScreen(const QPoint& nearPos) {
    QScreen* screen = QGuiApplication::screenAt(nearPos);
    if (!screen) {
        screen = QGuiApplication::primaryScreen();
    }

    QRect avail = screen->availableGeometry();
    QRect full  = screen->geometry();

    // Detect panel location by comparing available vs full geometry.
    // A gap at the top means a top panel (GNOME, KDE default, macOS-style).
    // A gap at the bottom means a bottom panel (Windows-style taskbar).
    int topGap    = avail.top()    - full.top();
    int bottomGap = full.bottom()  - avail.bottom();
    bool panelAtTop    = topGap > 10;
    bool panelAtBottom = bottomGap > 10;

    // Also check the click/icon position relative to screen
    bool nearTop    = nearPos.y() < full.top() + full.height() * 0.20;
    bool nearBottom = nearPos.y() > full.bottom() - full.height() * 0.20;

    // X: right-align popup when icon is on right half of screen
    int x;
    if (nearPos.x() > avail.center().x()) {
        x = nearPos.x() - width() + 20;  // Right-align with small offset
    } else {
        x = nearPos.x() - 20;  // Left-align with small offset
    }

    // Y: position based on where the panel is
    int y;
    if (panelAtTop || nearTop) {
        // Panel at top: drop down just below the panel
        y = avail.top() + 4;
    } else if (panelAtBottom || nearBottom) {
        // Panel at bottom: popup rises above the panel
        y = avail.bottom() - height() - 4;
    } else {
        // No clear panel or icon in the middle — snap to top of available area
        y = avail.top() + 4;
    }

    // Clamp to screen edges
    x = std::max(avail.left() + 4, std::min(x, avail.right() - width() - 4));
    y = std::max(avail.top()  + 4, std::min(y, avail.bottom() - height() - 4));

    move(x, y);
}

void TrayPopupWidget::refreshSessions() {
    m_sessionList->clear();
    
    if (!m_repository) {
        return;
    }
    
    QList<Session> sessions = m_repository->getSessions(20);
    
    for (const auto& session : sessions) {
        QString title = session.title.value_or(session.prompt);
        if (title.length() > 50) {
            title = title.left(47) + "...";
        }
        
        // Create formatted display text
        QString stateText;
        switch (session.state) {
            case SessionState::Queued: stateText = "Queued"; break;
            case SessionState::Planning: stateText = "Planning"; break;
            case SessionState::InProgress: stateText = "In Progress"; break;
            case SessionState::Completed: stateText = "Completed"; break;
            case SessionState::Failed: stateText = "Failed"; break;
            case SessionState::Paused: stateText = "Paused"; break;
            case SessionState::AwaitingUserFeedback: stateText = "Needs Feedback"; break;
            case SessionState::AwaitingPlanApproval: stateText = "Awaiting Approval"; break;
            default: stateText = "Unknown"; break;
        }
        
        // Create list item with title and state
        auto* item = new QListWidgetItem(m_sessionList);
        item->setText(QString("%1\n%2").arg(title, stateText));
        item->setData(Qt::UserRole, session.id);
        
        // Size hint for multi-line items
        item->setSizeHint(QSize(0, 56));
    }
    
    if (sessions.isEmpty()) {
        auto* item = new QListWidgetItem("No sessions yet. Start a new task above!", m_sessionList);
        item->setFlags(Qt::NoItemFlags);
        item->setTextAlignment(Qt::AlignCenter);
        
        bool isDark = palette().window().color().lightness() < 128;
        item->setForeground(AppColors::textSecondary(isDark));
    }
}

void TrayPopupWidget::setPopupOpacity(qreal opacity) {
    m_opacity = opacity;
    update();
}

void TrayPopupWidget::animateShow() {
    if (!m_fadeAnimation) {
        m_fadeAnimation = new QPropertyAnimation(this, "popupOpacity", this);
        m_fadeAnimation->setDuration(150);
        m_fadeAnimation->setEasingCurve(QEasingCurve::OutCubic);
    }
    
    m_fadeAnimation->stop();
    m_fadeAnimation->setStartValue(0.0);
    m_fadeAnimation->setEndValue(1.0);
    m_fadeAnimation->start();
}

void TrayPopupWidget::animateHide() {
    if (!m_fadeAnimation) {
        m_fadeAnimation = new QPropertyAnimation(this, "popupOpacity", this);
        m_fadeAnimation->setDuration(100);
        m_fadeAnimation->setEasingCurve(QEasingCurve::InCubic);
    }
    
    m_fadeAnimation->stop();
    m_fadeAnimation->setStartValue(1.0);
    m_fadeAnimation->setEndValue(0.0);
    
    connect(m_fadeAnimation, &QPropertyAnimation::finished, this, [this]() {
        hide();
    }, Qt::UniqueConnection);
    
    m_fadeAnimation->start();
}

void TrayPopupWidget::keyPressEvent(QKeyEvent* event) {
    if (event->key() == Qt::Key_Escape) {
        hide();
        return;
    }
    
    // Keyboard navigation for session list
    if (event->key() == Qt::Key_Down) {
        int nextRow = m_sessionList->currentRow() + 1;
        if (nextRow < m_sessionList->count()) {
            m_sessionList->setCurrentRow(nextRow);
        }
        return;
    }
    
    if (event->key() == Qt::Key_Up) {
        int prevRow = m_sessionList->currentRow() - 1;
        if (prevRow >= 0) {
            m_sessionList->setCurrentRow(prevRow);
        } else {
            m_promptInput->setFocus();
        }
        return;
    }
    
    if (event->key() == Qt::Key_Return || event->key() == Qt::Key_Enter) {
        if (m_sessionList->hasFocus() && m_sessionList->currentItem()) {
            onSessionClicked(m_sessionList->currentItem());
            return;
        }
    }
    
    QWidget::keyPressEvent(event);
}

void TrayPopupWidget::focusOutEvent(QFocusEvent* event) {
    Q_UNUSED(event)
    // Qt::Popup handles click-outside automatically
}

bool TrayPopupWidget::event(QEvent* event) {
    if (event->type() == QEvent::WindowDeactivate) {
        // Close when window loses focus
        hide();
        return true;
    }
    return QWidget::event(event);
}

void TrayPopupWidget::showEvent(QShowEvent* event) {
    QWidget::showEvent(event);
    setupStyling(); // Re-apply styling in case theme changed
}

void TrayPopupWidget::onSessionClicked(QListWidgetItem* item) {
    if (!item) return;
    
    QString sessionId = item->data(Qt::UserRole).toString();
    if (!sessionId.isEmpty()) {
        hide();
        emit sessionSelected(sessionId);
    }
}

void TrayPopupWidget::onSettingsClicked() {
    hide();
    emit settingsRequested();
}

void TrayPopupWidget::onNewSessionSubmit() {
    QString prompt = m_promptInput->text().trimmed();
    if (!prompt.isEmpty()) {
        m_promptInput->clear();
        hide();
        emit newSessionRequested(prompt);
    }
}

} // namespace jules
