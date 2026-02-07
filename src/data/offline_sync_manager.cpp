#include "data/offline_sync_manager.h"
#include "data/database.h"
#include "data/network_monitor.h"
#include "api/jules_api_client.h"

#include <QSqlQuery>
#include <QSqlError>
#include <QJsonDocument>
#include <QDebug>
#include <QtMath>

namespace jules {

OfflineSyncManager::OfflineSyncManager(Database* db, QObject* parent)
    : QObject(parent)
    , m_db(db)
{
    m_retryTimer.setInterval(RETRY_INTERVAL_MS);
    connect(&m_retryTimer, &QTimer::timeout,
            this, &OfflineSyncManager::onRetryTimerTimeout);
}

OfflineSyncManager::~OfflineSyncManager() = default;

void OfflineSyncManager::setApiClient(JulesApiClient* client)
{
    if (m_apiClient) {
        disconnect(m_apiClient, nullptr, this, nullptr);
    }

    m_apiClient = client;

    if (m_apiClient) {
        connect(m_apiClient, &JulesApiClient::sessionCreated,
                this, &OfflineSyncManager::onSessionCreated);
        connect(m_apiClient, &JulesApiClient::errorOccurred,
                this, &OfflineSyncManager::onErrorOccurred);
    }
}

void OfflineSyncManager::setNetworkMonitor(NetworkMonitor* monitor)
{
    if (m_networkMonitor) {
        disconnect(m_networkMonitor, nullptr, this, nullptr);
    }

    m_networkMonitor = monitor;

    if (m_networkMonitor) {
        connect(m_networkMonitor, &NetworkMonitor::connectivityRestored,
                this, &OfflineSyncManager::onConnectivityRestored);
    }
}

void OfflineSyncManager::queuePendingSession(const QJsonObject& payload)
{
    QSqlQuery query(m_db->database());
    query.prepare(R"(
        INSERT INTO pending_sessions (json_payload, status)
        VALUES (?, 'pending')
    )");

    QJsonDocument doc(payload);
    query.addBindValue(QString::fromUtf8(doc.toJson(QJsonDocument::Compact)));

    if (!query.exec()) {
        qWarning() << "[OfflineSyncManager] Failed to queue pending session:"
                    << query.lastError().text();
        return;
    }

    int count = getPendingCountFromDb();
    qDebug() << "[OfflineSyncManager] Queued pending session, total pending:" << count;
    emit queueChanged(count);

    // Start retry timer if not already running
    if (!m_retryTimer.isActive()) {
        m_retryTimer.start();
    }
}

void OfflineSyncManager::syncPendingQueue()
{
    if (m_syncing) {
        return;
    }

    if (m_networkMonitor && !m_networkMonitor->isOnline()) {
        qDebug() << "[OfflineSyncManager] Offline, skipping sync";
        return;
    }

    syncNextPending();
}

int OfflineSyncManager::pendingCount() const
{
    return getPendingCountFromDb();
}

void OfflineSyncManager::clearPendingQueue()
{
    QSqlQuery query(m_db->database());
    if (!query.exec("DELETE FROM pending_sessions")) {
        qWarning() << "[OfflineSyncManager] Failed to clear pending queue:"
                    << query.lastError().text();
        return;
    }

    m_retryTimer.stop();
    m_syncing = false;
    m_currentPendingId = -1;
    emit queueChanged(0);
    qDebug() << "[OfflineSyncManager] Cleared pending queue";
}

void OfflineSyncManager::onConnectivityRestored()
{
    qDebug() << "[OfflineSyncManager] Connectivity restored, syncing pending queue";
    syncPendingQueue();
}

void OfflineSyncManager::onRetryTimerTimeout()
{
    if (getPendingCountFromDb() == 0) {
        m_retryTimer.stop();
        return;
    }
    syncPendingQueue();
}

void OfflineSyncManager::onSessionCreated(const Session& session)
{
    if (m_currentPendingId < 0) {
        return;
    }

    // Remove the successfully synced pending session
    QSqlQuery query(m_db->database());
    query.prepare("DELETE FROM pending_sessions WHERE id = ?");
    query.addBindValue(m_currentPendingId);
    query.exec();

    int pendingId = m_currentPendingId;
    m_currentPendingId = -1;
    m_syncing = false;

    int count = getPendingCountFromDb();
    qDebug() << "[OfflineSyncManager] Session synced successfully, pending id:" << pendingId
             << "session:" << session.id << "remaining:" << count;

    emit sessionSynced(session.id);
    emit queueChanged(count);

    // Continue syncing if more pending
    if (count > 0) {
        syncNextPending();
    } else {
        m_retryTimer.stop();
    }
}

void OfflineSyncManager::onErrorOccurred(const ApiError& error)
{
    if (m_currentPendingId < 0) {
        return;
    }

    m_syncing = false;

    // Increment retry count
    QSqlQuery query(m_db->database());
    query.prepare(R"(
        UPDATE pending_sessions
        SET retry_count = retry_count + 1,
            last_retry_at = datetime('now')
        WHERE id = ?
    )");
    query.addBindValue(m_currentPendingId);
    query.exec();

    // Check if max retries reached
    QSqlQuery checkQuery(m_db->database());
    checkQuery.prepare("SELECT retry_count FROM pending_sessions WHERE id = ?");
    checkQuery.addBindValue(m_currentPendingId);
    if (checkQuery.exec() && checkQuery.next()) {
        int retryCount = checkQuery.value(0).toInt();
        if (retryCount >= MAX_RETRY_COUNT) {
            qWarning() << "[OfflineSyncManager] Max retries reached for pending id:"
                        << m_currentPendingId << ", marking as failed";

            QSqlQuery failQuery(m_db->database());
            failQuery.prepare("UPDATE pending_sessions SET status = 'failed' WHERE id = ?");
            failQuery.addBindValue(m_currentPendingId);
            failQuery.exec();

            emit syncFailed(error.message);
            emit queueChanged(getPendingCountFromDb());
        } else {
            // Apply exponential backoff for next retry
            int backoffMs = qMin(BASE_BACKOFF_MS * static_cast<int>(qPow(2, retryCount - 1)),
                                 MAX_BACKOFF_MS);
            qDebug() << "[OfflineSyncManager] Retry" << retryCount << "for pending id:"
                      << m_currentPendingId << "backoff:" << backoffMs << "ms";
            QTimer::singleShot(backoffMs, this, &OfflineSyncManager::syncNextPending);
        }
    }

    m_currentPendingId = -1;
}

void OfflineSyncManager::syncNextPending()
{
    if (m_syncing || !m_apiClient) {
        return;
    }

    QSqlQuery query(m_db->database());
    query.prepare(R"(
        SELECT id, json_payload, retry_count FROM pending_sessions
        WHERE status = 'pending'
        ORDER BY created_at ASC
        LIMIT 1
    )");

    if (!query.exec() || !query.next()) {
        return;
    }

    m_currentPendingId = query.value(0).toInt();
    QString jsonPayload = query.value(1).toString();
    m_currentRetryCount = query.value(2).toInt();

    QJsonDocument doc = QJsonDocument::fromJson(jsonPayload.toUtf8());
    if (!doc.isObject()) {
        qWarning() << "[OfflineSyncManager] Invalid JSON payload for pending id:" << m_currentPendingId;
        // Mark as failed
        QSqlQuery failQuery(m_db->database());
        failQuery.prepare("UPDATE pending_sessions SET status = 'failed' WHERE id = ?");
        failQuery.addBindValue(m_currentPendingId);
        failQuery.exec();
        m_currentPendingId = -1;
        emit queueChanged(getPendingCountFromDb());
        return;
    }

    QJsonObject payload = doc.object();

    // Reconstruct the Source and parameters from the payload
    Source source;
    source.name = payload["sourceName"].toString();
    source.id = payload["sourceId"].toString();
    QString branchName = payload["branchName"].toString();
    QString prompt = payload["prompt"].toString();

    m_syncing = true;
    qDebug() << "[OfflineSyncManager] Sending pending session, id:" << m_currentPendingId
             << "retry:" << m_currentRetryCount;

    m_apiClient->createSession(source, branchName, prompt);
}

int OfflineSyncManager::getPendingCountFromDb() const
{
    QSqlQuery query(m_db->database());
    if (!query.exec("SELECT COUNT(*) FROM pending_sessions WHERE status = 'pending'") || !query.next()) {
        return 0;
    }
    return query.value(0).toInt();
}

} // namespace jules
