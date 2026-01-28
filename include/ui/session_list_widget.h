#pragma once

#include <QWidget>
#include <QListWidget>
#include <QVBoxLayout>
#include <QPushButton>
#include <QLabel>
#include <QTimer>
#include <QMap>

#include "api/jules_api_client.h"
#include "data/session_repository.h"

namespace jules {

class SessionListWidget : public QWidget {
    Q_OBJECT

public:
    explicit SessionListWidget(SessionRepository* repository, QWidget* parent = nullptr);
    ~SessionListWidget() override;

    int sessionCount() const;
    QString sessionDisplayText(int index) const;
    QString sessionIdAt(int index) const;
    QString sessionStateIcon(int index) const;
    QString sessionStateText(int index) const;
    QString currentSessionId() const;

    void refresh();
    void selectSession(int index);
    void navigateUp();
    void navigateDown();
    void requestCreateNew();

    QList<QString> getActiveSessionIds() const;

    void startPolling();
    void stopPolling();
    bool isPolling() const;
    int pollingIntervalMs() const;
    void setPollingIntervalMs(int ms);

signals:
    void sessionSelected(const QString& sessionId);
    void createNewRequested();
    void refreshed();

private slots:
    void onSessionChanged(const QString& id);
    void onSessionDeleted(const QString& id);
    void onSessionsReloaded();
    void onItemClicked(QListWidgetItem* item);
    void onPollTimerTimeout();

private:
    void setupUi();
    void populateList();
    void updateSessionItem(QListWidgetItem* item, const Session& session);
    QIcon stateToIcon(SessionState state) const;
    QString stateToText(SessionState state) const;
    QColor stateToColor(SessionState state) const;

    SessionRepository* m_repository;
    QListWidget* m_listWidget;
    QPushButton* m_newButton;
    QLabel* m_emptyLabel;
    QTimer* m_pollTimer;
    int m_pollingIntervalMs;
    QMap<QString, int> m_sessionIndexMap;
};

}
