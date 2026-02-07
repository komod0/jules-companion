#pragma once

#include <QWidget>
#include <QVBoxLayout>
#include <QLabel>
#include <QScrollArea>
#include <QPushButton>
#include <QSplitter>
#include <QDateTime>
#include <QTimer>

#include "api/jules_api_client.h"

namespace jules {

class DiffPanelWidget;

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

protected:
    void resizeEvent(QResizeEvent* event) override;
    void changeEvent(QEvent* event) override;

signals:
    void openUrlRequested(const QString& url);
    void planApproved(const QString& sessionId);
    void feedbackProvided(const QString& sessionId, const QString& feedback);

private:
    void setupUi();
    void updateDisplay();
    void populateActivities();
    void clearActivities();
    QString formatActivityText(const Activity& activity) const;
    QIcon stateToIcon(SessionState state) const;
    QString stateToDisplayText(SessionState state) const;
    QColor stateToColor(SessionState state) const;
    QString markdownToHtml(const QString& markdown, bool isDark) const;

    // Text truncation helpers
    bool isTruncatable(const QString& text) const;
    QString truncateText(const QString& text, int maxLines = 5) const;

    // Time-ago auto-refresh
    void updateTimeAgo();

    // Time-ago formatting
    static QString formatTimeAgo(const QDateTime& created);

    std::optional<Session> m_session;

    // Fixed header bar (above scroll area)
    QWidget* m_headerBar;
    QLabel* m_titleLabel;
    QLabel* m_subtitleLabel;
    QLabel* m_stateLabel;
    QLabel* m_timeAgoLabel;

    QLabel* m_emptyLabel;
    QWidget* m_activityContainer;
    QVBoxLayout* m_activityLayout;
    QList<QWidget*> m_userBubbles;
    QPushButton* m_openBrowserBtn;
    QPushButton* m_pullRequestBtn;
    QWidget* m_contentWidget;
    QSplitter* m_mainSplitter;
    DiffPanelWidget* m_diffPanel;
    QScrollArea* m_scrollArea = nullptr;

    // Action bar for plan approval / feedback
    QWidget* m_actionBar = nullptr;
    QPushButton* m_approveButton = nullptr;
    QPushButton* m_feedbackButton = nullptr;

    // Prompt expansion (now in activity list)
    bool m_promptExpanded = false;

    // Time-ago auto-refresh timer
    QTimer* m_timeAgoTimer = nullptr;
};

}
