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

// Cached diff data for storage
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
    
    // Client-side only property to track when the session was viewed after completion
    std::optional<QDateTime> viewedPostCompletionAt;
    
    // Client-side tracking of local merge timestamp
    std::optional<QDateTime> mergedLocallyAt;
    
    // Cached git statistics summary (e.g., "+50/-30 lines")
    std::optional<QString> cachedGitStatsSummary;
    
    // Cached diff data for display
    std::optional<QList<CachedDiff>> cachedLatestDiffs;
    
    // Timestamp for cache staleness checking
    std::optional<QString> cachedGitStatsUpdateTime;
    
    // Flag indicating if diffs are cached (fast lookup)
    bool hasCachedDiffsFlag = false;
    
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
    
    /// Returns true if this session has been viewed after completion or is over a day old
    bool isViewed() const {
        // Explicitly viewed post-completion
        if (viewedPostCompletionAt.has_value()) return true;
        // Treat sessions over a day old as viewed (don't show unviewed indicator)
        if (updateTime.has_value()) {
            QDateTime updateDateTime = QDateTime::fromString(updateTime.value(), Qt::ISODate);
            if (updateDateTime.isValid() && updateDateTime.secsTo(QDateTime::currentDateTime()) > 86400) {
                return true;
            }
        }
        return false;
    }
    
    /// Returns true if this session is completed (or completedUnknown) but has not been viewed yet
    bool isUnviewedCompleted() const {
        return (state == SessionState::Completed || state == SessionState::CompletedUnknown) && !isViewed();
    }
    
    /// Returns true if this session was merged locally
    bool isMergedLocally() const {
        return mergedLocallyAt.has_value();
    }
    
    /// Returns cached git stats summary or empty string
    QString gitStatsSummary() const {
        return cachedGitStatsSummary.value_or(QString());
    }
    
    /// Returns true if diffs are available (from flag or cached data)
    bool hasDiffsAvailable() const {
        return hasCachedDiffsFlag || 
               (cachedLatestDiffs.has_value() && !cachedLatestDiffs->isEmpty());
    }
    
    /// Returns seconds since last update, or -1 if unknown
    qint64 timeSinceLastUpdate() const {
        if (!updateTime.has_value()) return -1;
        QDateTime updateDateTime = QDateTime::fromString(updateTime.value(), Qt::ISODate);
        if (!updateDateTime.isValid()) return -1;
        return updateDateTime.secsTo(QDateTime::currentDateTime());
    }
    
    /// Returns true if this is an active session that hasn't been updated in a while (stale)
    bool isStaleActive() const {
        if (!isActive()) return false;
        qint64 elapsed = timeSinceLastUpdate();
        // Consider stale if no update for 10 minutes
        return elapsed > 0 && elapsed > 600;
    }
    
    /// Returns true if we have any cached git stats
    bool hasCachedGitStats() const {
        return cachedGitStatsSummary.has_value() && !cachedGitStatsSummary->isEmpty();
    }
    
    /// Returns true if cached git stats are stale (session updated since computation)
    bool areCachedGitStatsStale() const {
        if (!cachedGitStatsUpdateTime.has_value()) return true;
        QString currentTime = updateTime.value_or(createTime.value_or(QString()));
        return cachedGitStatsUpdateTime.value() != currentTime;
    }
    
    /// Returns true if this session needs activity fetching for git stats
    bool needsActivityFetchForStats() const {
        if (state == SessionState::Completed || state == SessionState::CompletedUnknown) {
            return areCachedGitStatsStale();
        }
        if (state == SessionState::Queued || state == SessionState::Planning || 
            state == SessionState::InProgress) {
            return true;
        }
        return areCachedGitStatsStale();
    }
    
    /// Returns the latest progress title from activities
    QString latestProgressTitle() const {
        if (!activities.has_value()) return QString();
        for (auto it = activities->rbegin(); it != activities->rend(); ++it) {
            if (it->progressUpdated.has_value() && it->progressUpdated->title.has_value()) {
                return it->progressUpdated->title.value();
            }
        }
        return QString();
    }
    
    // Static helper methods for git stats computation
    static QString computeGitStatsSummary(const QList<Activity>& activities);
    static QList<CachedDiff> computeLatestDiffs(const QList<Activity>& activities);
    static QList<QPair<QString, QString>> splitPatchByFile(const QString& patch);
    static QString detectLanguageFromPatch(const QString& patch);
    static QString detectLanguageFromPath(const QString& path);
    
    /// Updates cached diff data from activities
    void updateCachedDiffData() {
        qDebug() << "[updateCachedDiffData] Called, activities.has_value()=" << activities.has_value();
        if (activities.has_value()) {
            qDebug() << "[updateCachedDiffData] Activities count:" << activities.value().size();
            QString summary = computeGitStatsSummary(activities.value());
            if (!summary.isEmpty()) {
                cachedGitStatsSummary = summary;
                qDebug() << "[updateCachedDiffData] Git stats:" << summary;
            }
            QList<CachedDiff> diffs = computeLatestDiffs(activities.value());
            qDebug() << "[updateCachedDiffData] computeLatestDiffs returned" << diffs.size() << "diffs";
            if (!diffs.isEmpty()) {
                cachedLatestDiffs = diffs;
                hasCachedDiffsFlag = true;
                qDebug() << "[updateCachedDiffData] Cached" << diffs.size() << "diffs";
            } else {
                qDebug() << "[updateCachedDiffData] No diffs found in activities!";
            }
            cachedGitStatsUpdateTime = updateTime.value_or(createTime.value_or(QString()));
        } else {
            qDebug() << "[updateCachedDiffData] No activities to process!";
        }
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
    void getSources(const QString& pageToken = QString());
    void createSession(const Source& source, const QString& branchName, 
                       const QString& prompt);
    void sendMessage(const QString& sessionId, const QString& message);
    void requestAiSummary(const QString& sessionId, const QList<Activity>& activities);

    void setRetryDelayMs(int delayMs);
    void setMaxRetries(int maxRetries);

signals:
    void sessionsReceived(const QList<Session>& sessions,
                          const QString& nextPageToken);
    void sessionsUnchanged();  // Response unchanged (hash match)
    void sessionReceived(const Session& session);
    void activitiesReceived(const QString& sessionId, 
                            const QList<Activity>& activities);
    void activitiesUnchanged(const QString& sessionId);  // Response unchanged (hash match)
    void activitiesError(const QString& sessionId, const ApiError& error);
    void sourcesReceived(const QList<Source>& sources,
                         const QString& nextPageToken);
    void sessionCreated(const Session& session);
    void messageSent(const QString& sessionId, bool success);
    void aiSummaryReceived(const QString& sessionId, const QString& summary);
    void errorOccurred(const ApiError& error);

private slots:
    void onReplyFinished(QNetworkReply* reply);

private:
    enum class RequestType {
        GetSessions,
        GetSession,
        GetActivities,
        GetSources,
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
    Source parseSource(const QJsonObject& json) const;
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
    
    // Response hash cache for skipping unchanged responses
    QByteArray m_sessionResponseHash;
    QMap<QString, QByteArray> m_activityResponseHashes;  // sessionId -> hash

    // Gemini AI summary support
    RateLimiter m_geminiRateLimiter;
};

} // namespace jules

Q_DECLARE_METATYPE(jules::Session)
Q_DECLARE_METATYPE(jules::Activity)
Q_DECLARE_METATYPE(jules::Source)
Q_DECLARE_METATYPE(jules::ApiError)
Q_DECLARE_METATYPE(QList<jules::Session>)
Q_DECLARE_METATYPE(QList<jules::Activity>)
