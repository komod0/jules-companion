#include "ui/session_detail_widget.h"
#include "ui/app_colors.h"

#include <QFrame>
#include <QFont>
#include <QDesktopServices>
#include <QUrl>
#include <QHBoxLayout>
#include <QScrollArea>
#include <QPainter>

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
    
    // Empty state label
    m_emptyLabel = new QLabel("Select a session to view details", this);
    m_emptyLabel->setAlignment(Qt::AlignCenter);
    m_emptyLabel->setStyleSheet("color: palette(placeholderText); font-size: 16px; padding: 48px;");
    
    // Main content widget with scroll area
    auto* scrollArea = new QScrollArea(this);
    scrollArea->setWidgetResizable(true);
    scrollArea->setFrameShape(QFrame::NoFrame);
    scrollArea->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
    
    m_contentWidget = new QWidget(scrollArea);
    scrollArea->setWidget(m_contentWidget);
    
    auto* contentLayout = new QVBoxLayout(m_contentWidget);
    contentLayout->setContentsMargins(24, 20, 24, 24);
    contentLayout->setSpacing(0);
    
    // === Header Section ===
    auto* headerWidget = new QWidget(m_contentWidget);
    auto* headerLayout = new QVBoxLayout(headerWidget);
    headerLayout->setContentsMargins(0, 0, 0, 16);
    headerLayout->setSpacing(12);
    
    // Title row with state badge
    auto* topRow = new QHBoxLayout();
    topRow->setSpacing(12);
    
    m_titleLabel = new QLabel(headerWidget);
    QFont titleFont = m_titleLabel->font();
    titleFont.setPointSize(18);
    titleFont.setWeight(QFont::DemiBold);
    m_titleLabel->setFont(titleFont);
    m_titleLabel->setWordWrap(true);
    
    // State badge with pill styling
    m_stateLabel = new QLabel(headerWidget);
    m_stateLabel->setFixedHeight(24);
    
    topRow->addWidget(m_titleLabel, 1);
    topRow->addWidget(m_stateLabel);
    topRow->setAlignment(m_stateLabel, Qt::AlignTop);
    
    // Prompt text
    m_promptLabel = new QLabel(headerWidget);
    m_promptLabel->setWordWrap(true);
    QFont promptFont = m_promptLabel->font();
    promptFont.setPointSize(14);
    m_promptLabel->setFont(promptFont);
    
    // Metadata row (repo, branch)
    auto* metaRow = new QHBoxLayout();
    metaRow->setSpacing(16);
    
    m_repoLabel = new QLabel(headerWidget);
    QFont metaFont = m_repoLabel->font();
    metaFont.setPointSize(12);
    m_repoLabel->setFont(metaFont);
    
    m_branchLabel = new QLabel(headerWidget);
    m_branchLabel->setFont(metaFont);
    
    metaRow->addWidget(m_repoLabel);
    metaRow->addWidget(m_branchLabel);
    metaRow->addStretch();
    
    headerLayout->addLayout(topRow);
    headerLayout->addWidget(m_promptLabel);
    headerLayout->addLayout(metaRow);
    
    // === Activity Section ===
    auto* activityHeader = new QLabel("Activity", m_contentWidget);
    QFont activityFont = activityHeader->font();
    activityFont.setPointSize(14);
    activityFont.setWeight(QFont::DemiBold);
    activityHeader->setFont(activityFont);
    
    // Activity list with message bubble styling
    m_activityList = new QListWidget(m_contentWidget);
    m_activityList->setFrameShape(QFrame::NoFrame);
    m_activityList->setSpacing(8);
    m_activityList->setSelectionMode(QAbstractItemView::NoSelection);
    m_activityList->setWordWrap(true);
    m_activityList->setStyleSheet(R"(
        QListWidget {
            background-color: transparent;
            border: none;
        }
        QListWidget::item {
            background-color: transparent;
            border: none;
            padding: 0px;
        }
    )");
    
    // === Button Row ===
    auto* buttonRow = new QHBoxLayout();
    buttonRow->setSpacing(12);
    
    m_openBrowserBtn = new QPushButton("Open in Browser", m_contentWidget);
    m_openBrowserBtn->setStyleSheet(R"(
        QPushButton {
            background-color: transparent;
            border: 1px solid palette(mid);
            border-radius: 8px;
            padding: 10px 20px;
            font-size: 13px;
            font-weight: 500;
        }
        QPushButton:hover {
            background-color: rgba(128, 128, 128, 0.1);
        }
        QPushButton:pressed {
            background-color: rgba(128, 128, 128, 0.2);
        }
    )");
    connect(m_openBrowserBtn, &QPushButton::clicked, 
            this, &SessionDetailWidget::requestOpenInBrowser);
    
    m_pullRequestBtn = new QPushButton("View Pull Request", m_contentWidget);
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
    
    // Assemble content layout
    contentLayout->addWidget(headerWidget);
    contentLayout->addSpacing(16);
    contentLayout->addWidget(activityHeader);
    contentLayout->addSpacing(12);
    contentLayout->addWidget(m_activityList, 1);
    contentLayout->addSpacing(16);
    contentLayout->addLayout(buttonRow);
    
    mainLayout->addWidget(m_emptyLabel);
    mainLayout->addWidget(scrollArea, 1);
    
    scrollArea->hide();
}

