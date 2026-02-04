#pragma once

#include <QObject>
#include <QString>
#include <QVariantMap>
#include <QDBusInterface>
#include <QDBusPendingCallWatcher>

#include "api/jules_api_client.h"

namespace jules {

/**
 * NotificationManager - Linux desktop notifications via DBus
 * 
 * Uses org.freedesktop.Notifications interface to show desktop notifications
 * for Jules session events like completion, failures, and pending approvals.
 * 
 * Features:
 * - Session completion notifications
 * - Session failure notifications
 * - Awaiting approval notifications
 * - Click-to-open session support
 * - Notification grouping by session
 */
class NotificationManager : public QObject {
    Q_OBJECT

public:
    explicit NotificationManager(QObject* parent = nullptr);
    ~NotificationManager() override;

    /// Check if notifications are available on this system
    bool isAvailable() const;
    
    /// Enable or disable notifications globally
    void setEnabled(bool enabled);
    bool isEnabled() const;

    /// Show a notification for a session event
    void notifySessionCompleted(const Session& session);
    void notifySessionFailed(const Session& session, const QString& reason);
    void notifyAwaitingApproval(const Session& session);
    void notifyAwaitingFeedback(const Session& session);
    
    /// Show a generic notification
    void showNotification(const QString& title, const QString& body,
                          const QString& sessionId = QString());

signals:
    /// Emitted when user clicks on a notification
    void notificationClicked(const QString& sessionId);
    
    /// Emitted when a notification is dismissed
    void notificationDismissed(const QString& sessionId);

private slots:
    void onNotificationClosed(uint id, uint reason);
    void onActionInvoked(uint id, const QString& actionKey);

private:
    void connectToDBus();
    uint sendNotification(const QString& summary, const QString& body,
                          const QString& icon, const QString& sessionId,
                          int timeout = 5000);
    
    QDBusInterface* m_notifyInterface = nullptr;
    bool m_isEnabled = true;
    bool m_isAvailable = false;
    
    // Map notification IDs to session IDs for click handling
    QMap<uint, QString> m_notificationSessionMap;
    
    // App info
    static const QString APP_NAME;
    static const QString APP_ICON;
};

} // namespace jules
