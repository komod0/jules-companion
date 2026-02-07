#include "data/session_repository.h"

#include <QSqlQuery>
#include <QSqlError>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QDebug>

namespace jules {

SessionRepository::SessionRepository(Database* db, QObject* parent)
    : QObject(parent)
    , m_db(db)
{
    qRegisterMetaType<CachedDiff>("CachedDiff");
    qRegisterMetaType<QList<CachedDiff>>("QList<CachedDiff>");
}

SessionRepository::~SessionRepository() = default;

bool SessionRepository::saveSession(const Session& session)
{
    QSqlQuery query(m_db->database());
    
    QString json = sessionToJson(session);
    QString stateStr = sessionStateToString(session.state);
    QString createTime = session.createTime.value_or(QString());
    QString updateTime = session.updateTime.value_or(QString());
    QString pollTime = session.lastActivityPollTime.has_value() 
        ? session.lastActivityPollTime->toString(Qt::ISODate) 
        : QString();
    
    query.prepare(R"(
        INSERT OR REPLACE INTO sessions 
        (id, json, create_time, update_time, state, has_cached_diffs, last_activity_poll_time, viewed_post_completion_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    )");
    
    query.addBindValue(session.id);
    query.addBindValue(json);
    query.addBindValue(createTime);
    query.addBindValue(updateTime);
    query.addBindValue(stateStr);
    query.addBindValue(hasDiffs(session.id) ? 1 : 0);
    query.addBindValue(pollTime);
    query.addBindValue(QString());
    
    if (!query.exec()) {
        qWarning() << "Failed to save session:" << query.lastError().text();
        return false;
    }
    
    emit sessionChanged(session.id);
    return true;
}

bool SessionRepository::saveSessions(const QList<Session>& sessions)
{
    QSqlDatabase sqlDb = m_db->database();
    sqlDb.transaction();
    
    for (const auto& session : sessions) {
        QString json = sessionToJson(session);
        QString stateStr = sessionStateToString(session.state);
        QString createTime = session.createTime.value_or(QString());
        QString updateTime = session.updateTime.value_or(QString());
        QString pollTime = session.lastActivityPollTime.has_value()
            ? session.lastActivityPollTime->toString(Qt::ISODate)
            : QString();
        
        QSqlQuery query(sqlDb);
        query.prepare(R"(
            INSERT OR REPLACE INTO sessions 
            (id, json, create_time, update_time, state, has_cached_diffs, last_activity_poll_time, viewed_post_completion_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        )");
        
        query.addBindValue(session.id);
        query.addBindValue(json);
        query.addBindValue(createTime);
        query.addBindValue(updateTime);
        query.addBindValue(stateStr);
        query.addBindValue(hasDiffs(session.id) ? 1 : 0);
        query.addBindValue(pollTime);
        query.addBindValue(QString());
        
        if (!query.exec()) {
            qWarning() << "Failed to save session in batch:" << query.lastError().text();
            sqlDb.rollback();
            return false;
        }
    }
    
    sqlDb.commit();
    emit sessionsReloaded();
    return true;
}

std::optional<Session> SessionRepository::getSession(const QString& id)
{
    QSqlQuery query(m_db->database());
    query.prepare("SELECT json, last_activity_poll_time FROM sessions WHERE id = ?");
    query.addBindValue(id);
    
    if (!query.exec() || !query.next()) {
        return std::nullopt;
    }
    
    QString json = query.value(0).toString();
    QString pollTimeStr = query.value(1).toString();
    
    auto session = jsonToSession(json);
    if (session && !pollTimeStr.isEmpty()) {
        session->lastActivityPollTime = QDateTime::fromString(pollTimeStr, Qt::ISODate);
    }
    
    return session;
}

bool SessionRepository::deleteSession(const QString& id)
{
    auto existing = getSession(id);
    if (!existing) {
        return false;
    }
    
    deleteDiffs(id);
    
    QSqlQuery query(m_db->database());
    query.prepare("DELETE FROM sessions WHERE id = ?");
    query.addBindValue(id);
    
    if (!query.exec()) {
        qWarning() << "Failed to delete session:" << query.lastError().text();
        return false;
    }
    
    emit sessionDeleted(id);
    return true;
}

QList<Session> SessionRepository::getAllSessions()
{
    return getSessions(-1, 0);
}

QList<Session> SessionRepository::getSessions(int limit, int offset)
{
    QList<Session> result;
    QSqlQuery query(m_db->database());
    
    QString sql = "SELECT json, last_activity_poll_time FROM sessions ORDER BY create_time DESC";
    if (limit > 0) {
        sql += QString(" LIMIT %1 OFFSET %2").arg(limit).arg(offset);
    }
    
    if (!query.exec(sql)) {
        qWarning() << "Failed to get sessions:" << query.lastError().text();
        return result;
    }
    
    while (query.next()) {
        QString json = query.value(0).toString();
        QString pollTimeStr = query.value(1).toString();
        
        auto session = jsonToSession(json);
        if (session) {
            if (!pollTimeStr.isEmpty()) {
                session->lastActivityPollTime = QDateTime::fromString(pollTimeStr, Qt::ISODate);
            }
            result.append(*session);
        }
    }
    
    return result;
}

QList<Session> SessionRepository::getActiveSessions()
{
    QList<Session> result;
    QSqlQuery query(m_db->database());
    
    query.prepare(R"(
        SELECT json, last_activity_poll_time FROM sessions 
        WHERE state IN ('QUEUED', 'PLANNING', 'IN_PROGRESS', 'AWAITING_PLAN_APPROVAL', 'AWAITING_USER_FEEDBACK')
        ORDER BY create_time DESC
    )");
    
    if (!query.exec()) {
        qWarning() << "Failed to get active sessions:" << query.lastError().text();
        return result;
    }
    
    while (query.next()) {
        QString json = query.value(0).toString();
        QString pollTimeStr = query.value(1).toString();
        
        auto session = jsonToSession(json);
        if (session) {
            if (!pollTimeStr.isEmpty()) {
                session->lastActivityPollTime = QDateTime::fromString(pollTimeStr, Qt::ISODate);
            }
            result.append(*session);
        }
    }
    
    return result;
}

std::optional<Session> SessionRepository::getNewestSession()
{
    QSqlQuery query(m_db->database());
    query.prepare("SELECT json, last_activity_poll_time FROM sessions ORDER BY create_time DESC LIMIT 1");
    
    if (!query.exec() || !query.next()) {
        return std::nullopt;
    }
    
    QString json = query.value(0).toString();
    QString pollTimeStr = query.value(1).toString();
    
    auto session = jsonToSession(json);
    if (session && !pollTimeStr.isEmpty()) {
        session->lastActivityPollTime = QDateTime::fromString(pollTimeStr, Qt::ISODate);
    }
    
    return session;
}

int SessionRepository::sessionCount()
{
    QSqlQuery query(m_db->database());
    if (!query.exec("SELECT COUNT(*) FROM sessions") || !query.next()) {
        return 0;
    }
    return query.value(0).toInt();
}

bool SessionRepository::saveDiffs(const QString& sessionId, const QList<CachedDiff>& diffs)
{
    deleteDiffs(sessionId);
    
    QSqlDatabase sqlDb = m_db->database();
    sqlDb.transaction();
    
    QSqlQuery query(sqlDb);
    query.prepare(R"(
        INSERT INTO cached_diffs (session_id, patch, language, filename, order_index)
        VALUES (?, ?, ?, ?, ?)
    )");
    
    int orderIndex = 0;
    for (const auto& diff : diffs) {
        query.addBindValue(sessionId);
        query.addBindValue(diff.patch);
        query.addBindValue(diff.language.value_or(QString()));
        query.addBindValue(diff.filename.value_or(QString()));
        query.addBindValue(orderIndex++);
        
        if (!query.exec()) {
            qWarning() << "Failed to save diff:" << query.lastError().text();
            sqlDb.rollback();
            return false;
        }
    }
    
    QSqlQuery updateQuery(sqlDb);
    updateQuery.prepare("UPDATE sessions SET has_cached_diffs = 1 WHERE id = ?");
    updateQuery.addBindValue(sessionId);
    updateQuery.exec();
    
    sqlDb.commit();
    return true;
}

QList<CachedDiff> SessionRepository::getDiffs(const QString& sessionId)
{
    QList<CachedDiff> result;
    QSqlQuery query(m_db->database());
    
    query.prepare("SELECT patch, language, filename FROM cached_diffs WHERE session_id = ? ORDER BY order_index");
    query.addBindValue(sessionId);
    
    if (!query.exec()) {
        qWarning() << "Failed to get diffs:" << query.lastError().text();
        return result;
    }
    
    while (query.next()) {
        CachedDiff diff;
        diff.patch = query.value(0).toString();
        QString lang = query.value(1).toString();
        QString file = query.value(2).toString();
        
        if (!lang.isEmpty()) diff.language = lang;
        if (!file.isEmpty()) diff.filename = file;
        
        result.append(diff);
    }
    
    return result;
}

bool SessionRepository::hasDiffs(const QString& sessionId)
{
    QSqlQuery query(m_db->database());
    query.prepare("SELECT 1 FROM cached_diffs WHERE session_id = ? LIMIT 1");
    query.addBindValue(sessionId);
    
    if (!query.exec()) {
        return false;
    }
    
    return query.next();
}

bool SessionRepository::deleteDiffs(const QString& sessionId)
{
    QSqlQuery query(m_db->database());
    query.prepare("DELETE FROM cached_diffs WHERE session_id = ?");
    query.addBindValue(sessionId);
    
    if (!query.exec()) {
        qWarning() << "Failed to delete diffs:" << query.lastError().text();
        return false;
    }
    
    QSqlQuery updateQuery(m_db->database());
    updateQuery.prepare("UPDATE sessions SET has_cached_diffs = 0 WHERE id = ?");
    updateQuery.addBindValue(sessionId);
    updateQuery.exec();
    
    return true;
}

QString SessionRepository::sessionToJson(const Session& session)
{
    QJsonObject obj;
    obj["name"] = session.name;
    obj["id"] = session.id;
    obj["prompt"] = session.prompt;
    obj["state"] = sessionStateToString(session.state);
    
    if (session.title) obj["title"] = *session.title;
    if (session.createTime) obj["createTime"] = *session.createTime;
    if (session.updateTime) obj["updateTime"] = *session.updateTime;
    if (session.url) obj["url"] = *session.url;
    if (session.automationMode) obj["automationMode"] = *session.automationMode;
    if (session.requirePlanApproval) obj["requirePlanApproval"] = *session.requirePlanApproval;
    
    if (session.sourceContext) {
        QJsonObject ctxObj;
        ctxObj["source"] = session.sourceContext->source;
        if (session.sourceContext->githubRepoContext) {
            QJsonObject ghObj;
            if (session.sourceContext->githubRepoContext->startingBranch) {
                ghObj["startingBranch"] = *session.sourceContext->githubRepoContext->startingBranch;
            }
            ctxObj["githubRepoContext"] = ghObj;
        }
        obj["sourceContext"] = ctxObj;
    }
    
    if (session.outputs && !session.outputs->isEmpty()) {
        QJsonArray outputsArr;
        for (const auto& output : *session.outputs) {
            QJsonObject outObj;
            if (output.pullRequest) {
                QJsonObject prObj;
                prObj["url"] = output.pullRequest->url;
                prObj["title"] = output.pullRequest->title;
                prObj["description"] = output.pullRequest->description;
                outObj["pullRequest"] = prObj;
            }
            outputsArr.append(outObj);
        }
        obj["outputs"] = outputsArr;
    }
    
    return QJsonDocument(obj).toJson(QJsonDocument::Compact);
}

std::optional<Session> SessionRepository::jsonToSession(const QString& json)
{
    QJsonParseError error;
    QJsonDocument doc = QJsonDocument::fromJson(json.toUtf8(), &error);
    
    if (error.error != QJsonParseError::NoError) {
        qWarning() << "JSON parse error:" << error.errorString();
        return std::nullopt;
    }
    
    if (!doc.isObject()) {
        return std::nullopt;
    }
    
    QJsonObject obj = doc.object();
    Session session;
    
    session.name = obj["name"].toString();
    session.id = obj["id"].toString();
    session.prompt = obj["prompt"].toString();
    session.state = stringToSessionState(obj["state"].toString());
    
    if (obj.contains("title")) session.title = obj["title"].toString();
    if (obj.contains("createTime")) session.createTime = obj["createTime"].toString();
    if (obj.contains("updateTime")) session.updateTime = obj["updateTime"].toString();
    if (obj.contains("url")) session.url = obj["url"].toString();
    if (obj.contains("automationMode")) session.automationMode = obj["automationMode"].toString();
    if (obj.contains("requirePlanApproval")) session.requirePlanApproval = obj["requirePlanApproval"].toBool();
    
    if (obj.contains("sourceContext")) {
        QJsonObject ctxObj = obj["sourceContext"].toObject();
        SourceContext ctx;
        ctx.source = ctxObj["source"].toString();
        
        if (ctxObj.contains("githubRepoContext")) {
            QJsonObject ghObj = ctxObj["githubRepoContext"].toObject();
            GitHubRepoContext ghCtx;
            if (ghObj.contains("startingBranch")) {
                ghCtx.startingBranch = ghObj["startingBranch"].toString();
            }
            ctx.githubRepoContext = ghCtx;
        }
        session.sourceContext = ctx;
    }
    
    if (obj.contains("outputs")) {
        QList<SessionOutput> outputs;
        QJsonArray arr = obj["outputs"].toArray();
        for (const auto& val : arr) {
            QJsonObject outObj = val.toObject();
            SessionOutput output;
            if (outObj.contains("pullRequest")) {
                QJsonObject prObj = outObj["pullRequest"].toObject();
                PullRequest pr;
                pr.url = prObj["url"].toString();
                pr.title = prObj["title"].toString();
                pr.description = prObj["description"].toString();
                output.pullRequest = pr;
            }
            outputs.append(output);
        }
        session.outputs = outputs;
    }
    
    return session;
}

QString SessionRepository::sessionStateToString(SessionState state)
{
    switch (state) {
        case SessionState::Unspecified: return "STATE_UNSPECIFIED";
        case SessionState::Queued: return "QUEUED";
        case SessionState::Planning: return "PLANNING";
        case SessionState::AwaitingPlanApproval: return "AWAITING_PLAN_APPROVAL";
        case SessionState::AwaitingUserFeedback: return "AWAITING_USER_FEEDBACK";
        case SessionState::InProgress: return "IN_PROGRESS";
        case SessionState::Paused: return "PAUSED";
        case SessionState::Failed: return "FAILED";
        case SessionState::Completed: return "COMPLETED";
        case SessionState::CompletedUnknown: return "COMPLETED_UNKNOWN";
        default: return "STATE_UNSPECIFIED";
    }
}

SessionState SessionRepository::stringToSessionState(const QString& str)
{
    if (str == "QUEUED") return SessionState::Queued;
    if (str == "PLANNING") return SessionState::Planning;
    if (str == "AWAITING_PLAN_APPROVAL") return SessionState::AwaitingPlanApproval;
    if (str == "AWAITING_USER_FEEDBACK") return SessionState::AwaitingUserFeedback;
    if (str == "IN_PROGRESS") return SessionState::InProgress;
    if (str == "PAUSED") return SessionState::Paused;
    if (str == "FAILED") return SessionState::Failed;
    if (str == "COMPLETED") return SessionState::Completed;
    if (str == "COMPLETED_UNKNOWN") return SessionState::CompletedUnknown;
    return SessionState::Unspecified;
}

int SessionRepository::cachedSessionCount() const
{
    QSqlQuery query(m_db->database());
    if (!query.exec("SELECT COUNT(*) FROM sessions") || !query.next()) {
        return 0;
    }
    return query.value(0).toInt();
}

bool SessionRepository::clearAllCachedData()
{
    QSqlDatabase sqlDb = m_db->database();
    sqlDb.transaction();
    
    QSqlQuery diffsQuery(sqlDb);
    if (!diffsQuery.exec("DELETE FROM cached_diffs")) {
        qWarning() << "Failed to clear cached diffs:" << diffsQuery.lastError().text();
        sqlDb.rollback();
        return false;
    }
    
    QSqlQuery sessionsQuery(sqlDb);
    if (!sessionsQuery.exec("DELETE FROM sessions")) {
        qWarning() << "Failed to clear sessions:" << sessionsQuery.lastError().text();
        sqlDb.rollback();
        return false;
    }
    
    sqlDb.commit();
    emit sessionsReloaded();
    return true;
}

}
