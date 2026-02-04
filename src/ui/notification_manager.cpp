#include "ui/notification_manager.h"

#include <QDBusConnection>
#include <QDBusReply>
#include <QDebug>

namespace jules {

const QString NotificationManager::APP_NAME = QStringLiteral("Jules Companion");
const QString NotificationManager::APP_ICON = QStringLiteral("jules-companion");

NotificationManager::NotificationManager(QObject* parent)
    : QObject(parent)
{
    connectToDBus();
}

NotificationManager::~NotificationManager() {
    delete m_notifyInterface;
}

void NotificationManager::connectToDBus() {
    m_notifyInterface = new QDBusInterface(
        QStringLiteral("org.freedesktop.Notifications"),
        QStringLiteral("/org/freedesktop/Notifications"),
        QStringLiteral("org.freedesktop.Notifications"),
        QDBusConnection::sessionBus(),
        this
    );
    
    m_isAvailable = m_notifyInterface->isValid();
    
    if (m_isAvailable) {
        // Connect to notification signals
        QDBusConnection::sessionBus().connect(
            QStringLiteral("org.freedesktop.Notifications"),
            QStringLiteral("/org/freedesktop/Notifications"),
            QStringLiteral("org.freedesktop.Notifications"),
            QStringLiteral("NotificationClosed"),
            this,
            SLOT(onNotificationClosed(uint, uint))
        );
        
        QDBusConnection::sessionBus().connect(
            QStringLiteral("org.freedesktop.Notifications"),
            QStringLiteral("/org/freedesktop/Notifications"),
            QStringLiteral("org.freedesktop.Notifications"),
            QStringLiteral("ActionInvoked"),
            this,
            SLOT(onActionInvoked(uint, QString))
        );
        
        qDebug() << "NotificationManager: Connected to org.freedesktop.Notifications";
    } else {
        qWarning() << "NotificationManager: DBus notification service not available";
    }
}

bool NotificationManager::isAvailable() const {
    return m_isAvailable;
}

void NotificationManager::setEnabled(bool enabled) {
    m_isEnabled = enabled;
}

bool NotificationManager::isEnabled() const {
    return m_isEnabled;
}

void NotificationManager::notifySessionCompleted(const Session& session) {
    if (!m_isEnabled || !m_isAvailable) return;
    
    QString title = session.title.value_or(session.prompt.left(50));
    QString body = QStringLiteral("Session completed successfully");
    
    // Add git stats if available
    QString stats = session.gitStatsSummary();
    if (!stats.isEmpty()) {
        body += QStringLiteral(" (%1)").arg(stats);
    }
    
    sendNotification(
        QStringLiteral("✅ Jules: Task Complete"),
        QStringLiteral("%1\n%2").arg(title, body),
        QStringLiteral("dialog-ok"),
        session.id
    );
}

void NotificationManager::notifySessionFailed(const Session& session, const QString& reason) {
    if (!m_isEnabled || !m_isAvailable) return;
    
    QString title = session.title.value_or(session.prompt.left(50));
    QString body = reason.isEmpty() 
        ? QStringLiteral("Session failed")
        : QStringLiteral("Failed: %1").arg(reason);
    
    sendNotification(
        QStringLiteral("❌ Jules: Task Failed"),
        QStringLiteral("%1\n%2").arg(title, body),
        QStringLiteral("dialog-error"),
        session.id,
        10000  // Longer timeout for errors
    );
}

void NotificationManager::notifyAwaitingApproval(const Session& session) {
    if (!m_isEnabled || !m_isAvailable) return;
    
    QString title = session.title.value_or(session.prompt.left(50));
    
    sendNotification(
        QStringLiteral("📋 Jules: Plan Ready"),
        QStringLiteral("%1\nPlan generated - awaiting your approval").arg(title),
        QStringLiteral("dialog-question"),
        session.id,
        0  // Persistent until dismissed
    );
}

void NotificationManager::notifyAwaitingFeedback(const Session& session) {
    if (!m_isEnabled || !m_isAvailable) return;
    
    QString title = session.title.value_or(session.prompt.left(50));
    
    sendNotification(
        QStringLiteral("💬 Jules: Input Needed"),
        QStringLiteral("%1\nAwaiting your feedback").arg(title),
        QStringLiteral("dialog-question"),
        session.id,
        0  // Persistent until dismissed
    );
}

void NotificationManager::showNotification(const QString& title, const QString& body,
                                            const QString& sessionId) {
    if (!m_isEnabled || !m_isAvailable) return;
    
    sendNotification(title, body, QStringLiteral("jules-companion"), sessionId);
}

uint NotificationManager::sendNotification(const QString& summary, const QString& body,
                                            const QString& icon, const QString& sessionId,
                                            int timeout) {
    if (!m_notifyInterface || !m_notifyInterface->isValid()) {
        return 0;
    }
    
    // Build hints
    QVariantMap hints;
    hints["urgency"] = QVariant::fromValue<uchar>(1);  // Normal urgency
    hints["category"] = QStringLiteral("im.received");
    hints["desktop-entry"] = QStringLiteral("jules-companion");
    
    // Build actions (click to open)
    QStringList actions;
    if (!sessionId.isEmpty()) {
        actions << QStringLiteral("default") << QStringLiteral("Open Session");
    }
    
    QDBusReply<uint> reply = m_notifyInterface->call(
        QStringLiteral("Notify"),
        APP_NAME,           // app_name
        0u,                 // replaces_id (0 = new notification)
        icon,               // app_icon
        summary,            // summary
        body,               // body
        actions,            // actions
        hints,              // hints
        timeout             // expire_timeout (-1 = default, 0 = never)
    );
    
    if (reply.isValid()) {
        uint notificationId = reply.value();
        if (!sessionId.isEmpty()) {
            m_notificationSessionMap[notificationId] = sessionId;
        }
        return notificationId;
    } else {
        qWarning() << "Failed to send notification:" << reply.error().message();
        return 0;
    }
}

void NotificationManager::onNotificationClosed(uint id, uint reason) {
    Q_UNUSED(reason);
    
    if (m_notificationSessionMap.contains(id)) {
        QString sessionId = m_notificationSessionMap.take(id);
        emit notificationDismissed(sessionId);
    }
}

void NotificationManager::onActionInvoked(uint id, const QString& actionKey) {
    if (actionKey == QStringLiteral("default") && m_notificationSessionMap.contains(id)) {
        QString sessionId = m_notificationSessionMap.value(id);
        emit notificationClicked(sessionId);
    }
}

} // namespace jules
