#pragma once

#include <QObject>
#include <QString>
#include <QDateTime>
#include <QList>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QJsonObject>
#include <QJsonArray>
#include <QUrlQuery>

#include <memory>
#include <optional>

namespace jules {

// ============================================================================
// Enums
// ============================================================================

enum class SessionState {
    Unspecified,
    Queued,
    Planning,
    AwaitingPlanApproval,
    AwaitingUserFeedback,
    InProgress,
    Paused,
    Failed,
    Completed,
    CompletedUnknown
};

enum class ApiErrorType {
    None,
    Unauthorized,
    Forbidden,
    NotFound,
    ClientError,
    ServerError,
    NetworkError,
    ParseError,
    RateLimited
};

// ============================================================================
// Data Structures
// ============================================================================

struct GitHubBranch {
    QString displayName;
};

struct GitHubRepo {
    QString owner;
    QString repo;
    std::optional<bool> isPrivate;
    std::optional<GitHubBranch> defaultBranch;
    QList<GitHubBranch> branches;
};

struct Source {
    QString name;
    QString id;
    std::optional<GitHubRepo> githubRepo;
    
    QString displayName() const {
        QString result = name;
        return result.replace("sources/github/", "");
    }
};

struct GitHubRepoContext {
    std::optional<QString> startingBranch;
};

struct SourceContext {
    QString source;
    std::optional<GitHubRepoContext> githubRepoContext;
};

struct PullRequest {
    QString url;
    QString title;
    QString description;
};

struct SessionOutput {
    std::optional<PullRequest> pullRequest;
};

struct GitPatch {
    std::optional<QString> unidiffPatch;
    std::optional<QString> baseCommitId;
    std::optional<QString> suggestedCommitMessage;
};

struct ChangeSet {
    std::optional<QString> source;
    std::optional<GitPatch> gitPatch;
};

struct Media {
    QString data;
    QString mimeType;
};

struct BashOutput {
    std::optional<QString> command;
    std::optional<QString> output;
    std::optional<int> exitCode;
};

struct Artifact {
    std::optional<ChangeSet> changeSet;
    std::optional<Media> media;
    std::optional<BashOutput> bashOutput;
};

struct ProgressUpdated {
    std::optional<QString> title;
    std::optional<QString> description;
};

struct AgentMessaged {
    QString agentMessage;
};

struct UserMessaged {
    QString userMessage;
};

struct PlanStep {
    QString id;
    std::optional<QString> title;
    std::optional<QString> description;
    std::optional<int> index;
};

struct Plan {
    QString id;
    QList<PlanStep> steps;
    std::optional<QString> createTime;
};

struct PlanGenerated {
    Plan plan;
};

struct PlanApproved {
    QString planId;
};

struct SessionCompleted {};

struct SessionFailed {
    std::optional<QString> reason;
};

struct Activity {
    QString name;
    QString id;
    std::optional<QString> title;
    std::optional<QString> description;
    std::optional<QString> createTime;
    QString originator;
    std::optional<QList<Artifact>> artifacts;
    
    std::optional<AgentMessaged> agentMessaged;
    std::optional<UserMessaged> userMessaged;
    std::optional<PlanGenerated> planGenerated;
    std::optional<PlanApproved> planApproved;
    std::optional<ProgressUpdated> progressUpdated;
    std::optional<SessionCompleted> sessionCompleted;
    std::optional<SessionFailed> sessionFailed;
    
    std::optional<QString> generatedDescription;
    std::optional<QString> generatedTitle;
};

struct Session {
    QString name;
    QString id;
    QString prompt;
    std::optional<SourceContext> sourceContext;
    std::optional<QString> title;
    std::optional<bool> requirePlanApproval;
    std::optional<QString> automationMode;
    std::optional<QString> createTime;
    std::optional<QString> updateTime;
    SessionState state = SessionState::Unspecified;
    std::optional<QString> url;
    std::optional<QList<SessionOutput>> outputs;
    
    std::optional<QList<Activity>> activities;
    std::optional<QDateTime> lastActivityPollTime;
    