void SessionDetailWidget::setSession(const Session& session) {
    m_session = session;
    updateDisplay();
    populateActivities();
    
    m_emptyLabel->hide();
    // Find scroll area and show it
    if (auto* scrollArea = findChild<QScrollArea*>()) {
        scrollArea->show();
    }
}

void SessionDetailWidget::clear() {
    m_session.reset();
    m_activityList->clear();
    
    if (auto* scrollArea = findChild<QScrollArea*>()) {
        scrollArea->hide();
    }
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
    
    bool isDark = palette().window().color().lightness() < 128;
    const Session& session = m_session.value();
    
    // Title
    QString title = session.title.value_or(session.prompt.left(50));
    if (title.length() > 60) {
        title = title.left(57) + "...";
    }
    m_titleLabel->setText(title);
    m_titleLabel->setStyleSheet(QString("color: %1;").arg(AppColors::textPrimary(isDark).name()));
    
    // Prompt
    m_promptLabel->setText(session.prompt);
    m_promptLabel->setStyleSheet(QString("color: %1;").arg(AppColors::textPrimary(isDark).name()));
    
    // State badge with proper colors
    QString stateText = stateToDisplayText(session.state);
    m_stateLabel->setText(stateText);
    
    QColor stateColor = stateToColor(session.state);
    QColor textColor = isDark ? QColor(0, 0, 0) : QColor(255, 255, 255);
    
    // Adjust text color for better contrast on certain backgrounds
    if (session.state == SessionState::Completed || 
        session.state == SessionState::CompletedUnknown ||
        session.state == SessionState::Queued ||
        session.state == SessionState::Unspecified) {
        textColor = QColor(255, 255, 255);
    }
    
    m_stateLabel->setStyleSheet(QString(
        "background-color: %1; color: %2; "
        "padding: 4px 12px; border-radius: 12px; font-size: 12px; font-weight: 500;")
        .arg(stateColor.name())
        .arg(textColor.name()));
    
    // Metadata
    QColor secondaryColor = AppColors::textSecondary(isDark);
    QString metaStyle = QString("color: %1;").arg(secondaryColor.name());
    
    if (session.sourceContext.has_value()) {
        QString source = session.sourceContext->source;
        source = source.replace("sources/github/", "");
        m_repoLabel->setText(QString("📁 %1").arg(source));
        m_repoLabel->setStyleSheet(metaStyle);
        
        if (session.sourceContext->githubRepoContext.has_value() &&
            session.sourceContext->githubRepoContext->startingBranch.has_value()) {
            m_branchLabel->setText(QString("🌿 %1")
                .arg(session.sourceContext->githubRepoContext->startingBranch.value()));
            m_branchLabel->setStyleSheet(metaStyle);
        } else {
            m_branchLabel->clear();
        }
    } else {
        m_repoLabel->clear();
        m_branchLabel->clear();
    }
    
    // PR button styling
    bool hasPR = hasPullRequestLink();
    m_pullRequestBtn->setVisible(hasPR);
    if (hasPR) {
        QColor prColor = AppColors::running(isDark);
        m_pullRequestBtn->setStyleSheet(QString(
            "QPushButton {"
            "  background-color: %1; color: white; "
            "  padding: 10px 20px; border-radius: 8px; font-size: 13px; font-weight: 500; border: none;"
            "}"
            "QPushButton:hover { background-color: %2; }"
            "QPushButton:pressed { background-color: %3; }")
            .arg(prColor.name())
            .arg(prColor.darker(110).name())
            .arg(prColor.darker(120).name()));
    }
}

