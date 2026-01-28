/**
 * @file api_client_test.cpp
 * @brief Unit tests for JulesApiClient with mock network
 * 
 * TDD approach: These tests define the expected API client behavior.
 */

#include <gtest/gtest.h>
#include <QCoreApplication>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QSignalSpy>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QTimer>
#include <QBuffer>

#include "api/jules_api_client.h"

namespace jules {
namespace test {

// ============================================================================
// Mock Network Reply
// ============================================================================

/**
 * @brief Mock QNetworkReply for testing
 */
class MockNetworkReply : public QNetworkReply {
    Q_OBJECT
public:
    explicit MockNetworkReply(QObject* parent = nullptr)
        : QNetworkReply(parent)
        , m_offset(0)
    {
        open(QIODevice::ReadOnly);
    }

    void initReply(QNetworkAccessManager::Operation op, const QNetworkRequest& req) {
        setRequest(req);
        setOperation(op);
        setUrl(req.url());
    }

    void setHttpStatusCode(int code) {
        setAttribute(QNetworkRequest::HttpStatusCodeAttribute, code);
    }

    void setResponseData(const QByteArray& data) {
        m_data = data;
        m_offset = 0;
    }

    void setNetworkError(QNetworkReply::NetworkError error, const QString& errorString = QString()) {
        setError(error, errorString);
    }

    void finish() {
        setFinished(true);
        emit finished();
    }

    void abort() override {
        close();
    }

    qint64 bytesAvailable() const override {
        return m_data.size() - m_offset + QIODevice::bytesAvailable();
    }

    bool isSequential() const override {
        return true;
    }

protected:
    qint64 readData(char* data, qint64 maxlen) override {
        if (m_offset >= m_data.size()) {
            return -1;
        }
        qint64 count = qMin(maxlen, static_cast<qint64>(m_data.size() - m_offset));
        memcpy(data, m_data.constData() + m_offset, count);
        m_offset += count;
        return count;
    }

private:
    QByteArray m_data;
    qint64 m_offset;
};

// ============================================================================
// Mock Network Access Manager
// ============================================================================

/**
 * @brief Mock QNetworkAccessManager for testing API client
 */
class MockNetworkAccessManager : public QNetworkAccessManager {
    Q_OBJECT
public:
    explicit MockNetworkAccessManager(QObject* parent = nullptr)
        : QNetworkAccessManager(parent)
        , m_nextStatusCode(200)
        , m_nextError(QNetworkReply::NoError)
        , m_finishDelay(0)
    {}

    void setNextResponse(int statusCode, const QByteArray& data) {
        m_nextStatusCode = statusCode;
        m_nextResponseData = data;
        m_nextError = QNetworkReply::NoError;
    }

    void setNextResponse(int statusCode, const QJsonObject& json) {
        setNextResponse(statusCode, QJsonDocument(json).toJson());
    }

    void setNextResponse(int statusCode, const QJsonArray& json) {
        setNextResponse(statusCode, QJsonDocument(json).toJson());
    }

    void setNextError(QNetworkReply::NetworkError error, const QString& errorString = QString()) {
        m_nextError = error;
        m_nextErrorString = errorString;
        m_nextStatusCode = 0;
    }

    void setFinishDelay(int ms) {
        m_finishDelay = ms;
    }

    QNetworkRequest lastRequest() const { return m_lastRequest; }
    QByteArray lastRequestBody() const { return m_lastRequestBody; }
    int requestCount() const { return m_requestCount; }

    void resetRequestCount() { m_requestCount = 0; }

protected:
    QNetworkReply* createRequest(Operation op, const QNetworkRequest& request, 
                                  QIODevice* outgoingData = nullptr) override {
        m_lastRequest = request;
        m_lastOperation = op;
        m_requestCount++;
        
        if (outgoingData) {
            m_lastRequestBody = outgoingData->readAll();
        } else {
            m_lastRequestBody.clear();
        }

        auto* reply = new MockNetworkReply(this);
        reply->initReply(op, request);

        if (m_nextError != QNetworkReply::NoError) {
            reply->setNetworkError(m_nextError, m_nextErrorString);
        } else {
            reply->setHttpStatusCode(m_nextStatusCode);
            reply->setResponseData(m_nextResponseData);
        }

        connect(reply, &QNetworkReply::finished, this, [this, reply]() {
            emit finished(reply);
        });

        QTimer::singleShot(m_finishDelay, reply, &MockNetworkReply::finish);

        return reply;
    }

private:
    QNetworkRequest m_lastRequest;
    QByteArray m_lastRequestBody;
    Operation m_lastOperation;
    int m_nextStatusCode;
    QByteArray m_nextResponseData;
    QNetworkReply::NetworkError m_nextError;
    QString m_nextErrorString;
    int m_finishDelay;
    int m_requestCount = 0;
};

// ============================================================================
// Test Fixture
// ============================================================================

class JulesApiClientTest : public ::testing::Test {
protected:
    void SetUp() override {
        m_mockNetwork = new MockNetworkAccessManager();
        m_client = std::make_unique<JulesApiClient>(m_mockNetwork);
        m_client->setApiKey("test-api-key-12345");
        m_client->setRetryDelayMs(10);
    }

