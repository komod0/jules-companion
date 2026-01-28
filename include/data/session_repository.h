#pragma once

#include <QObject>
#include <QString>
#include <QList>

#include <optional>

#include "api/jules_api_client.h"
#include "data/database.h"

namespace jules {

struct CachedDiff {
    QString patch;
    std::optional<QString> language;
    std::optional<QString> filename;
    
    bool operator==(const CachedDiff& other) const {
        return patch == other.patch && 
               language == other.language && 
               filename == other.filename;
    }
};

class SessionRepository : public QObject {
    Q_OBJECT

public:
    explicit SessionRepository(Database* db, QObject* parent = nullptr);
    ~SessionRepository() override;

    bool saveSession(const Session& session);
    bool saveSessions(const QList<Session>& sessions);
    std::optional<Session> getSession(const QString& id);
    bool deleteSession(const QString& id);
    
    QList<Session> getAllSessions();
    QList<Session> getSessions(int limit, int offset = 0);
    QList<Session> getActiveSessions();
    std::optional<Session> getNewestSession();
    int sessionCount();

    bool saveDiffs(const QString& sessionId, const QList<CachedDiff>& diffs);
    QList<CachedDiff> getDiffs(const QString& sessionId);
    bool hasDiffs(const QString& sessionId);
    bool deleteDiffs(const QString& sessionId);

signals:
    void sessionChanged(const QString& id);
    void sessionDeleted(const QString& id);
    void sessionsReloaded();

private:
    QString sessionToJson(const Session& session);
    std::optional<Session> jsonToSession(const QString& json);
    QString sessionStateToString(SessionState state);
    SessionState stringToSessionState(const QString& str);

    Database* m_db;
};

}

Q_DECLARE_METATYPE(jules::CachedDiff)
Q_DECLARE_METATYPE(QList<jules::CachedDiff>)
