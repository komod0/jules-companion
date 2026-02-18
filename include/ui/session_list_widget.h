#pragma once

#include <QWidget>
#include <QListWidget>
#include <QVBoxLayout>
#include <QPushButton>
#include <QLabel>
#include <QLineEdit>
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

    void setSearchText(const QString& text);
    QString searchText() const;
    void clearSearch();

    QLineEdit* searchField() const { return m_searchEdit; }

signals:
    void sessionSelected(const QString& sessionId);
    void createNewRequested();
    void openInBrowserRequested(const QString& sessionId);
    void deleteSessionRequested(const QString& sessionId);
    void refreshed();

private slots:
    void onSessionChanged(const QString& id);
    void onSessionDeleted(const QString& id);
    void onSessionsReloaded();
    void onItemClicked(QListWidgetItem* item);
    void onPollTimerTimeout();
    void onSearchTextChanged(const QString& text);
    void showContextMenu(const QPoint& pos);

private:
    void setupUi();
    void populateList();
    void addSectionHeader(const QString& title);
    void updateSessionItem(QListWidgetItem* item, const Session& session);
    int sessionIndexToListIndex(int sessionIndex) const;
    void applySearchFilter();
    bool sessionMatchesSearch(const Session& session) const;
    QIcon stateToIcon(SessionState state) const;
    QString stateToText(SessionState state) const;
    QColor stateToColor(SessionState state) const;

    SessionRepository* m_repository;
    QListWidget* m_listWidget;
    QPushButton* m_newButton;
    QLineEdit* m_searchEdit;
    QLabel* m_emptyLabel;
    QTimer* m_pollTimer;
    int m_pollingIntervalMs;
    QString m_searchText;
    QMap<QString, int> m_sessionIndexMap;
    QList<Session> m_cachedSessions;
};

}