    void TearDown() override {
        m_client.reset();
        // m_mockNetwork is owned by m_client and will be deleted
    }

    // Helper to process Qt events
    void processEvents(int timeoutMs = 100) {
        QEventLoop loop;
        QTimer::singleShot(timeoutMs, &loop, &QEventLoop::quit);
        loop.exec();
    }

    MockNetworkAccessManager* m_mockNetwork;
    std::unique_ptr<JulesApiClient> m_client;
};

// ============================================================================
// Authentication Tests
// ============================================================================

TEST_F(JulesApiClientTest, SetsApiKeyHeader) {
    QJsonObject response;
    response["sessions"] = QJsonArray();
    m_mockNetwork->setNextResponse(200, response);

    m_client->getSessions();
    processEvents();

    // Verify x-api-key header is set
    QNetworkRequest req = m_mockNetwork->lastRequest();
    EXPECT_EQ(req.rawHeader("x-api-key"), QByteArray("test-api-key-12345"));
}

TEST_F(JulesApiClientTest, UsesCorrectBaseUrl) {
    QJsonObject response;
    response["sessions"] = QJsonArray();
    m_mockNetwork->setNextResponse(200, response);

    m_client->getSessions();
    processEvents();

    QUrl url = m_mockNetwork->lastRequest().url();
    EXPECT_EQ(url.scheme(), QString("https"));
    EXPECT_EQ(url.host(), QString("jules.googleapis.com"));
    EXPECT_TRUE(url.path().startsWith("/v1alpha"));
}

// ============================================================================
// getSessions Tests
// ============================================================================

TEST_F(JulesApiClientTest, GetSessionsReturnsEmptyList) {
    QJsonObject response;
    response["sessions"] = QJsonArray();
    m_mockNetwork->setNextResponse(200, response);

    QSignalSpy spy(m_client.get(), &JulesApiClient::sessionsReceived);
    m_client->getSessions();
    processEvents();

    ASSERT_EQ(spy.count(), 1);
    QList<Session> sessions = spy.at(0).at(0).value<QList<Session>>();
    EXPECT_TRUE(sessions.isEmpty());
}

TEST_F(JulesApiClientTest, GetSessionsParsesMultipleSessions) {
    QJsonArray sessionsArray;
    
    QJsonObject session1;
    session1["name"] = "sessions/abc123";
    session1["id"] = "abc123";
    session1["prompt"] = "Fix the bug";
    session1["state"] = "IN_PROGRESS";
    sessionsArray.append(session1);

    QJsonObject session2;
    session2["name"] = "sessions/def456";
    session2["id"] = "def456";
    session2["prompt"] = "Add feature";
    session2["state"] = "COMPLETED";
    sessionsArray.append(session2);

    QJsonObject response;
    response["sessions"] = sessionsArray;
    m_mockNetwork->setNextResponse(200, response);

    QSignalSpy spy(m_client.get(), &JulesApiClient::sessionsReceived);
    m_client->getSessions();
    processEvents();

    ASSERT_EQ(spy.count(), 1);
    QList<Session> sessions = spy.at(0).at(0).value<QList<Session>>();
    ASSERT_EQ(sessions.size(), 2);
    
    EXPECT_EQ(sessions[0].id, QString("abc123"));
    EXPECT_EQ(sessions[0].prompt, QString("Fix the bug"));
    EXPECT_EQ(sessions[0].state, SessionState::InProgress);
    
    EXPECT_EQ(sessions[1].id, QString("def456"));
    EXPECT_EQ(sessions[1].state, SessionState::Completed);
}

TEST_F(JulesApiClientTest, GetSessionsWithPagination) {
    QJsonObject response;
    response["sessions"] = QJsonArray();
    m_mockNetwork->setNextResponse(200, response);

    m_client->getSessions(20, "next-page-token");
    processEvents();

    QUrl url = m_mockNetwork->lastRequest().url();
    QUrlQuery query(url);
    EXPECT_EQ(query.queryItemValue("pageSize"), QString("20"));
    EXPECT_EQ(query.queryItemValue("pageToken"), QString("next-page-token"));
}

// ============================================================================
// getSession Tests
// ============================================================================

TEST_F(JulesApiClientTest, GetSessionById) {
    QJsonObject response;
    response["name"] = "sessions/test-session-id";
    response["id"] = "test-session-id";
    response["prompt"] = "Test prompt";
    response["state"] = "QUEUED";
    m_mockNetwork->setNextResponse(200, response);

    QSignalSpy spy(m_client.get(), &JulesApiClient::sessionReceived);
    m_client->getSession("test-session-id");
    processEvents();

    ASSERT_EQ(spy.count(), 1);
    Session session = spy.at(0).at(0).value<Session>();
    EXPECT_EQ(session.id, QString("test-session-id"));
    EXPECT_EQ(session.state, SessionState::Queued);
}

TEST_F(JulesApiClientTest, GetSessionUsesCorrectEndpoint) {
    QJsonObject response;
    response["id"] = "my-id";
    response["name"] = "sessions/my-id";
    response["prompt"] = "Test";
    response["state"] = "QUEUED";
    m_mockNetwork->setNextResponse(200, response);

    m_client->getSession("my-session-123");
    processEvents();

    QUrl url = m_mockNetwork->lastRequest().url();
    EXPECT_TRUE(url.path().endsWith("/sessions/my-session-123"));
}

// ============================================================================
// getActivities Tests
// ============================================================================

TEST_F(JulesApiClientTest, GetActivitiesForSession) {
    QJsonArray activitiesArray;
    
    QJsonObject activity1;
    activity1["name"] = "sessions/abc/activities/act1";
    activity1["id"] = "act1";
    activity1["originator"] = "agent";
    
    QJsonObject progressUpdated;
    progressUpdated["title"] = "Working on it";
    progressUpdated["description"] = "Making progress";
    activity1["progressUpdated"] = progressUpdated;
    activitiesArray.append(activity1);

    QJsonObject response;
    response["activities"] = activitiesArray;
    m_mockNetwork->setNextResponse(200, response);

    QSignalSpy spy(m_client.get(), &JulesApiClient::activitiesReceived);
    m_client->getActivities("abc");
    processEvents();

    ASSERT_EQ(spy.count(), 1);
    QString sessionId = spy.at(0).at(0).toString();
    QList<Activity> activities = spy.at(0).at(1).value<QList<Activity>>();
    
    EXPECT_EQ(sessionId, QString("abc"));
    ASSERT_EQ(activities.size(), 1);
    EXPECT_EQ(activities[0].id, QString("act1"));
    EXPECT_EQ(activities[0].originator, QString("agent"));
}

TEST_F(JulesApiClientTest, GetActivitiesUsesCorrectEndpoint) {
    QJsonObject response;
    response["activities"] = QJsonArray();
    m_mockNetwork->setNextResponse(200, response);

    m_client->getActivities("session-xyz");
    processEvents();

    QUrl url = m_mockNetwork->lastRequest().url();
    EXPECT_TRUE(url.path().contains("/sessions/session-xyz/activities"));
}

// ============================================================================
// createSession Tests
// ============================================================================

TEST_F(JulesApiClientTest, CreateSessionSendsCorrectPayload) {
    QJsonObject response;
    response["name"] = "sessions/new-session";
    response["id"] = "new-session";
    response["prompt"] = "Do something";
    response["state"] = "QUEUED";
    m_mockNetwork->setNextResponse(200, response);

    Source source;
    source.name = "sources/github/owner/repo";
    source.id = "source-123";

    QSignalSpy spy(m_client.get(), &JulesApiClient::sessionCreated);
    m_client->createSession(source, "main", "Do something");
    processEvents();

    // Verify POST request
    QNetworkRequest req = m_mockNetwork->lastRequest();
    EXPECT_EQ(req.rawHeader("Content-Type"), QByteArray("application/json"));

    // Verify request body
    QJsonDocument doc = QJsonDocument::fromJson(m_mockNetwork->lastRequestBody());
    ASSERT_TRUE(doc.isObject());
    QJsonObject body = doc.object();
    EXPECT_EQ(body["prompt"].toString(), QString("Do something"));
    EXPECT_TRUE(body.contains("sourceContext"));
}

TEST_F(JulesApiClientTest, CreateSessionEmitsSignalOnSuccess) {
    QJsonObject response;
    response["name"] = "sessions/created-session";
    response["id"] = "created-session";
    response["prompt"] = "Test prompt";
    response["state"] = "QUEUED";
    m_mockNetwork->setNextResponse(200, response);

    Source source;
    source.name = "sources/github/test/repo";
    source.id = "src-1";

    QSignalSpy spy(m_client.get(), &JulesApiClient::sessionCreated);
    m_client->createSession(source, "develop", "Test prompt");
    processEvents();

    ASSERT_EQ(spy.count(), 1);
    Session session = spy.at(0).at(0).value<Session>();
    EXPECT_EQ(session.id, QString("created-session"));
}

// ============================================================================
// Error Handling Tests
// ============================================================================

TEST_F(JulesApiClientTest, HandlesUnauthorizedError) {
    m_mockNetwork->setNextResponse(401, QByteArray("Unauthorized"));

    QSignalSpy spy(m_client.get(), &JulesApiClient::errorOccurred);
    m_client->getSessions();
    processEvents();

    ASSERT_EQ(spy.count(), 1);
    ApiError error = spy.at(0).at(0).value<ApiError>();
    EXPECT_EQ(error.type, ApiErrorType::Unauthorized);
}

TEST_F(JulesApiClientTest, HandlesForbiddenError) {
    m_mockNetwork->setNextResponse(403, QByteArray("Forbidden"));

    QSignalSpy spy(m_client.get(), &JulesApiClient::errorOccurred);
    m_client->getSessions();
    processEvents();

    ASSERT_EQ(spy.count(), 1);
    ApiError error = spy.at(0).at(0).value<ApiError>();
    EXPECT_EQ(error.type, ApiErrorType::Forbidden);
}

TEST_F(JulesApiClientTest, HandlesNotFoundError) {
    m_mockNetwork->setNextResponse(404, QByteArray("Not found"));

    QSignalSpy spy(m_client.get(), &JulesApiClient::errorOccurred);
    m_client->getSession("nonexistent");
    processEvents();

    ASSERT_EQ(spy.count(), 1);
    ApiError error = spy.at(0).at(0).value<ApiError>();
    EXPECT_EQ(error.type, ApiErrorType::NotFound);
}

TEST_F(JulesApiClientTest, HandlesServerError) {
    m_mockNetwork->setNextResponse(500, QByteArray("Internal server error"));

    QSignalSpy spy(m_client.get(), &JulesApiClient::errorOccurred);
    m_client->getSessions();
    processEvents(500);

    ASSERT_EQ(spy.count(), 1);
    ApiError error = spy.at(0).at(0).value<ApiError>();
    EXPECT_EQ(error.type, ApiErrorType::ServerError);
}

TEST_F(JulesApiClientTest, HandlesNetworkError) {
    m_mockNetwork->setNextError(QNetworkReply::ConnectionRefusedError, "Connection refused");

    QSignalSpy spy(m_client.get(), &JulesApiClient::errorOccurred);
    m_client->getSessions();
    processEvents(500);

    ASSERT_EQ(spy.count(), 1);
    ApiError error = spy.at(0).at(0).value<ApiError>();
    EXPECT_EQ(error.type, ApiErrorType::NetworkError);
}

// ============================================================================
// Rate Limiting Tests
// ============================================================================

TEST_F(JulesApiClientTest, RateLimiterInitialState) {
    EXPECT_EQ(m_client->rateLimiter().currentRequestCount(), 0);
    EXPECT_FALSE(m_client->rateLimiter().isAtLimit());
    EXPECT_EQ(m_client->rateLimiter().remainingRequests(), 100);
}

TEST_F(JulesApiClientTest, RateLimiterTracksRequests) {
    QJsonObject response;
    response["sessions"] = QJsonArray();
    m_mockNetwork->setNextResponse(200, response);

    // Make several requests
    for (int i = 0; i < 5; ++i) {
        m_client->getSessions();
        processEvents();
    }

    EXPECT_EQ(m_client->rateLimiter().currentRequestCount(), 5);
    EXPECT_EQ(m_client->rateLimiter().remainingRequests(), 95);
}

TEST_F(JulesApiClientTest, RateLimiterReportsApproachingLimit) {
    // Manually record many requests to approach limit
    for (int i = 0; i < 80; ++i) {
        m_client->rateLimiter().recordRequest();
    }

    EXPECT_TRUE(m_client->rateLimiter().isApproachingLimit());
    EXPECT_FALSE(m_client->rateLimiter().isAtLimit());
}

TEST_F(JulesApiClientTest, RateLimiterReportsAtLimit) {
    // Manually fill up rate limiter
    for (int i = 0; i < 100; ++i) {
        m_client->rateLimiter().recordRequest();
    }

    EXPECT_TRUE(m_client->rateLimiter().isAtLimit());
    EXPECT_EQ(m_client->rateLimiter().remainingRequests(), 0);
}

// ============================================================================
// Retry Logic Tests
// ============================================================================

TEST_F(JulesApiClientTest, RetriesOnServerError) {
    m_mockNetwork->setNextResponse(503, QByteArray("Service unavailable"));

    QSignalSpy errorSpy(m_client.get(), &JulesApiClient::errorOccurred);
    m_client->getSessions();
    processEvents(500);

    EXPECT_EQ(errorSpy.count(), 1);
    EXPECT_GE(m_mockNetwork->requestCount(), 3);
}

// ============================================================================
// Session State Parsing Tests
// ============================================================================

TEST_F(JulesApiClientTest, ParsesAllSessionStates) {
    struct StateTest {
        const char* apiState;
        SessionState expectedState;
    };

    std::vector<StateTest> tests = {
        {"STATE_UNSPECIFIED", SessionState::Unspecified},
        {"QUEUED", SessionState::Queued},
        {"PLANNING", SessionState::Planning},
        {"AWAITING_PLAN_APPROVAL", SessionState::AwaitingPlanApproval},
        {"AWAITING_USER_FEEDBACK", SessionState::AwaitingUserFeedback},
        {"IN_PROGRESS", SessionState::InProgress},
        {"PAUSED", SessionState::Paused},
        {"FAILED", SessionState::Failed},
        {"COMPLETED", SessionState::Completed},
    };

    for (const auto& test : tests) {
        QJsonObject response;
        response["id"] = "test-id";
        response["name"] = "sessions/test-id";
        response["prompt"] = "test";
        response["state"] = test.apiState;
        m_mockNetwork->setNextResponse(200, response);

        QSignalSpy spy(m_client.get(), &JulesApiClient::sessionReceived);
        m_client->getSession("test-id");
        processEvents();

        ASSERT_EQ(spy.count(), 1) << "Failed for state: " << test.apiState;
        Session session = spy.at(0).at(0).value<Session>();
        EXPECT_EQ(session.state, test.expectedState) << "Failed for state: " << test.apiState;
    }
}

// ============================================================================
// Data Structure Tests
// ============================================================================

TEST_F(JulesApiClientTest, SessionIsActiveForCorrectStates) {
    Session session;
    
    session.state = SessionState::Queued;
    EXPECT_TRUE(session.isActive());
    
    session.state = SessionState::Planning;
    EXPECT_TRUE(session.isActive());
    
    session.state = SessionState::InProgress;
    EXPECT_TRUE(session.isActive());
    
    session.state = SessionState::AwaitingPlanApproval;
    EXPECT_TRUE(session.isActive());
    
    session.state = SessionState::AwaitingUserFeedback;
    EXPECT_TRUE(session.isActive());
    
    session.state = SessionState::Completed;
    EXPECT_FALSE(session.isActive());
    
    session.state = SessionState::Failed;
    EXPECT_FALSE(session.isActive());
    
    session.state = SessionState::Paused;
    EXPECT_FALSE(session.isActive());
}

TEST_F(JulesApiClientTest, SessionIsTerminalForCorrectStates) {
    Session session;
    
    session.state = SessionState::Completed;
    EXPECT_TRUE(session.isTerminal());
    
    session.state = SessionState::Failed;
    EXPECT_TRUE(session.isTerminal());
    
    session.state = SessionState::Paused;
    EXPECT_TRUE(session.isTerminal());
    
    session.state = SessionState::InProgress;
    EXPECT_FALSE(session.isTerminal());
    
    session.state = SessionState::Queued;
    EXPECT_FALSE(session.isTerminal());
}

} // namespace test
} // namespace jules

// Required for Q_OBJECT macros in this file
#include "api_client_test.moc"

// Main function for Qt test application
int main(int argc, char** argv) {
    QCoreApplication app(argc, argv);
    ::testing::InitGoogleTest(&argc, argv);
    return RUN_ALL_TESTS();
}
