#pragma once

#include <QObject>
#include <QTimer>
#include <QSet>

#include "api/jules_api_client.h"
#include "data/session_repository.h"

namespace jules {

/**
 * SessionPollingController - Multi-tier polling for session updates
 * 
 * Matches macOS polling strategy:
 * - Active sessions: every 10s (top 5 + currently viewed)
 * - Backfill: every 30s (older sessions needing stats, 3 at a time)
 * - Completed sessions: every 60s (only those needing git stats)
 * - Stale check: every 10 minutes (mark hung sessions as completedUnknown)
 * 
 * Uses a single timer with 5s base interval, different operations run
 * on different tick cycles for efficiency.
 */
class SessionPollingController : public QObject {
    Q_OBJECT

public:
    explicit SessionPollingController(SessionRepository* repository,
                                      JulesApiClient* apiClient,
                                      QObject* parent = nullptr);
    ~SessionPollingController() override;

    void startPolling();
    void stopPolling();
    bool isPolling() const;
    
    void pausePolling();
    void resumePolling();
    bool isPaused() const;
    
    /// Set the currently active/viewed session ID for priority polling
    void setActiveSessionId(const QString& sessionId);
    QString activeSessionId() const;

signals:
    /// Emitted when sessions need to be refreshed from API
    void requestSessionsRefresh();
    
    /// Emitted when activities need to be fetched for specific sessions
    void requestActivitiesFetch(const QStringList& sessionIds);
    
    /// Emitted when a session should be checked for staleness
    void requestStaleSessionCheck(const QString& sessionId);
    
    /// Emitted after each tick cycle completes
    void tickCompleted(int tickCount);

private slots:
    void onTick();
    void onActivitiesReceived(const QString& sessionId, const QList<Activity>& activities);

private:
    void pollActiveSessions();
    void pollCompletedSessions();
    void backfillActivities();
    void checkStaleSessions();

    // Tick intervals (in 5-second ticks)
    static const int BASE_INTERVAL_MS = 5000;
    static const int ACTIVE_SESSIONS_TICKS = 2;      // 10s
    static const int BACKFILL_TICKS = 6;             // 30s
    static const int COMPLETED_SESSIONS_TICKS = 12;  // 60s
    static const int STALE_SESSION_CHECK_TICKS = 120; // 10 minutes
    static const int INITIAL_BACKFILL_TICKS = 2;     // 10s delay before first backfill

    SessionRepository* m_repository;
    JulesApiClient* m_apiClient;
    QTimer* m_timer;
    
    int m_tickCount = 0;
    bool m_isPaused = false;
    bool m_hasRunInitialBackfill = false;
    QString m_activeSessionId;
    
    QSet<QString> m_pendingActivityFetches;
};

} // namespace jules
