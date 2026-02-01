#include "ui/system_tray.h"

#include <QMainWindow>
#include <QPainter>
#include <QPixmap>
#include <QApplication>

namespace jules {

namespace {

QIcon createStateIcon(const QColor& color, const QColor& accent = QColor()) {
    QPixmap pixmap(":/icons/jules-32.png");
    QPainter painter(&pixmap);
    painter.setCompositionMode(QPainter::CompositionMode_SourceIn);
    painter.fillRect(pixmap.rect(), color);

    if (accent.isValid()) {
        painter.setCompositionMode(QPainter::CompositionMode_SourceOver);
        painter.setBrush(accent);
        painter.setPen(Qt::NoPen);
        int size = pixmap.width();
        painter.drawEllipse(size/2 - 3, size/2 - 3, 6, 6);
    }

    painter.end();
    return QIcon(pixmap);
}

}

SystemTray::SystemTray(QObject* parent)
    : QObject(parent)
    , m_trayIcon(new QSystemTrayIcon(this))
    , m_contextMenu(nullptr)
    , m_showAction(nullptr)
    , m_settingsAction(nullptr)
    , m_quitAction(nullptr)
    , m_state(TrayState::Idle)
{
    qRegisterMetaType<TrayState>("TrayState");
    qRegisterMetaType<QSystemTrayIcon::ActivationReason>("QSystemTrayIcon::ActivationReason");
    
    setupIcons();
    setupContextMenu();
    updateIcon();
    updateTooltip();
    
    connect(m_trayIcon, &QSystemTrayIcon::activated,
            this, &SystemTray::onActivated);
}

SystemTray::~SystemTray() = default;

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
    updateIcon();
    
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

void SystemTray::setupIcons() {
    m_idleIcon = createStateIcon(QColor(128, 128, 128));
    m_activeIcon = createStateIcon(QColor(76, 175, 80), QColor(255, 255, 255));
    m_attentionIcon = createStateIcon(QColor(255, 193, 7), QColor(255, 255, 255));
    m_errorIcon = createStateIcon(QColor(244, 67, 54), QColor(255, 255, 255));
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

void SystemTray::updateIcon() {
    switch (m_state) {
        case TrayState::Idle:
            m_trayIcon->setIcon(m_idleIcon);
            break;
        case TrayState::Active:
            m_trayIcon->setIcon(m_activeIcon);
            break;
        case TrayState::NeedsAttention:
            m_trayIcon->setIcon(m_attentionIcon);
            break;
        case TrayState::Error:
            m_trayIcon->setIcon(m_errorIcon);
            break;
    }
}

void SystemTray::updateTooltip() {
    QString tooltip;
    
    switch (m_state) {
        case TrayState::Idle:
            tooltip = tr("Jules - Ready");
            break;
        case TrayState::Active:
            tooltip = tr("Jules - Active");
            break;
        case TrayState::NeedsAttention:
            tooltip = tr("Jules - Needs Attention");
            break;
        case TrayState::Error:
            tooltip = tr("Jules - Error");
            break;
    }
    
    m_trayIcon->setToolTip(tooltip);
}

}
