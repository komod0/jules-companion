#include "ui/system_tray.h"

#include <QMainWindow>
#include <QApplication>
#include <QCursor>
#include <QPixmap>
#include <QScreen>
#include <QGuiApplication>

namespace jules {

// Animation sequences
// Loading: 0->1->2->3->4->3->2->1->0 (bouncing effect, 9 frames total)
const QVector<int> SystemTray::s_loadingSequence = {0, 1, 2, 3, 4, 3, 2, 1, 0};
// Running: 0->1->2->3->4->5 (smooth 6-frame loop)
const QVector<int> SystemTray::s_runningSequence = {0, 1, 2, 3, 4, 5};

SystemTray::SystemTray(QObject* parent)
    : QObject(parent)
    , m_trayIcon(new QSystemTrayIcon(this))
    , m_contextMenu(nullptr)
    , m_showAction(nullptr)
    , m_settingsAction(nullptr)
    , m_quitAction(nullptr)
    , m_animationTimer(nullptr)
    , m_state(TrayState::Idle)
{
    qRegisterMetaType<TrayState>("TrayState");
    qRegisterMetaType<QSystemTrayIcon::ActivationReason>("QSystemTrayIcon::ActivationReason");

    setupIcons();
    setupContextMenu();
    setupAnimation();
    updateIcon();
    updateTooltip();

    connect(m_trayIcon, &QSystemTrayIcon::activated,
            this, &SystemTray::onActivated);
}

SystemTray::~SystemTray() {
    stopAnimation();
}

bool SystemTray::isAvailable() const {
    return QSystemTrayIcon::isSystemTrayAvailable();
}

bool SystemTray::isVisible() const {
    return m_trayIcon->isVisible();
}

TrayState SystemTray::state() const {
    return m_state;
}

void SystemTray::setState(TrayState state) {
    if (m_state == state) {
        return;
    }

    m_state = state;

    // Stop any existing animation
    stopAnimation();

    // Start animation for animated states
    if (state == TrayState::Queued || state == TrayState::Planning ||
        state == TrayState::Running) {
        startAnimation();
    } else {
        updateIcon();
    }

    if (m_customTooltip.isEmpty()) {
        updateTooltip();
    }

    emit stateChanged(state);
}

QIcon SystemTray::currentIcon() const {
    return m_trayIcon->icon();
}

QString SystemTray::toolTip() const {
    return m_trayIcon->toolTip();
}

void SystemTray::setToolTip(const QString& tooltip) {
    m_customTooltip = tooltip;
    m_trayIcon->setToolTip(tooltip);
}

QMenu* SystemTray::contextMenu() const {
    return m_contextMenu;
}

QAction* SystemTray::showAction() const {
    return m_showAction;
}

QAction* SystemTray::settingsAction() const {
    return m_settingsAction;
}

QAction* SystemTray::quitAction() const {
    return m_quitAction;
}

QMainWindow* SystemTray::targetWindow() const {
    return m_targetWindow;
}

void SystemTray::setTargetWindow(QMainWindow* window) {
    if (m_targetWindow) {
        disconnect(m_targetWindow, &QObject::destroyed,
                   this, &SystemTray::onTargetWindowDestroyed);
    }

    m_targetWindow = window;

    if (m_targetWindow) {
        connect(m_targetWindow, &QObject::destroyed,
                this, &SystemTray::onTargetWindowDestroyed);
    }

    updateShowActionText();
}

void SystemTray::updateShowActionText() {
    if (!m_showAction) {
        return;
    }

    if (m_targetWindow && m_targetWindow->isVisible()) {
        m_showAction->setText(tr("Hide Window"));
    } else {
        m_showAction->setText(tr("Show Window"));
    }
}

void SystemTray::toggleWindow() {
    if (!m_targetWindow) {
        return;
    }

    if (m_targetWindow->isVisible()) {
        m_targetWindow->hide();
    } else {
        m_targetWindow->show();
        m_targetWindow->raise();
        m_targetWindow->activateWindow();
    }

    updateShowActionText();
}

void SystemTray::simulateActivation(QSystemTrayIcon::ActivationReason reason) {
    onActivated(reason);
}

void SystemTray::show() {
    if (isAvailable()) {
        m_trayIcon->show();
    }
}

void SystemTray::hide() {
    m_trayIcon->hide();
}

void SystemTray::onActivated(QSystemTrayIcon::ActivationReason reason) {
    emit activated(reason);

    if (reason == QSystemTrayIcon::Trigger) {
        // Use tray icon geometry for positioning; fall back to panel-edge detection
        QRect iconRect = m_trayIcon->geometry();
        QPoint pos;
        if (iconRect.isValid() && !iconRect.isNull() && iconRect.width() > 0) {
            pos = iconRect.center();
        } else {
            // On Linux, QSystemTrayIcon::geometry() often returns (0,0,0,0).
            // Detect panel location from the gap between full and available geometry.
            QScreen* screen = QGuiApplication::primaryScreen();
            QRect avail = screen->availableGeometry();
            QRect full = screen->geometry();
            int bottomGap = full.bottom() - avail.bottom();
            int topGap = avail.top() - full.top();

            if (bottomGap > 10) {
                // Bottom panel: position near bottom-right
                pos = QPoint(avail.right() - 200, avail.bottom());
            } else if (topGap > 10) {
                // Top panel: position near top-right
                pos = QPoint(avail.right() - 200, avail.top());
            } else {
                // Fallback: bottom-right of available area
                pos = QPoint(avail.right() - 200, avail.bottom() - 50);
            }
        }
        emit popupRequested(pos);
    } else if (reason == QSystemTrayIcon::MiddleClick) {
        // Middle click toggles main window
        toggleWindow();
    }
}

void SystemTray::onShowActionTriggered() {
    emit showWindowRequested();
    toggleWindow();
}

void SystemTray::onTargetWindowDestroyed() {
    m_targetWindow = nullptr;
    updateShowActionText();
}

void SystemTray::onAnimationTick() {
    if (!m_isAnimating) {
        return;
    }

    const QVector<int>* sequence = nullptr;
    const QVector<QIcon>* frames = nullptr;

    if (m_state == TrayState::Queued || m_state == TrayState::Planning) {
        sequence = &s_loadingSequence;
        frames = &m_loadingFrames;
    } else if (m_state == TrayState::Running) {
        sequence = &s_runningSequence;
        frames = &m_runningFrames;
    }

    if (!sequence || !frames || frames->isEmpty()) {
        stopAnimation();
        return;
    }

    // Get the frame index from the sequence
    int frameIndex = (*sequence)[m_currentFrame % sequence->size()];

    // Safety check for frame bounds
    if (frameIndex >= 0 && frameIndex < frames->size()) {
        m_trayIcon->setIcon((*frames)[frameIndex]);
    }

    // Advance to next frame in sequence
    m_currentFrame = (m_currentFrame + 1) % sequence->size();
}

QIcon SystemTray::loadTrayIcon(const QString& baseName) {
    QIcon icon;
    // Add 22x22 (1x) and 44x44 (2x) for HiDPI support
    icon.addFile(QStringLiteral(":/icons/") + baseName + QStringLiteral(".png"), QSize(22, 22));
    icon.addFile(QStringLiteral(":/icons/") + baseName + QStringLiteral("@2x.png"), QSize(44, 44));
    return icon;
}

void SystemTray::setupIcons() {
    // Load static state icons from resources
    m_idleIcon = loadTrayIcon(QStringLiteral("jules-tray-idle"));
    m_attentionIcon = loadTrayIcon(QStringLiteral("jules-tray-warning"));
    m_failedIcon = loadTrayIcon(QStringLiteral("jules-tray-failed"));
    m_errorIcon = loadTrayIcon(QStringLiteral("jules-tray-failed"));
    m_pausedIcon = loadTrayIcon(QStringLiteral("jules-tray-review"));

    // Load loading animation frames (5 frames)
    m_loadingFrames.clear();
    for (int i = 1; i <= 5; ++i) {
        m_loadingFrames.append(loadTrayIcon(QStringLiteral("jules-tray-load-%1").arg(i)));
    }

    // Load running animation frames (6 frames)
    m_runningFrames.clear();
    for (int i = 1; i <= 6; ++i) {
        m_runningFrames.append(loadTrayIcon(QStringLiteral("jules-tray-running-%1").arg(i)));
    }
}

void SystemTray::setupContextMenu() {
    m_contextMenu = new QMenu();

    m_showAction = m_contextMenu->addAction(tr("Show Window"));
    connect(m_showAction, &QAction::triggered,
            this, &SystemTray::onShowActionTriggered);

    m_contextMenu->addSeparator();

    m_settingsAction = m_contextMenu->addAction(tr("Settings..."));
    connect(m_settingsAction, &QAction::triggered,
            this, &SystemTray::settingsRequested);

    m_contextMenu->addSeparator();

    m_quitAction = m_contextMenu->addAction(tr("Quit"));
    connect(m_quitAction, &QAction::triggered,
            this, &SystemTray::quitRequested);

    m_trayIcon->setContextMenu(m_contextMenu);
}

void SystemTray::setupAnimation() {
    m_animationTimer = new QTimer(this);
    connect(m_animationTimer, &QTimer::timeout,
            this, &SystemTray::onAnimationTick);
}

void SystemTray::startAnimation() {
    if (m_isAnimating) {
        return;
    }

    m_isAnimating = true;
    m_currentFrame = 0;

    // Set animation interval based on state (matching macOS timing)
    int intervalMs = 200;  // Default for loading animation
    if (m_state == TrayState::Running) {
        intervalMs = 300;  // Running animation is slower
    }

    m_animationTimer->start(intervalMs);

    // Trigger first frame immediately
    onAnimationTick();
}

void SystemTray::stopAnimation() {
    if (!m_isAnimating) {
        return;
    }

    m_isAnimating = false;
    m_currentFrame = 0;

    if (m_animationTimer) {
        m_animationTimer->stop();
    }
}

void SystemTray::updateIcon() {
    // This is called for non-animated states
    switch (m_state) {
        case TrayState::Idle:
            m_trayIcon->setIcon(m_idleIcon);
            break;
        case TrayState::Queued:
        case TrayState::Planning:
            // These are animated, but fall back to first frame if animation not running
            if (!m_loadingFrames.isEmpty()) {
                m_trayIcon->setIcon(m_loadingFrames.first());
            }
            break;
        case TrayState::Running:
            // Animated, fall back to first frame
            if (!m_runningFrames.isEmpty()) {
                m_trayIcon->setIcon(m_runningFrames.first());
            }
            break;
        case TrayState::NeedsAttention:
            m_trayIcon->setIcon(m_attentionIcon);
            break;
        case TrayState::Paused:
            m_trayIcon->setIcon(m_pausedIcon);
            break;
        case TrayState::Failed:
            m_trayIcon->setIcon(m_failedIcon);
            break;
        case TrayState::Error:
            m_trayIcon->setIcon(m_errorIcon);
            break;
    }
}

void SystemTray::updateTheme(bool isDark) {
    m_isDark = isDark;
    // Icons are pre-rendered colored PNGs from resources;
    // they work on both dark and light panels without regeneration.
}

void SystemTray::updateTooltip() {
    QString tooltip;

    switch (m_state) {
        case TrayState::Idle:
            tooltip = tr("Jules - Ready");
            break;
        case TrayState::Queued:
            tooltip = tr("Jules - Queued");
            break;
        case TrayState::Planning:
            tooltip = tr("Jules - Planning");
            break;
        case TrayState::Running:
            tooltip = tr("Jules - Running");
            break;
        case TrayState::NeedsAttention:
            tooltip = tr("Jules - Needs Attention");
            break;
        case TrayState::Paused:
            tooltip = tr("Jules - Paused");
            break;
        case TrayState::Failed:
            tooltip = tr("Jules - Failed");
            break;
        case TrayState::Error:
            tooltip = tr("Jules - Error");
            break;
    }

    m_trayIcon->setToolTip(tooltip);
}

}
