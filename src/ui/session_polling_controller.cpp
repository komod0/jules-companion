#include "ui/session_polling_controller.h"

#include <QDebug>

namespace jules {

SessionPollingController::SessionPollingController(SessionRepository* repository,
                                                   JulesApiClient* apiClient,
                                                   QObject* parent)
    : QObject(parent)
    , m_repository(repository)
    , m_apiClient(apiClient)
    , m_timer(new QTimer(this))
{
    connect(m_timer, &QTimer::timeout, this, &SessionPollingController::onTick);
    connect(m_apiClient, &JulesApiClient::activitiesReceived,
            this, &SessionPollingController::onActivitiesReceived);
}

SessionPollingController::~SessionPollingController() {
    stopPolling();
}

void SessionPollingController::startPolling() {
    stopPolling();
    m_tickCount = 0;
    m_hasRunInitialBackfill = false;
    m_isPaused = false;
    
    m_timer->start(BASE_INTERVAL_MS);
}

void SessionPollingController::stopPolling() {
    m_timer->stop();
}

bool SessionPollingController::isPolling() const {
    return m_timer->isActive();
}

void SessionPollingController::pausePolling() {
    m_isPaused = true;
}

void SessionPollingController::resumePolling() {
    m_isPaused = false;
}

bool SessionPollingController::isPaused() const {
    return m_isPaused;
}

void SessionPollingController::setActiveSessionId(const QString& sessionId) {
    m_activeSessionId = sessionId;
}

QString SessionPollingController::activeSessionId() const {
    return m_activeSessionId;
}

void SessionPollingController::onTick() {
    if (m_isPaused) return;
    
    m_tickCount++;
    int currentTick = m_tickCount;
    
    // Initial backfill after 10 seconds (2 ticks)
    if (!m_hasRunInitialBackfill && currentTick >= INITIAL_BACKFILL_TICKS) {
        m_hasRunInitialBackfill = true;
        backfillActivities();
    }
    
    // Active sessions: every 2 ticks (10s)
    if (currentTick % ACTIVE_SESSIONS_TICKS == 0) {
        pollActiveSessions();
    }
    
    // Backfill: every 6 ticks (30s)
    if (currentTick % BACKFILL_TICKS == 0) {
        backfillActivities();
    }
    
    // Completed sessions: every 12 ticks (60s)
    if (currentTick % COMPLETED_SESSIONS_TICKS == 0) {
        pollCompletedSessions();
    }
    
    // Stale session check: every 120 ticks (10 minutes)
    if (currentTick % STALE_SESSION_CHECK_TICKS == 0) {
        checkStaleSessions();
    }
    
    emit tickCompleted(currentTick);
}

void SessionPollingController::pollActiveSessions() {
    emit requestSessionsRefresh();
    
    // Get top 5 active sessions
    QList<Session> allSessions = m_repository->getAllSessions();
    QStringList idsToFetch;
    
    int count = 0;
    for (const auto& session : allSessions) {
        if (count >= 5) break;
        if (session.isActive()) {
            idsToFetch.append(session.id);
            count++;
        }
    }
    
    // Always include the currently active session if not already in list
    if (!m_activeSessionId.isEmpty() && !idsToFetch.contains(m_activeSessionId)) {
        idsToFetch.append(m_activeSessionId);
    }
    
    if (!idsToFetch.isEmpty()) {
        for (const QString& id : idsToFetch) {
            if (!m_pendingActivityFetches.contains(id)) {
                m_pendingActivityFetches.insert(id);
                m_apiClient->getActivities(id);
            }
        }
        emit requestActivitiesFetch(idsToFetch);
    }
}

void SessionPollingController::pollCompletedSessions() {
    emit requestSessionsRefresh();
    
    // Only poll completed sessions that still need stats
    QList<Session> allSessions = m_repository->getAllSessions();
    QStringList idsToFetch;
    
    int count = 0;
    for (const auto& session : allSessions) {
        if (count >= 5) break;
        if ((session.state == SessionState::Completed || 
             session.state == SessionState::CompletedUnknown) &&
            session.needsActivityFetchForStats()) {
            idsToFetch.append(session.id);
            count++;
        }
    }
    
    if (!idsToFetch.isEmpty()) {
        for (const QString& id : idsToFetch) {
            if (!m_pendingActivityFetches.contains(id)) {
                m_pendingActivityFetches.insert(id);
                m_apiClient->getActivities(id);
            }
        }
        emit requestActivitiesFetch(idsToFetch);
    }
}

void SessionPollingController::backfillActivities() {
    // Query sessions that need backfilling (skip first 5, get next 3)
    QList<Session> allSessions = m_repository->getAllSessions();
    QStringList idsToBackfill;
    
    int skipped = 0;
    int count = 0;
    for (const auto& session : allSessions) {
        if (skipped < 5) {
            skipped++;
            continue;
        }
        if (count >= 3) break;
        
        // Backfill sessions that need activity fetching for stats
        if (session.needsActivityFetchForStats()) {
            idsToBackfill.append(session.id);
            count++;
        }
    }
    
    if (!idsToBackfill.isEmpty()) {
        for (const QString& id : idsToBackfill) {
            if (!m_pendingActivityFetches.contains(id)) {
                m_pendingActivityFetches.insert(id);
                m_apiClient->getActivities(id);
            }
        }
        emit requestActivitiesFetch(idsToBackfill);
    }
}

void SessionPollingController::checkStaleSessions() {
    // Check for sessions that have been active for too long without updates
    QList<Session> allSessions = m_repository->getAllSessions();
    
    for (const auto& session : allSessions) {
        if (session.isStaleActive()) {
            emit requestStaleSessionCheck(session.id);
        }
    }
}

void SessionPollingController::onActivitiesReceived(const QString& sessionId,
                                                     const QList<Activity>& activities) {
    m_pendingActivityFetches.remove(sessionId);
    
    // Update session with activities and compute git stats
    auto sessionOpt = m_repository->getSession(sessionId);
    if (sessionOpt.has_value()) {
        Session session = sessionOpt.value();
        session.activities = activities;
        session.updateCachedDiffData();
        m_repository->saveSession(session);
    }
}

} // namespace jules