    bool isActive() const {
        return state == SessionState::Queued ||
               state == SessionState::Planning ||
               state == SessionState::InProgress ||
               state == SessionState::AwaitingPlanApproval ||
               state == SessionState::AwaitingUserFeedback;
    }
    
    bool isTerminal() const {
        return state == SessionState::Completed ||
               state == SessionState::CompletedUnknown ||
               state == SessionState::Failed ||
               state == SessionState::Paused;
    }
};

struct ApiError {
    ApiErrorType type = ApiErrorType::None;
    int statusCode = 0;
    QString message;
    QString errorBody;
};

// ============================================================================
// Rate Limiter
// ============================================================================

class RateLimiter {
public:
    explicit RateLimiter(int maxRequests = 100, int windowDurationSecs = 60, 
                         int warningThreshold = 80);
    
    void recordRequest();
    int currentRequestCount();
    bool isApproachingLimit();
    bool isAtLimit();
    int remainingRequests();
    double secondsUntilSlotAvailable();
    
private:
    void pruneOldTimestamps();
    
    int m_maxRequests;
    int m_windowDurationSecs;
    int m_warningThreshold;
    QList<QDateTime> m_requestTimestamps;
};

// ============================================================================
// API Client
// ============================================================================

class JulesApiClient : public QObject {
    Q_OBJECT

public:
    explicit JulesApiClient(QNetworkAccessManager* networkManager = nullptr, 
                           QObject* parent = nullptr);
    ~JulesApiClient() override;

    void setApiKey(const QString& apiKey);
    QString apiKey() const;

    RateLimiter& rateLimiter();

    void getSessions(int pageSize = 10, const QString& pageToken = QString());
    void getSession(const QString& sessionId);
    void getActivities(const QString& sessionId);
    void createSession(const Source& source, const QString& branchName, 
                       const QString& prompt);
    void sendMessage(const QString& sessionId, const QString& message);

    void setRetryDelayMs(int delayMs);
    void setMaxRetries(int maxRetries);

signals:
    void sessionsReceived(const QList<Session>& sessions, 
                          const QString& nextPageToken);
    void sessionReceived(const Session& session);
    void activitiesReceived(const QString& sessionId, 
                            const QList<Activity>& activities);
    void sessionCreated(const Session& session);
    void messageSent(const QString& sessionId, bool success);
    void errorOccurred(const ApiError& error);

private slots:
    void onReplyFinished(QNetworkReply* reply);

private:
    enum class RequestType {
        GetSessions,
        GetSession,
        GetActivities,
        CreateSession,
        SendMessage
    };

    struct PendingRequest {
        RequestType type;
        QString sessionId;
        int retryCount = 0;
        QJsonObject requestBody;
        Source source;
        QString branchName;
        QString prompt;
        QString message;
    };

    void makeGetRequest(const QString& endpoint, RequestType type, 
                        const QString& sessionId = QString());
    void makePostRequest(const QString& endpoint, const QJsonObject& body,
                         RequestType type, const QString& sessionId = QString());

    QNetworkRequest createRequest(const QString& endpoint) const;
    void handleResponse(QNetworkReply* reply, const PendingRequest& request);
    void handleError(QNetworkReply* reply, const PendingRequest& request);
    void scheduleRetry(const PendingRequest& request);

    Session parseSession(const QJsonObject& json) const;
    Activity parseActivity(const QJsonObject& json) const;
    SessionState parseSessionState(const QString& stateStr) const;
    ApiError createApiError(QNetworkReply* reply, const QString& body = QString()) const;

    static const QString BASE_URL;
    int m_maxRetries = 3;
    int m_retryDelayMs = 1000;

    QString m_apiKey;
    QNetworkAccessManager* m_networkManager;
    bool m_ownsNetworkManager;
    RateLimiter m_rateLimiter;
    QMap<QNetworkReply*, PendingRequest> m_pendingRequests;
};

} // namespace jules

Q_DECLARE_METATYPE(jules::Session)
Q_DECLARE_METATYPE(jules::Activity)
Q_DECLARE_METATYPE(jules::Source)
Q_DECLARE_METATYPE(jules::ApiError)
Q_DECLARE_METATYPE(QList<jules::Session>)
Q_DECLARE_METATYPE(QList<jules::Activity>)