void SessionDetailWidget::populateActivities() {
    m_activityList->clear();
    
    if (!m_session.has_value() || !m_session->activities.has_value()) {
        return;
    }
    
    bool isDark = palette().window().color().lightness() < 128;
    
    for (const auto& activity : m_session->activities.value()) {
        QString text = formatActivityText(activity);
        if (!text.isEmpty()) {
            auto* item = new QListWidgetItem(m_activityList);
            item->setData(Qt::UserRole, activity.id);
            
            // Create a custom widget for the activity item (message bubble style)
            auto* itemWidget = new QWidget();
            auto* itemLayout = new QHBoxLayout(itemWidget);
            itemLayout->setContentsMargins(0, 10, 0, 10);  // Match macOS ~20pt spacing
            
            bool isUser = (activity.originator == "USER");
            
            auto* bubble = new QLabel(text);
            bubble->setWordWrap(true);
            bubble->setTextInteractionFlags(Qt::TextSelectableByMouse);
            bubble->setMaximumWidth(450);  // Limit bubble width like macOS (minLength: 50 spacer)
            
            // User messages: accent background, white text
            // Agent messages: secondary background, primary text
            QColor bubbleBg = isUser 
                ? AppColors::accent(isDark)
                : AppColors::backgroundSecondary(isDark);
            QColor bubbleText = isUser 
                ? QColor(255, 255, 255)  // White for user bubbles
                : AppColors::textPrimary(isDark);
            
            bubble->setStyleSheet(QString(
                "background-color: %1; color: %2; "
                "padding: 12px 16px; border-radius: 18px; font-size: 13px;")
                .arg(bubbleBg.name())
                .arg(bubbleText.name()));
            
            if (isUser) {
                itemLayout->addSpacing(50);  // Match macOS minLength: 50
                itemLayout->addStretch();
                itemLayout->addWidget(bubble);
            } else {
                itemLayout->addWidget(bubble);
                itemLayout->addStretch();
                itemLayout->addSpacing(50);  // Match macOS minLength: 50
            }
            
            item->setSizeHint(itemWidget->sizeHint());
            m_activityList->setItemWidget(item, itemWidget);
        }
    }
    
    // Scroll to bottom to show latest activity
    if (m_activityList->count() > 0) {
        m_activityList->scrollToBottom();
    }
}

QString SessionDetailWidget::formatActivityText(const Activity& activity) const {
    QString text;
    
    if (activity.userMessaged.has_value()) {
        text = activity.userMessaged->userMessage;
    } else if (activity.agentMessaged.has_value()) {
        text = activity.agentMessaged->agentMessage;
    } else if (activity.progressUpdated.has_value()) {
        QString title = activity.progressUpdated->title.value_or("Working");
        QString desc = activity.progressUpdated->description.value_or("");
        text = QString("⏳ %1").arg(title);
        if (!desc.isEmpty() && desc.length() < 100) {
            text += QString("\n%1").arg(desc);
        }
    } else if (activity.planGenerated.has_value()) {
        text = QString("📋 Plan generated with %1 steps")
                   .arg(activity.planGenerated->plan.steps.size());
    } else if (activity.planApproved.has_value()) {
        text = "✅ Plan approved";
    } else if (activity.sessionCompleted.has_value()) {
        text = "🎉 Session completed";
    } else if (activity.sessionFailed.has_value()) {
        QString reason = activity.sessionFailed->reason.value_or("Unknown error");
        text = QString("❌ Session failed: %1").arg(reason);
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
    bool isDark = palette().window().color().lightness() < 128;
    return AppColors::stateColor(static_cast<int>(state), isDark);
}

}
