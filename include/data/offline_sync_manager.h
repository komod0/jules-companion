#pragma once

#include <QObject>
#include <QTimer>
#include <QJsonObject>

#include "api/jules_api_client.h"

namespace jules {

class Database;
class NetworkMonitor;

class OfflineSyncManager : public QObject {
    Q_OBJECT

public:
    explicit OfflineSyncManager(Database* db, QObject* parent = nullptr);
    ~OfflineSyncManager() override;

    void setApiClient(JulesApiClient* client);
    void setNetworkMonitor(NetworkMonitor* monitor);

    void queuePendingSession(const QJsonObject& payload);
    void syncPendingQueue();
    int pendingCount() const;
    void clearPendingQueue();

signals:
    void sessionSynced(const QString& sessionId);
    void syncFailed(const QString& error);
    void queueChanged(int pendingCount);

private slots:
    void onConnectivityRestored();
    void onRetryTimerTimeout();
    void onSessionCreated(const Session& session);
    void onErrorOccurred(const ApiError& error);

private:
    void syncNextPending();
    int getPendingCountFromDb() const;

    Database* m_db;
    JulesApiClient* m_apiClient = nullptr;
    NetworkMonitor* m_networkMonitor = nullptr;
    QTimer m_retryTimer;

    bool m_syncing = false;
    int m_currentPendingId = -1;
    int m_currentRetryCount = 0;

    static constexpr int RETRY_INTERVAL_MS = 15000;
    static constexpr int MAX_RETRY_COUNT = 10;
    static constexpr int BASE_BACKOFF_MS = 5000;
    static constexpr int MAX_BACKOFF_MS = 300000;
};

} // namespace jules
