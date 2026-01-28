#pragma once

#include <QWidget>
#include <QVBoxLayout>
#include <QLabel>
#include <QScrollArea>
#include <QPushButton>
#include <QListWidget>

#include "api/jules_api_client.h"

namespace jules {

class SessionDetailWidget : public QWidget {
    Q_OBJECT

public:
    explicit SessionDetailWidget(QWidget* parent = nullptr);
    ~SessionDetailWidget() override;

    void setSession(const Session& session);
    void clear();

    bool isEmpty() const;
    QString displayedText() const;
    QString stateIndicatorText() const;
    int activityCount() const;
    bool hasPullRequestLink() const;
    QString pullRequestUrl() const;

    void requestOpenInBrowser();

signals:
    void openUrlRequested(const QString& url);

private:
    void setupUi();
    void updateDisplay();
    void populateActivities();
    QString formatActivityText(const Activity& activity) const;
    QIcon stateToIcon(SessionState state) const;
    QString stateToDisplayText(SessionState state) const;
    QColor stateToColor(SessionState state) const;

    std::optional<Session> m_session;
    
    QLabel* m_titleLabel;
    QLabel* m_promptLabel;
    QLabel* m_stateLabel;
    QLabel* m_repoLabel;
    QLabel* m_branchLabel;
    QLabel* m_emptyLabel;
    QListWidget* m_activityList;
    QPushButton* m_openBrowserBtn;
    QPushButton* m_pullRequestBtn;
    QWidget* m_contentWidget;
};

}
