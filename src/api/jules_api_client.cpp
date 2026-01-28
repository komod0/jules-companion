#include "api/jules_api_client.h"

#include <QJsonDocument>
#include <QTimer>
#include <QNetworkRequest>
#include <QDebug>

namespace jules {

const QString JulesApiClient::BASE_URL = 
    QStringLiteral("https://jules.googleapis.com/v1alpha");

RateLimiter::RateLimiter(int maxRequests, int windowDurationSecs, int warningThreshold)
    : m_maxRequests(maxRequests)
    , m_windowDurationSecs(windowDurationSecs)
    , m_warningThreshold(warningThreshold)
{
}

void RateLimiter::pruneOldTimestamps() {
    QDateTime cutoff = QDateTime::currentDateTime().addSecs(-m_windowDurationSecs);
    m_requestTimestamps.erase(
        std::remove_if(m_requestTimestamps.begin(), m_requestTimestamps.end(),
            [&cutoff](const QDateTime& ts) { return ts < cutoff; }),
        m_requestTimestamps.end()
    );
}

void RateLimiter::recordRequest() {
    pruneOldTimestamps();
    m_requestTimestamps.append(QDateTime::currentDateTime());
}

int RateLimiter::currentRequestCount() {
    pruneOldTimestamps();
    return m_requestTimestamps.size();
}

bool RateLimiter::isApproachingLimit() {
    return currentRequestCount() >= m_warningThreshold;
}

bool RateLimiter::isAtLimit() {
    return currentRequestCount() >= m_maxRequests;
}

int RateLimiter::remainingRequests() {
    return qMax(0, m_maxRequests - currentRequestCount());
}

double RateLimiter::secondsUntilSlotAvailable() {
    pruneOldTimestamps();
    if (m_requestTimestamps.isEmpty()) {
        return 0.0;
    }
    
    QDateTime oldestTimestamp = m_requestTimestamps.first();
    QDateTime expirationTime = oldestTimestamp.addSecs(m_windowDurationSecs);
    double waitTime = QDateTime::currentDateTime().msecsTo(expirationTime) / 1000.0;
    return qMax(0.0, waitTime);
}

JulesApiClient::JulesApiClient(QNetworkAccessManager* networkManager, QObject* parent)
    : QObject(parent)
    , m_networkManager(networkManager)
    , m_ownsNetworkManager(networkManager == nullptr)
    , m_rateLimiter(100, 60, 80)
{
    if (m_ownsNetworkManager) {
        m_networkManager = new QNetworkAccessManager(this);
    }
    
    connect(m_networkManager, &QNetworkAccessManager::finished,
            this, &JulesApiClient::onReplyFinished);

    qRegisterMetaType<Session>("Session");
    qRegisterMetaType<Activity>("Activity");
    qRegisterMetaType<Source>("Source");
    qRegisterMetaType<ApiError>("ApiError");
    qRegisterMetaType<QList<Session>>("QList<Session>");
    qRegisterMetaType<QList<Activity>>("QList<Activity>");
}

JulesApiClient::~JulesApiClient() {
    if (m_ownsNetworkManager && m_networkManager) {
        delete m_networkManager;
    }
}

void JulesApiClient::setApiKey(const QString& apiKey) {
    m_apiKey = apiKey;
}

QString JulesApiClient::apiKey() const {
    return m_apiKey;
}

RateLimiter& JulesApiClient::rateLimiter() {
    return m_rateLimiter;
}

void JulesApiClient::setRetryDelayMs(int delayMs) {
    m_retryDelayMs = delayMs;
}

void JulesApiClient::setMaxRetries(int maxRetries) {
    m_maxRetries = maxRetries;
}

QNetworkRequest JulesApiClient::createRequest(const QString& endpoint) const {
    QUrl url(BASE_URL + endpoint);
    QNetworkRequest request(url);
    
    request.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    request.setRawHeader("x-api-key", m_apiKey.toUtf8());
    
    return request;
}

void JulesApiClient::makeGetRequest(const QString& endpoint, RequestType type, 
                                     const QString& sessionId) {
    QNetworkRequest request = createRequest(endpoint);
    QNetworkReply* reply = m_networkManager->get(request);
    
    PendingRequest pending;
    pending.type = type;
    pending.sessionId = sessionId;
    pending.retryCount = 0;
    m_pendingRequests[reply] = pending;
    
    m_rateLimiter.recordRequest();
}

void JulesApiClient::makePostRequest(const QString& endpoint, const QJsonObject& body,
                                      RequestType type, const QString& sessionId) {
    QNetworkRequest request = createRequest(endpoint);
    QByteArray jsonData = QJsonDocument(body).toJson();
    QNetworkReply* reply = m_networkManager->post(request, jsonData);
    
    PendingRequest pending;
    pending.type = type;
    pending.sessionId = sessionId;
    pending.requestBody = body;
    pending.retryCount = 0;
    m_pendingRequests[reply] = pending;
    
    m_rateLimiter.recordRequest();
}

void JulesApiClient::getSessions(int pageSize, const QString& pageToken) {
    QString endpoint = QStringLiteral("/sessions");
    QUrlQuery query;
    query.addQueryItem("pageSize", QString::number(pageSize));
    if (!pageToken.isEmpty()) {
        query.addQueryItem("pageToken", pageToken);
    }
    
    QUrl url(BASE_URL + endpoint);
    url.setQuery(query);
    
    QNetworkRequest request;
    request.setUrl(url);
    request.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    request.setRawHeader("x-api-key", m_apiKey.toUtf8());
    
    QNetworkReply* reply = m_networkManager->get(request);
    
    PendingRequest pending;
    pending.type = RequestType::GetSessions;
    pending.retryCount = 0;
    m_pendingRequests[reply] = pending;
    
    m_rateLimiter.recordRequest();
}

void JulesApiClient::getSession(const QString& sessionId) {
    QString endpoint = QStringLiteral("/sessions/") + sessionId;
    makeGetRequest(endpoint, RequestType::GetSession, sessionId);
}

void JulesApiClient::getActivities(const QString& sessionId) {
    QString endpoint = QStringLiteral("/sessions/") + sessionId + "/activities";
    makeGetRequest(endpoint, RequestType::GetActivities, sessionId);
}

void JulesApiClient::createSession(const Source& source, const QString& branchName, 
                                    const QString& prompt) {
    QJsonObject body;
    body["prompt"] = prompt;
    
    QJsonObject sourceContext;
    sourceContext["source"] = source.name;
    
    QJsonObject githubRepoContext;
    githubRepoContext["startingBranch"] = branchName;
    sourceContext["githubRepoContext"] = githubRepoContext;
    
    body["sourceContext"] = sourceContext;
    body["automationMode"] = "AUTO_CREATE_PR";
    body["requirePlanApproval"] = false;
    
    QString endpoint = QStringLiteral("/sessions");

    QNetworkRequest request = createRequest(endpoint);
    QByteArray jsonData = QJsonDocument(body).toJson();
    QNetworkReply* reply = m_networkManager->post(request, jsonData);
    
    PendingRequest pending;
    pending.type = RequestType::CreateSession;
    pending.requestBody = body;
    pending.source = source;
    pending.branchName = branchName;
    pending.prompt = prompt;
    pending.retryCount = 0;
    m_pendingRequests[reply] = pending;
    
    m_rateLimiter.recordRequest();
}

void JulesApiClient::sendMessage(const QString& sessionId, const QString& message) {
    QString endpoint = QStringLiteral("/sessions/") + sessionId + ":sendMessage";
    
    QJsonObject body;
    body["prompt"] = message;
    
    QNetworkRequest request = createRequest(endpoint);
    QByteArray jsonData = QJsonDocument(body).toJson();
    QNetworkReply* reply = m_networkManager->post(request, jsonData);
    
    PendingRequest pending;
    pending.type = RequestType::SendMessage;
    pending.sessionId = sessionId;
    pending.message = message;
    pending.requestBody = body;
    pending.retryCount = 0;
    m_pendingRequests[reply] = pending;
    
    m_rateLimiter.recordRequest();
}

void JulesApiClient::onReplyFinished(QNetworkReply* reply) {
    if (!m_pendingRequests.contains(reply)) {
        reply->deleteLater();
        return;
    }
    
    PendingRequest request = m_pendingRequests.take(reply);
    
    if (reply->error() != QNetworkReply::NoError) {
        handleError(reply, request);
    } else {
        handleResponse(reply, request);
    }
    
    reply->deleteLater();
}

void JulesApiClient::handleResponse(QNetworkReply* reply, const PendingRequest& request) {
    int statusCode = reply->attribute(
        QNetworkRequest::HttpStatusCodeAttribute).toInt();
    QByteArray responseData = reply->readAll();
    
    if (statusCode < 200 || statusCode >= 300) {
        ApiError error = createApiError(reply, QString::fromUtf8(responseData));
        
        bool shouldRetry = (statusCode >= 500 || statusCode == 429) && 
                           request.retryCount < m_maxRetries;
        
        if (shouldRetry) {
            PendingRequest retryRequest = request;
            retryRequest.retryCount++;
            scheduleRetry(retryRequest);
        } else {
            emit errorOccurred(error);
        }
        return;
    }
    
    QJsonParseError parseError;
    QJsonDocument doc = QJsonDocument::fromJson(responseData, &parseError);
    
    if (parseError.error != QJsonParseError::NoError) {
        ApiError error;
        error.type = ApiErrorType::ParseError;
        error.message = parseError.errorString();
        emit errorOccurred(error);
        return;
    }
    
    QJsonObject json = doc.object();
    
    switch (request.type) {
        case RequestType::GetSessions: {
            QList<Session> sessions;
            QJsonArray sessionsArray = json["sessions"].toArray();
            for (const QJsonValue& val : sessionsArray) {
                sessions.append(parseSession(val.toObject()));
            }
            QString nextPageToken = json["nextPageToken"].toString();
            emit sessionsReceived(sessions, nextPageToken);
            break;
        }
        
        case RequestType::GetSession: {
            Session session = parseSession(json);
            emit sessionReceived(session);
            break;
        }
        
        case RequestType::GetActivities: {
            QList<Activity> activities;
            QJsonArray activitiesArray = json["activities"].toArray();
            for (const QJsonValue& val : activitiesArray) {
                activities.append(parseActivity(val.toObject()));
            }
            emit activitiesReceived(request.sessionId, activities);
            break;
        }
        
        case RequestType::CreateSession: {
            Session session = parseSession(json);
            emit sessionCreated(session);
            break;
        }
        
        case RequestType::SendMessage: {
            emit messageSent(request.sessionId, true);
            break;
        }
    }
}

void JulesApiClient::handleError(QNetworkReply* reply, const PendingRequest& request) {
    ApiError error = createApiError(reply);
    
    bool isRetryable = (error.type == ApiErrorType::ServerError || 
                        error.type == ApiErrorType::NetworkError ||
                        error.type == ApiErrorType::RateLimited) &&
                       request.retryCount < m_maxRetries;
    
    if (isRetryable) {
        PendingRequest retryRequest = request;
        retryRequest.retryCount++;
        scheduleRetry(retryRequest);
    } else {
        emit errorOccurred(error);
    }
}

void JulesApiClient::scheduleRetry(const PendingRequest& request) {
    int delay = m_retryDelayMs * (1 << request.retryCount);
    
    QTimer::singleShot(delay, this, [this, request]() {
        QString endpoint;
        QNetworkReply* reply = nullptr;
        PendingRequest newRequest = request;
        
        switch (request.type) {
            case RequestType::GetSessions:
                endpoint = QStringLiteral("/sessions");
                reply = m_networkManager->get(createRequest(endpoint));
                break;
            case RequestType::GetSession:
                endpoint = QStringLiteral("/sessions/") + request.sessionId;
                reply = m_networkManager->get(createRequest(endpoint));
                break;
            case RequestType::GetActivities:
                endpoint = QStringLiteral("/sessions/") + request.sessionId + "/activities";
                reply = m_networkManager->get(createRequest(endpoint));
                break;
            case RequestType::CreateSession:
                endpoint = QStringLiteral("/sessions");
                reply = m_networkManager->post(createRequest(endpoint), 
                    QJsonDocument(request.requestBody).toJson());
                break;
            case RequestType::SendMessage:
                endpoint = QStringLiteral("/sessions/") + request.sessionId + ":sendMessage";
                reply = m_networkManager->post(createRequest(endpoint),
                    QJsonDocument(request.requestBody).toJson());
                break;
        }
        
        if (reply) {
            m_pendingRequests[reply] = newRequest;
            m_rateLimiter.recordRequest();
        }
    });
}

ApiError JulesApiClient::createApiError(QNetworkReply* reply, const QString& body) const {
    ApiError error;
    
    int statusCode = reply->attribute(
        QNetworkRequest::HttpStatusCodeAttribute).toInt();
    error.statusCode = statusCode;
    error.errorBody = body.isEmpty() ? QString::fromUtf8(reply->readAll()) : body;
    
    if (reply->error() != QNetworkReply::NoError && statusCode == 0) {
        error.type = ApiErrorType::NetworkError;
        error.message = reply->errorString();
        return error;
    }
    
    switch (statusCode) {
        case 401:
            error.type = ApiErrorType::Unauthorized;
            error.message = QStringLiteral(
                "Your API key is invalid or has expired. "
                "Please update your API key in Settings.");
            break;
        case 403:
            error.type = ApiErrorType::Forbidden;
            error.message = QStringLiteral(
                "Access denied. You don't have permission to access this resource.");
            break;
        case 404:
            error.type = ApiErrorType::NotFound;
            error.message = QStringLiteral("The requested resource was not found.");
            break;
        case 429:
            error.type = ApiErrorType::RateLimited;
            error.message = QStringLiteral("Rate limit exceeded. Please try again later.");
            break;
        default:
            if (statusCode >= 400 && statusCode < 500) {
                error.type = ApiErrorType::ClientError;
                error.message = QString("Request failed (Error %1): %2")
                    .arg(statusCode).arg(error.errorBody);
            } else if (statusCode >= 500) {
                error.type = ApiErrorType::ServerError;
                error.message = QString("Server error (Error %1): %2")
                    .arg(statusCode).arg(error.errorBody);
            }
            break;
    }
    
    return error;
}

Session JulesApiClient::parseSession(const QJsonObject& json) const {
    Session session;
    session.name = json["name"].toString();
    session.id = json["id"].toString();
    session.prompt = json["prompt"].toString();
    session.state = parseSessionState(json["state"].toString());
    
    if (json.contains("title") && !json["title"].isNull()) {
        session.title = json["title"].toString();
    }
    
    if (json.contains("createTime") && !json["createTime"].isNull()) {
        session.createTime = json["createTime"].toString();
    }
    
    if (json.contains("updateTime") && !json["updateTime"].isNull()) {
        session.updateTime = json["updateTime"].toString();
    }
    
    if (json.contains("url") && !json["url"].isNull()) {
        session.url = json["url"].toString();
    }
    
    if (json.contains("requirePlanApproval")) {
        session.requirePlanApproval = json["requirePlanApproval"].toBool();
    }
    
    if (json.contains("automationMode") && !json["automationMode"].isNull()) {
        session.automationMode = json["automationMode"].toString();
    }
    
    if (json.contains("sourceContext") && json["sourceContext"].isObject()) {
        QJsonObject scJson = json["sourceContext"].toObject();
        SourceContext sc;
        sc.source = scJson["source"].toString();
        
        if (scJson.contains("githubRepoContext") && scJson["githubRepoContext"].isObject()) {
            QJsonObject grcJson = scJson["githubRepoContext"].toObject();
            GitHubRepoContext grc;
            if (grcJson.contains("startingBranch")) {
                grc.startingBranch = grcJson["startingBranch"].toString();
            }
            sc.githubRepoContext = grc;
        }
        
        session.sourceContext = sc;
    }
    
    if (json.contains("outputs") && json["outputs"].isArray()) {
        QList<SessionOutput> outputs;
        QJsonArray outputsArray = json["outputs"].toArray();
        for (const QJsonValue& val : outputsArray) {
            QJsonObject outJson = val.toObject();
            SessionOutput output;
            
            if (outJson.contains("pullRequest") && outJson["pullRequest"].isObject()) {
                QJsonObject prJson = outJson["pullRequest"].toObject();
                PullRequest pr;
                pr.url = prJson["url"].toString();
                pr.title = prJson["title"].toString();
                pr.description = prJson["description"].toString();
                output.pullRequest = pr;
            }
            
            outputs.append(output);
        }
        session.outputs = outputs;
    }
    
    return session;
}

Activity JulesApiClient::parseActivity(const QJsonObject& json) const {
    Activity activity;
    activity.name = json["name"].toString();
    activity.id = json["id"].toString();
    activity.originator = json["originator"].toString();
    
    if (json.contains("title") && !json["title"].isNull()) {
        activity.title = json["title"].toString();
    }
    
    if (json.contains("description") && !json["description"].isNull()) {
        activity.description = json["description"].toString();
    }
    
    if (json.contains("createTime") && !json["createTime"].isNull()) {
        activity.createTime = json["createTime"].toString();
    }
    
    if (json.contains("progressUpdated") && json["progressUpdated"].isObject()) {
        QJsonObject puJson = json["progressUpdated"].toObject();
        ProgressUpdated pu;
        if (puJson.contains("title")) {
            pu.title = puJson["title"].toString();
        }
        if (puJson.contains("description")) {
            pu.description = puJson["description"].toString();
        }
        activity.progressUpdated = pu;
    }
    
    if (json.contains("agentMessaged") && json["agentMessaged"].isObject()) {
        QJsonObject amJson = json["agentMessaged"].toObject();
        AgentMessaged am;
        am.agentMessage = amJson["agentMessage"].toString();
        activity.agentMessaged = am;
    }
    
    if (json.contains("userMessaged") && json["userMessaged"].isObject()) {
        QJsonObject umJson = json["userMessaged"].toObject();
        UserMessaged um;
        um.userMessage = umJson["userMessage"].toString();
        activity.userMessaged = um;
    }
    
    if (json.contains("planGenerated") && json["planGenerated"].isObject()) {
        QJsonObject pgJson = json["planGenerated"].toObject();
        PlanGenerated pg;
        
        if (pgJson.contains("plan") && pgJson["plan"].isObject()) {
            QJsonObject planJson = pgJson["plan"].toObject();
            Plan plan;
            plan.id = planJson["id"].toString();
            
            if (planJson.contains("createTime")) {
                plan.createTime = planJson["createTime"].toString();
            }
            
            if (planJson.contains("steps") && planJson["steps"].isArray()) {
                QJsonArray stepsArray = planJson["steps"].toArray();
                for (const QJsonValue& val : stepsArray) {
                    QJsonObject stepJson = val.toObject();
                    PlanStep step;
                    step.id = stepJson["id"].toString();
                    if (stepJson.contains("title")) {
                        step.title = stepJson["title"].toString();
                    }
                    if (stepJson.contains("description")) {
                        step.description = stepJson["description"].toString();
                    }
                    if (stepJson.contains("index")) {
                        step.index = stepJson["index"].toInt();
                    }
                    plan.steps.append(step);
                }
            }
            
            pg.plan = plan;
        }
        
        activity.planGenerated = pg;
    }
    
    if (json.contains("planApproved") && json["planApproved"].isObject()) {
        QJsonObject paJson = json["planApproved"].toObject();
        PlanApproved pa;
        pa.planId = paJson["planId"].toString();
        activity.planApproved = pa;
    }
    
    if (json.contains("sessionCompleted") && json["sessionCompleted"].isObject()) {
        activity.sessionCompleted = SessionCompleted{};
    }
    
    if (json.contains("sessionFailed") && json["sessionFailed"].isObject()) {
        QJsonObject sfJson = json["sessionFailed"].toObject();
        SessionFailed sf;
        if (sfJson.contains("reason")) {
            sf.reason = sfJson["reason"].toString();
        }
        activity.sessionFailed = sf;
    }
    
    if (json.contains("artifacts") && json["artifacts"].isArray()) {
        QList<Artifact> artifacts;
        QJsonArray artifactsArray = json["artifacts"].toArray();
        
        for (const QJsonValue& val : artifactsArray) {
            QJsonObject artJson = val.toObject();
            Artifact artifact;
            
            if (artJson.contains("changeSet") && artJson["changeSet"].isObject()) {
                QJsonObject csJson = artJson["changeSet"].toObject();
                ChangeSet cs;
                
                if (csJson.contains("source")) {
                    cs.source = csJson["source"].toString();
                }
                
                if (csJson.contains("gitPatch") && csJson["gitPatch"].isObject()) {
                    QJsonObject gpJson = csJson["gitPatch"].toObject();
                    GitPatch gp;
                    
                    if (gpJson.contains("unidiffPatch")) {
                        gp.unidiffPatch = gpJson["unidiffPatch"].toString();
                    }
                    if (gpJson.contains("baseCommitId")) {
                        gp.baseCommitId = gpJson["baseCommitId"].toString();
                    }
                    if (gpJson.contains("suggestedCommitMessage")) {
                        gp.suggestedCommitMessage = gpJson["suggestedCommitMessage"].toString();
                    }
                    
                    cs.gitPatch = gp;
                }
                
                artifact.changeSet = cs;
            }
            
            if (artJson.contains("media") && artJson["media"].isObject()) {
                QJsonObject mJson = artJson["media"].toObject();
                Media m;
                m.data = mJson["data"].toString();
                m.mimeType = mJson["mimeType"].toString();
                artifact.media = m;
            }
            
            if (artJson.contains("bashOutput") && artJson["bashOutput"].isObject()) {
                QJsonObject boJson = artJson["bashOutput"].toObject();
                BashOutput bo;
                
                if (boJson.contains("command")) {
                    bo.command = boJson["command"].toString();
                }
                if (boJson.contains("output")) {
                    bo.output = boJson["output"].toString();
                }
                if (boJson.contains("exitCode")) {
                    bo.exitCode = boJson["exitCode"].toInt();
                }
                
                artifact.bashOutput = bo;
            }
            
            artifacts.append(artifact);
        }
        
        activity.artifacts = artifacts;
    }
    
    return activity;
}

SessionState JulesApiClient::parseSessionState(const QString& stateStr) const {
    static const QMap<QString, SessionState> stateMap = {
        {"STATE_UNSPECIFIED", SessionState::Unspecified},
        {"QUEUED", SessionState::Queued},
        {"PLANNING", SessionState::Planning},
        {"AWAITING_PLAN_APPROVAL", SessionState::AwaitingPlanApproval},
        {"AWAITING_USER_FEEDBACK", SessionState::AwaitingUserFeedback},
        {"IN_PROGRESS", SessionState::InProgress},
        {"PAUSED", SessionState::Paused},
        {"FAILED", SessionState::Failed},
        {"COMPLETED", SessionState::Completed},
        {"COMPLETED_UNKNOWN", SessionState::CompletedUnknown}
    };
    
    return stateMap.value(stateStr, SessionState::Unspecified);
}

} // namespace jules
