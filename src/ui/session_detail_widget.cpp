#include "ui/session_detail_widget.h"

#include <QFrame>
#include <QFont>
#include <QDesktopServices>
#include <QUrl>
#include <QHBoxLayout>

namespace jules {

namespace {
const QMap<SessionState, QString> STATE_DISPLAY_TEXTS = {
    {SessionState::Unspecified, "Unknown"},
    {SessionState::Queued, "Queued"},
    {SessionState::Planning, "Planning..."},
    {SessionState::InProgress, "In Progress"},
    {SessionState::Completed, "Completed"},
    {SessionState::CompletedUnknown, "Completed"},
    {SessionState::Failed, "Failed"},
    {SessionState::Paused, "Paused"},
    {SessionState::AwaitingUserFeedback, "Awaiting Your Input"},
    {SessionState::AwaitingPlanApproval, "Review Plan"}
};
}

SessionDetailWidget::SessionDetailWidget(QWidget* parent)
    : QWidget(parent)
    , m_titleLabel(nullptr)
    , m_promptLabel(nullptr)
    , m_stateLabel(nullptr)
    , m_repoLabel(nullptr)
    , m_branchLabel(nullptr)
    , m_emptyLabel(nullptr)
    , m_activityList(nullptr)
    , m_openBrowserBtn(nullptr)
    , m_pullRequestBtn(nullptr)
    , m_contentWidget(nullptr)
{
    setupUi();
}

SessionDetailWidget::~SessionDetailWidget() = default;

void SessionDetailWidget::setupUi() {
    auto* mainLayout = new QVBoxLayout(this);
    mainLayout->setContentsMargins(0, 0, 0, 0);
    mainLayout->setSpacing(0);
    
    m_emptyLabel = new QLabel("Select a session to view details", this);
    m_emptyLabel->setAlignment(Qt::AlignCenter);
    m_emptyLabel->setStyleSheet("color: palette(placeholderText); font-size: 14px; padding: 48px;");
    
    m_contentWidget = new QWidget(this);
    auto* contentLayout = new QVBoxLayout(m_contentWidget);
    contentLayout->setContentsMargins(24, 24, 24, 24);
    contentLayout->setSpacing(16);
    
    auto* headerWidget = new QWidget(m_contentWidget);
    auto* headerLayout = new QVBoxLayout(headerWidget);
    headerLayout->setContentsMargins(0, 0, 0, 0);
    headerLayout->setSpacing(8);
    
    auto* topRow = new QHBoxLayout();
    
    m_titleLabel = new QLabel(headerWidget);
    QFont titleFont = m_titleLabel->font();
    titleFont.setPointSize(titleFont.pointSize() + 6);
    titleFont.setBold(true);
    m_titleLabel->setFont(titleFont);
    m_titleLabel->setWordWrap(true);
    
    m_stateLabel = new QLabel(headerWidget);
    m_stateLabel->setStyleSheet(
        "background-color: #4285f4; color: white; "
        "padding: 4px 12px; border-radius: 12px; font-size: 12px;");
    
    topRow->addWidget(m_titleLabel, 1);
    topRow->addWidget(m_stateLabel);
    
    m_promptLabel = new QLabel(headerWidget);
    m_promptLabel->setStyleSheet("color: palette(text); font-size: 14px;");
    m_promptLabel->setWordWrap(true);
    
    auto* metaRow = new QHBoxLayout();
    metaRow->setSpacing(16);
    
    m_repoLabel = new QLabel(headerWidget);
    m_repoLabel->setStyleSheet("color: palette(placeholderText); font-size: 12px;");
    
    m_branchLabel = new QLabel(headerWidget);
    m_branchLabel->setStyleSheet("color: palette(placeholderText); font-size: 12px;");
    
    metaRow->addWidget(m_repoLabel);
    metaRow->addWidget(m_branchLabel);
    metaRow->addStretch();
    
    headerLayout->addLayout(topRow);
    headerLayout->addWidget(m_promptLabel);
    headerLayout->addLayout(metaRow);
    
    auto* separator = new QFrame(m_contentWidget);
    separator->setFrameShape(QFrame::HLine);
    separator->setFrameShadow(QFrame::Sunken);
    
    auto* activityHeader = new QLabel("Activity", m_contentWidget);
    QFont activityFont = activityHeader->font();
    activityFont.setBold(true);
    activityHeader->setFont(activityFont);
    
    m_activityList = new QListWidget(m_contentWidget);
    m_activityList->setFrameShape(QFrame::NoFrame);
    m_activityList->setSpacing(4);
    m_activityList->setSelectionMode(QAbstractItemView::NoSelection);
    m_activityList->setWordWrap(true);
    
    auto* buttonRow = new QHBoxLayout();
    
    m_openBrowserBtn = new QPushButton("Open in Browser", m_contentWidget);
    connect(m_openBrowserBtn, &QPushButton::clicked, 
            this, &SessionDetailWidget::requestOpenInBrowser);
    
    m_pullRequestBtn = new QPushButton("View Pull Request", m_contentWidget);
    m_pullRequestBtn->setStyleSheet(
        "background-color: #34a853; color: white; padding: 8px 16px; border-radius: 4px;");
    m_pullRequestBtn->hide();
    connect(m_pullRequestBtn, &QPushButton::clicked, [this]() {
        QString prUrl = pullRequestUrl();
        if (!prUrl.isEmpty()) {
            emit openUrlRequested(prUrl);
        }
    });
    
    buttonRow->addWidget(m_openBrowserBtn);
    buttonRow->addWidget(m_pullRequestBtn);
    buttonRow->addStretch();
    
    contentLayout->addWidget(headerWidget);
    contentLayout->addWidget(separator);
    contentLayout->addWidget(activityHeader);
    contentLayout->addWidget(m_activityList, 1);
    contentLayout->addLayout(buttonRow);
    
    mainLayout->addWidget(m_emptyLabel);
    mainLayout->addWidget(m_contentWidget, 1);
    
    m_contentWidget->hide();
}

void SessionDetailWidget::setSession(const Session& session) {
    m_session = session;
    updateDisplay();
    populateActivities();
    
    m_emptyLabel->hide();
    m_contentWidget->show();
}

void SessionDetailWidget::clear() {
    m_session.reset();
    m_activityList->clear();
    
    m_contentWidget->hide();
    m_emptyLabel->show();
}

bool SessionDetailWidget::isEmpty() const {
    return !m_session.has_value();
}

QString SessionDetailWidget::displayedText() const {
    if (!m_session.has_value()) {
        return QString();
    }
    
    QString text = m_titleLabel->text() + "\n" + m_promptLabel->text();
    if (!m_repoLabel->text().isEmpty()) {
        text += "\n" + m_repoLabel->text();
    }
    return text;
}

QString SessionDetailWidget::stateIndicatorText() const {
    if (!m_session.has_value()) {
        return QString();
    }
    return stateToDisplayText(m_session->state);
}

int SessionDetailWidget::activityCount() const {
    return m_activityList->count();
}

bool SessionDetailWidget::hasPullRequestLink() const {
    if (!m_session.has_value() || !m_session->outputs.has_value()) {
        return false;
    }
    
    for (const auto& output : m_session->outputs.value()) {
        if (output.pullRequest.has_value()) {
            return true;
        }
    }
    return false;
}

QString SessionDetailWidget::pullRequestUrl() const {
    if (!m_session.has_value() || !m_session->outputs.has_value()) {
        return QString();
    }
    
    for (const auto& output : m_session->outputs.value()) {
        if (output.pullRequest.has_value()) {
            return output.pullRequest->url;
        }
    }
    return QString();
}

void SessionDetailWidget::requestOpenInBrowser() {
    if (m_session.has_value() && m_session->url.has_value()) {
        emit openUrlRequested(m_session->url.value());
    }
}

void SessionDetailWidget::updateDisplay() {
    if (!m_session.has_value()) {
        return;
    }
    
    const Session& session = m_session.value();
    
    QString title = session.title.value_or(session.prompt.left(50));
    if (title.length() > 50) {
        title = title.left(47) + "...";
    }
    m_titleLabel->setText(title);
    
    m_promptLabel->setText(session.prompt);
    
    QString stateText = stateToDisplayText(session.state);
    m_stateLabel->setText(stateText);
    
    QColor stateColor = stateToColor(session.state);
    m_stateLabel->setStyleSheet(QString(
        "background-color: %1; color: white; "
        "padding: 4px 12px; border-radius: 12px; font-size: 12px;")
        .arg(stateColor.name()));
    
    if (session.sourceContext.has_value()) {
        QString source = session.sourceContext->source;
        source = source.replace("sources/github/", "");
        m_repoLabel->setText(QString("Repository: %1").arg(source));
        
        if (session.sourceContext->githubRepoContext.has_value() &&
            session.sourceContext->githubRepoContext->startingBranch.has_value()) {
            m_branchLabel->setText(QString("Branch: %1")
                .arg(session.sourceContext->githubRepoContext->startingBranch.value()));
        } else {
            m_branchLabel->clear();
        }
    } else {
        m_repoLabel->clear();
        m_branchLabel->clear();
    }
    
    m_pullRequestBtn->setVisible(hasPullRequestLink());
}

void SessionDetailWidget::populateActivities() {
    m_activityList->clear();
    
    if (!m_session.has_value() || !m_session->activities.has_value()) {
        return;
    }
    
    for (const auto& activity : m_session->activities.value()) {
        QString text = formatActivityText(activity);
        if (!text.isEmpty()) {
            auto* item = new QListWidgetItem(text, m_activityList);
            item->setData(Qt::UserRole, activity.id);
            
            if (activity.originator == "USER") {
                item->setBackground(QColor(240, 240, 240));
            }
        }
    }
}

QString SessionDetailWidget::formatActivityText(const Activity& activity) const {
    QString text;
    
    if (activity.userMessaged.has_value()) {
        text = QString("You: %1").arg(activity.userMessaged->userMessage);
    } else if (activity.agentMessaged.has_value()) {
        text = QString("Jules: %1").arg(activity.agentMessaged->agentMessage);
    } else if (activity.progressUpdated.has_value()) {
        QString title = activity.progressUpdated->title.value_or("Working");
        QString desc = activity.progressUpdated->description.value_or("");
        text = QString("%1").arg(title);
        if (!desc.isEmpty()) {
            text += QString("\n%1").arg(desc.left(100));
        }
    } else if (activity.planGenerated.has_value()) {
        text = QString("Plan generated with %1 steps")
                   .arg(activity.planGenerated->plan.steps.size());
    } else if (activity.planApproved.has_value()) {
        text = "Plan approved";
    } else if (activity.sessionCompleted.has_value()) {
        text = "Session completed";
    } else if (activity.sessionFailed.has_value()) {
        QString reason = activity.sessionFailed->reason.value_or("Unknown error");
        text = QString("Session failed: %1").arg(reason);
    }
    
    return text;
}

QIcon SessionDetailWidget::stateToIcon(SessionState state) const {
    Q_UNUSED(state);
    return QIcon();
}

QString SessionDetailWidget::stateToDisplayText(SessionState state) const {
    return STATE_DISPLAY_TEXTS.value(state, "Unknown");
}

QColor SessionDetailWidget::stateToColor(SessionState state) const {
    switch (state) {
        case SessionState::Queued:
            return QColor(128, 128, 128);
        case SessionState::Planning:
        case SessionState::InProgress:
            return QColor(66, 133, 244);
        case SessionState::Completed:
        case SessionState::CompletedUnknown:
            return QColor(52, 168, 83);
        case SessionState::Failed:
            return QColor(234, 67, 53);
        case SessionState::Paused:
            return QColor(251, 188, 4);
        case SessionState::AwaitingUserFeedback:
        case SessionState::AwaitingPlanApproval:
            return QColor(255, 152, 0);
        default:
            return QColor(128, 128, 128);
    }
}

}
