#include "ui/session_detail_widget.h"
#include "ui/diff_panel_widget.h"
#include "ui/app_colors.h"

#include <QFrame>
#include <QFont>
#include <QDesktopServices>
#include <QUrl>
#include <QHBoxLayout>
#include <QScrollArea>
#include <QPainter>
#include <QRegularExpression>
#include <QSplitter>
#include <QPropertyAnimation>
#include <QInputDialog>
#include <QResizeEvent>
#include <QScrollBar>
#include <QTimer>

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

// (PlanStepWidget removed — plan steps rendered as simple HTML bullet list)

}

SessionDetailWidget::SessionDetailWidget(QWidget* parent)
    : QWidget(parent)
    , m_headerBar(nullptr)
    , m_titleLabel(nullptr)
    , m_subtitleLabel(nullptr)
    , m_stateLabel(nullptr)
    , m_timeAgoLabel(nullptr)
    , m_emptyLabel(nullptr)
    , m_activityContainer(nullptr)
    , m_activityLayout(nullptr)
    , m_openBrowserBtn(nullptr)
    , m_pullRequestBtn(nullptr)
    , m_contentWidget(nullptr)
    , m_mainSplitter(nullptr)
    , m_diffPanel(nullptr)
{
    setupUi();

    // Time-ago auto-refresh: update every 60 seconds
    m_timeAgoTimer = new QTimer(this);
    m_timeAgoTimer->setInterval(60000);
    connect(m_timeAgoTimer, &QTimer::timeout, this, &SessionDetailWidget::updateTimeAgo);
}

SessionDetailWidget::~SessionDetailWidget() = default;

void SessionDetailWidget::setupUi() {
    auto* mainLayout = new QVBoxLayout(this);
    mainLayout->setContentsMargins(0, 0, 0, 0);
    mainLayout->setSpacing(0);

    // Empty state label - centered, larger, dimmed
    m_emptyLabel = new QLabel("Select a session from the sidebar", this);
    m_emptyLabel->setAlignment(Qt::AlignCenter);
    m_emptyLabel->setStyleSheet("color: palette(placeholderText); font-size: 18px; padding: 48px;");

    // === Fixed Header Bar (above scroll area) ===
    m_headerBar = new QWidget(this);
    m_headerBar->setFixedHeight(72);

    auto* headerBarLayout = new QHBoxLayout(m_headerBar);
    headerBarLayout->setContentsMargins(16, 10, 16, 10);
    headerBarLayout->setSpacing(12);

    // Left side: title + subtitle
    auto* leftVBox = new QVBoxLayout();
    leftVBox->setContentsMargins(0, 0, 0, 0);
    leftVBox->setSpacing(2);

    m_titleLabel = new QLabel(m_headerBar);
    QFont titleFont = m_titleLabel->font();
    titleFont.setPointSize(16);
    titleFont.setWeight(QFont::Normal);
    m_titleLabel->setFont(titleFont);
    m_titleLabel->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Preferred);

    m_subtitleLabel = new QLabel(m_headerBar);
    QFont subtitleFont = m_subtitleLabel->font();
    subtitleFont.setPointSize(12);
    m_subtitleLabel->setFont(subtitleFont);
    m_subtitleLabel->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Preferred);
    m_subtitleLabel->setTextFormat(Qt::RichText);
    m_subtitleLabel->setTextInteractionFlags(Qt::TextBrowserInteraction);
    m_subtitleLabel->setOpenExternalLinks(true);

    leftVBox->addWidget(m_titleLabel);
    leftVBox->addWidget(m_subtitleLabel);

    // Right side: state badge + time ago
    auto* rightVBox = new QVBoxLayout();
    rightVBox->setContentsMargins(0, 0, 0, 0);
    rightVBox->setSpacing(2);
    rightVBox->setAlignment(Qt::AlignVCenter | Qt::AlignRight);

    m_pullRequestBtn = new QPushButton("View PR", m_headerBar);
    m_pullRequestBtn->setFixedHeight(28);
    m_pullRequestBtn->hide();
    m_pullRequestBtn->setCursor(Qt::PointingHandCursor);
    connect(m_pullRequestBtn, &QPushButton::clicked, [this]() {
        QString prUrl = pullRequestUrl();
        if (!prUrl.isEmpty()) {
            emit openUrlRequested(prUrl);
        }
    });

    m_stateLabel = new QLabel(m_headerBar);
    m_stateLabel->setFixedHeight(28);
    m_stateLabel->setAlignment(Qt::AlignRight);

    m_timeAgoLabel = new QLabel(m_headerBar);
    QFont timeFont = m_timeAgoLabel->font();
    timeFont.setPointSize(11);
    m_timeAgoLabel->setFont(timeFont);
    m_timeAgoLabel->setFixedHeight(28);
    m_timeAgoLabel->setAlignment(Qt::AlignRight | Qt::AlignVCenter);

    auto* rightTopRow = new QHBoxLayout();
    rightTopRow->setSpacing(8);
    m_diffToggleBtn = new QPushButton(m_headerBar);
    m_diffToggleBtn->setFixedSize(28, 28);
    m_diffToggleBtn->setCursor(Qt::PointingHandCursor);
    m_diffToggleBtn->setToolTip("Toggle Diff Panel");
    m_diffToggleBtn->setText(QString::fromUtf8("\u00BB")); // » chevron = diff visible
    connect(m_diffToggleBtn, &QPushButton::clicked, this, &SessionDetailWidget::toggleDiffPanel);

    rightTopRow->addWidget(m_pullRequestBtn);
    rightTopRow->addWidget(m_stateLabel);
    rightTopRow->addWidget(m_timeAgoLabel);
    rightTopRow->addWidget(m_diffToggleBtn);

    rightVBox->addLayout(rightTopRow);

    headerBarLayout->addLayout(leftVBox, 1);
    headerBarLayout->addLayout(rightVBox);

    // === Action Bar (plan approval / feedback) ===
    m_actionBar = new QWidget(this);
    auto* actionLayout = new QHBoxLayout(m_actionBar);
    actionLayout->setContentsMargins(12, 8, 12, 8);
    actionLayout->setSpacing(12);

    m_approveButton = new QPushButton("Approve Plan", m_actionBar);
    m_approveButton->setObjectName("approveButton");
    m_approveButton->setCursor(Qt::PointingHandCursor);
    m_feedbackButton = new QPushButton("Provide Feedback", m_actionBar);
    m_feedbackButton->setObjectName("feedbackButton");
    m_feedbackButton->setCursor(Qt::PointingHandCursor);

    actionLayout->addStretch();
    actionLayout->addWidget(m_approveButton);
    actionLayout->addWidget(m_feedbackButton);

    m_actionBar->hide();

    // Connect action bar buttons
    connect(m_approveButton, &QPushButton::clicked, this, [this]() {
        if (m_session.has_value()) {
            emit planApproved(m_session->id);
        }
    });
    connect(m_feedbackButton, &QPushButton::clicked, this, [this]() {
        if (!m_session.has_value()) return;
        bool ok = false;
        QString feedback = QInputDialog::getMultiLineText(
            this, "Provide Feedback", "Enter your feedback:", QString(), &ok);
        if (ok && !feedback.isEmpty()) {
            emit feedbackProvided(m_session->id, feedback);
        }
    });

    // === Scroll Area for activities ===
    auto* scrollArea = new QScrollArea(this);
    m_scrollArea = scrollArea;
    scrollArea->setWidgetResizable(true);
    scrollArea->setFrameShape(QFrame::NoFrame);
    scrollArea->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);

    m_contentWidget = new QWidget(scrollArea);
    scrollArea->setWidget(m_contentWidget);

    auto* contentLayout = new QVBoxLayout(m_contentWidget);
    contentLayout->setContentsMargins(16, 12, 16, 16);
    contentLayout->setSpacing(0);

    // Activity container with VBoxLayout for automatic text reflow on resize
    m_activityContainer = new QWidget(m_contentWidget);
    m_activityLayout = new QVBoxLayout(m_activityContainer);
    m_activityLayout->setSpacing(12);
    m_activityLayout->setContentsMargins(0, 0, 0, 0);

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
    m_openBrowserBtn->setCursor(Qt::PointingHandCursor);
    connect(m_openBrowserBtn, &QPushButton::clicked,
            this, &SessionDetailWidget::requestOpenInBrowser);

    buttonRow->addWidget(m_openBrowserBtn);
    buttonRow->addStretch();

    // Assemble content layout (activities + buttons)
    contentLayout->addWidget(m_activityContainer, 1);
    contentLayout->addSpacing(16);
    contentLayout->addLayout(buttonRow);

    // Create diff panel
    m_diffPanel = new DiffPanelWidget(this);
    m_diffPanel->setMinimumWidth(0);

    // Create horizontal splitter: activities on left, diffs on right
    m_mainSplitter = new QSplitter(Qt::Horizontal, this);

    // Wrap diff panel in opaque container to prevent transparency bleed
    auto* diffContainer = new QWidget(this);
    diffContainer->setAutoFillBackground(true);
    auto* diffContainerLayout = new QVBoxLayout(diffContainer);
    diffContainerLayout->setContentsMargins(0, 0, 0, 0);
    diffContainerLayout->setSpacing(0);
    diffContainerLayout->addWidget(m_diffPanel);

    m_mainSplitter->addWidget(scrollArea);
    m_mainSplitter->addWidget(diffContainer);
    m_mainSplitter->setStretchFactor(0, 2);
    m_mainSplitter->setStretchFactor(1, 3);
    m_mainSplitter->setSizes(QList<int>() << 400 << 600);

    // Assemble main layout:
    //   headerBar (fixed) → actionBar → splitter (scrollable activities + diff)
    mainLayout->addWidget(m_emptyLabel);
    mainLayout->addWidget(m_headerBar);
    mainLayout->addWidget(m_actionBar);
    mainLayout->addWidget(m_mainSplitter, 1);

    m_headerBar->hide();
    m_mainSplitter->hide();
}

void SessionDetailWidget::setSession(const Session& session) {
    m_session = session;
    m_promptExpanded = false;  // Reset expansion state for new session
    updateDisplay();
    populateActivities();

    // Restart time-ago auto-refresh timer
    if (m_timeAgoTimer) {
        m_timeAgoTimer->start();
    }

    // Show/hide action bar based on session state
    bool isDark = palette().window().color().lightness() < 128;
    if (session.state == SessionState::AwaitingPlanApproval) {
        m_actionBar->show();
        m_approveButton->show();
        m_feedbackButton->setText("Request Changes");
        m_feedbackButton->show();
        // Style approve button: accent bg, white text
        QColor accentColor = AppColors::accent(isDark);
        m_approveButton->setStyleSheet(QString(
            "QPushButton { background-color: %1; color: white; padding: 8px 20px; "
            "border-radius: 8px; font-size: 13px; font-weight: 500; border: none; }"
            "QPushButton:hover { background-color: %2; }"
            "QPushButton:pressed { background-color: %3; }")
            .arg(accentColor.name())
            .arg(accentColor.darker(110).name())
            .arg(accentColor.darker(120).name()));
        // Style feedback button: secondary bg, primary text
        QColor secondaryBg = AppColors::backgroundSecondary(isDark);
        QColor primaryText = AppColors::textPrimary(isDark);
        m_feedbackButton->setStyleSheet(QString(
            "QPushButton { background-color: %1; color: %2; padding: 8px 20px; "
            "border-radius: 8px; font-size: 13px; font-weight: 500; border: none; }"
            "QPushButton:hover { background-color: %3; }")
            .arg(secondaryBg.name())
            .arg(primaryText.name())
            .arg(secondaryBg.darker(110).name()));
    } else if (session.state == SessionState::AwaitingUserFeedback) {
        m_actionBar->show();
        m_approveButton->hide();
        m_feedbackButton->setText("Provide Feedback");
        m_feedbackButton->show();
        QColor accentColor = AppColors::accent(isDark);
        m_feedbackButton->setStyleSheet(QString(
            "QPushButton { background-color: %1; color: white; padding: 8px 20px; "
            "border-radius: 8px; font-size: 13px; font-weight: 500; border: none; }"
            "QPushButton:hover { background-color: %2; }"
            "QPushButton:pressed { background-color: %3; }")
            .arg(accentColor.name())
            .arg(accentColor.darker(110).name())
            .arg(accentColor.darker(120).name()));
    } else {
        m_actionBar->hide();
    }

    // Update diff panel with cached diffs
    qDebug() << "[SessionDetailWidget::setSession] Session:" << session.id.left(8)
             << "hasDiffs:" << session.cachedLatestDiffs.has_value()
             << "diffCount:" << (session.cachedLatestDiffs.has_value() ? session.cachedLatestDiffs->size() : 0);

    if (m_diffPanel) {
        bool hasDiffs = session.cachedLatestDiffs.has_value() && !session.cachedLatestDiffs->isEmpty();

        if (hasDiffs) {
            qDebug() << "[SessionDetailWidget::setSession] Setting" << session.cachedLatestDiffs->size() << "diffs";
            m_diffPanel->setLoading(false);
            m_diffPanel->setDiffs(session.cachedLatestDiffs.value());
        } else if (!session.activitiesFetched) {
            // Show loading for ANY session whose activities haven't arrived yet
            qDebug() << "[SessionDetailWidget::setSession] Activities not fetched, showing loading spinner";
            m_diffPanel->setLoading(true);
        } else {
            qDebug() << "[SessionDetailWidget::setSession] No diffs available (activities fetched)";
            m_diffPanel->setLoading(false);
            m_diffPanel->setDiffs({});  // Clear any old diffs
        }
    }

    m_emptyLabel->hide();
    m_headerBar->show();
    if (m_mainSplitter) {
        m_mainSplitter->show();
    }
}

void SessionDetailWidget::clear() {
    m_session.reset();
    clearActivities();

    // Stop time-ago auto-refresh
    if (m_timeAgoTimer) {
        m_timeAgoTimer->stop();
    }

    if (m_diffPanel) {
        m_diffPanel->setLoading(false);
        m_diffPanel->setDiffs({});  // Clear diffs
    }

    m_headerBar->hide();
    m_actionBar->hide();
    if (m_mainSplitter) {
        m_mainSplitter->hide();
    }
    m_emptyLabel->show();
}

void SessionDetailWidget::clearActivities() {
    m_userBubbles.clear();
    QLayoutItem* child;
    while ((child = m_activityLayout->takeAt(0)) != nullptr) {
        if (child->widget()) {
            delete child->widget();
        }
        delete child;
    }
}

bool SessionDetailWidget::isEmpty() const {
    return !m_session.has_value();
}

QString SessionDetailWidget::displayedText() const {
    if (!m_session.has_value()) {
        return QString();
    }

    QString text = m_titleLabel->text() + "\n" + m_session->prompt;
    if (m_subtitleLabel && !m_subtitleLabel->text().isEmpty()) {
        text += "\n" + m_subtitleLabel->text();
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
    // Count actual widgets, minus the trailing stretch
    int count = m_activityLayout->count();
    // The last item is a stretch spacer added in populateActivities
    if (count > 0) {
        QLayoutItem* last = m_activityLayout->itemAt(count - 1);
        if (last && !last->widget()) {
            count--;  // Subtract the stretch item
        }
    }
    return count;
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

void SessionDetailWidget::toggleDiffPanel() {
    if (!m_mainSplitter) return;

    m_diffCollapsed = !m_diffCollapsed;

    if (m_diffCollapsed) {
        // Save current sizes before collapsing
        m_savedDiffSplitterSizes = m_mainSplitter->sizes();
        // Collapse diff panel (index 1) to 0
        QList<int> collapsed;
        int total = m_savedDiffSplitterSizes[0] + m_savedDiffSplitterSizes[1];
        collapsed << total << 0;
        m_mainSplitter->setSizes(collapsed);
        m_diffToggleBtn->setText(QString::fromUtf8("\u00AB")); // « = diff hidden, click to show
        m_diffToggleBtn->setToolTip("Show Diff Panel");
    } else {
        // Restore saved sizes
        if (!m_savedDiffSplitterSizes.isEmpty() && m_savedDiffSplitterSizes.size() == 2) {
            m_mainSplitter->setSizes(m_savedDiffSplitterSizes);
        } else {
            m_mainSplitter->setSizes(QList<int>() << 400 << 600);
        }
        m_diffToggleBtn->setText(QString::fromUtf8("\u00BB")); // » = diff visible, click to hide
        m_diffToggleBtn->setToolTip("Hide Diff Panel");
    }
}

QString SessionDetailWidget::formatTimeAgo(const QDateTime& created) {
    if (!created.isValid()) {
        return QString();
    }

    qint64 secs = created.secsTo(QDateTime::currentDateTimeUtc());
    if (secs < 0) secs = 0;

    if (secs < 60) {
        return QStringLiteral("Just now");
    } else if (secs < 3600) {
        int mins = static_cast<int>(secs / 60);
        return QString("%1 min ago").arg(mins);
    } else if (secs < 86400) {
        int hours = static_cast<int>(secs / 3600);
        return QString("%1 hour%2 ago").arg(hours).arg(hours == 1 ? "" : "s");
    } else if (secs < 172800) {
        return QStringLiteral("Yesterday");
    } else {
        return created.toString("MMM d");
    }
}

void SessionDetailWidget::updateTimeAgo() {
    if (!m_session.has_value() || !m_session->createTime.has_value()) {
        return;
    }
    QDateTime created = QDateTime::fromString(m_session->createTime.value(), Qt::ISODate);
    if (!created.isValid()) {
        created = QDateTime::fromString(m_session->createTime.value(), Qt::ISODateWithMs);
    }
    if (created.isValid()) {
        m_timeAgoLabel->setText(formatTimeAgo(created));
    }
}

void SessionDetailWidget::updateDisplay() {
    if (!m_session.has_value()) {
        return;
    }

    bool isDark = palette().window().color().lightness() < 128;
    const Session& session = m_session.value();

    // Header bar background + bottom border
    m_headerBar->setStyleSheet(QString(
        "QWidget { background-color: %1; border-bottom: 1px solid %2; }")
        .arg(AppColors::background(isDark).name())
        .arg(AppColors::separator(isDark).name()));

    // Title - 13pt Medium, single line, elided
    QString title = session.title.value_or(session.prompt.left(50));
    m_titleLabel->setText(title);
    m_titleLabel->setTextFormat(Qt::PlainText);
    QFontMetrics fm(m_titleLabel->font());
    m_titleLabel->setStyleSheet(QString("color: %1; border: none;").arg(AppColors::textPrimary(isDark).name()));

    // Subtitle: repo(link) · branch · +N(green) -M(red)
    QColor secondaryColor = AppColors::textSecondary(isDark);
    QColor addedColor = AppColors::linesAdded(isDark);
    QColor removedColor = AppColors::linesRemoved(isDark);
    QString sep = QString(" <span style='color:%1;'>&middot;</span> ").arg(secondaryColor.name());

    QStringList htmlParts;

    // Repo as hyperlink
    if (session.sourceContext.has_value()) {
        QString source = session.sourceContext->source;
        source = source.replace("sources/github/", "");
        QString repoUrl = QString("https://github.com/%1").arg(source);
        htmlParts.append(QString("<a href='%1' style='color:%2; text-decoration:none;'>%3</a>")
            .arg(repoUrl).arg(AppColors::accent(isDark).name()).arg(source.toHtmlEscaped()));

        if (session.sourceContext->githubRepoContext.has_value() &&
            session.sourceContext->githubRepoContext->startingBranch.has_value()) {
            htmlParts.append(QString("<span style='color:%1;'>%2</span>")
                .arg(secondaryColor.name())
                .arg(session.sourceContext->githubRepoContext->startingBranch.value().toHtmlEscaped()));
        }
    }

    // Colored git stats
    QString gitStats = session.gitStatsSummary();
    if (!gitStats.isEmpty()) {
        QString statsHtml;
        for (const QString& comp : gitStats.split(' ')) {
            if (comp.startsWith('+')) {
                statsHtml += QString("<span style='color:%1;'>%2</span> ").arg(addedColor.name()).arg(comp.toHtmlEscaped());
            } else if (comp.startsWith('-')) {
                statsHtml += QString("<span style='color:%1;'>%2</span> ").arg(removedColor.name()).arg(comp.toHtmlEscaped());
            }
        }
        htmlParts.append(statsHtml.trimmed());
    }

    if (!htmlParts.isEmpty()) {
        m_subtitleLabel->setText(htmlParts.join(sep));
        m_subtitleLabel->setStyleSheet(QString("color: %1; border: none;").arg(secondaryColor.name()));
        m_subtitleLabel->show();
    } else {
        m_subtitleLabel->clear();
        m_subtitleLabel->hide();
    }

    // State badge with proper colors
    QString stateText = stateToDisplayText(session.state);
    m_stateLabel->setText(stateText);

    QColor stateColor = stateToColor(session.state);
    m_stateLabel->setStyleSheet(QString(
        "background-color: %1; color: white; "
        "padding: 6px 14px; border-radius: 12px; font-size: 11px; font-weight: 500; border: none;")
        .arg(stateColor.name()));

    // Time-ago label
    if (session.createTime.has_value() && !session.createTime->isEmpty()) {
        QDateTime created = QDateTime::fromString(session.createTime.value(), Qt::ISODate);
        if (!created.isValid()) {
            // Try alternative format (Google API format with Z suffix)
            created = QDateTime::fromString(session.createTime.value(), Qt::ISODateWithMs);
        }
        QString timeAgo = formatTimeAgo(created);
        m_timeAgoLabel->setText(timeAgo);
        m_timeAgoLabel->setStyleSheet(QString("color: %1; border: none;").arg(secondaryColor.name()));
        m_timeAgoLabel->show();
    } else {
        m_timeAgoLabel->clear();
        m_timeAgoLabel->hide();
    }

    // PR button styling
    bool hasPR = hasPullRequestLink();
    m_pullRequestBtn->setVisible(hasPR);
    if (hasPR) {
        QColor prColor = AppColors::running(isDark);
        m_pullRequestBtn->setStyleSheet(QString(
            "QPushButton { background-color: %1; color: white; padding: 6px 14px; "
            "border-radius: 12px; font-size: 11px; font-weight: 500; border: none; }"
            "QPushButton:hover { background-color: %2; }")
            .arg(prColor.name()).arg(prColor.darker(110).name()));
    }

    // Diff toggle button styling
    if (m_diffToggleBtn) {
        QColor borderColor = AppColors::separator(isDark);
        QColor textColor = AppColors::textSecondary(isDark);
        m_diffToggleBtn->setStyleSheet(QString(
            "QPushButton { background-color: transparent; color: %1; "
            "border: 1px solid %2; border-radius: 6px; font-size: 14px; font-weight: bold; }"
            "QPushButton:hover { background-color: rgba(128, 128, 128, 0.15); }")
            .arg(textColor.name()).arg(borderColor.name()));
    }
}

void SessionDetailWidget::populateActivities() {
    clearActivities();

    if (!m_session.has_value()) {
        m_activityLayout->addStretch();
        return;
    }

    bool isDark = palette().window().color().lightness() < 128;

    // === Prepend prompt as first bubble (user message style) ===
    if (!m_session->prompt.isEmpty()) {
        auto* itemWidget = new QWidget();
        auto* itemLayout = new QHBoxLayout(itemWidget);
        itemLayout->setContentsMargins(0, 6, 0, 6);

        auto* bubbleContainer = new QWidget();
        auto* bubbleVLayout = new QVBoxLayout(bubbleContainer);
        bubbleVLayout->setContentsMargins(0, 0, 0, 0);
        bubbleVLayout->setSpacing(4);
        bubbleContainer->setMaximumWidth(static_cast<int>(width() * 0.8));
        m_userBubbles.append(bubbleContainer);

        auto* bubble = new QLabel();
        bubble->setTextFormat(Qt::RichText);
        bubble->setWordWrap(true);
        bubble->setTextInteractionFlags(Qt::TextSelectableByMouse | Qt::LinksAccessibleByMouse);
        bubble->setOpenExternalLinks(true);

        // Check if truncation is needed
        QString promptText = m_session->prompt;
        bool needsTruncation = isTruncatable(promptText) && !m_promptExpanded;
        QString displayText = needsTruncation ? truncateText(promptText) : promptText;
        bubble->setText(markdownToHtml(displayText, isDark));

        QColor bubbleBg = AppColors::accent(isDark);
        bubble->setStyleSheet(QString(
            "background-color: %1; color: white; "
            "padding: 12px 16px; border-radius: 18px; font-size: 13px; "
            "border: none;")
            .arg(bubbleBg.name()));

        bubbleVLayout->addWidget(bubble);

        // Add Read More button if truncated
        if (needsTruncation) {
            auto* readMoreBtn = new QPushButton("Read More");
            readMoreBtn->setFlat(true);
            readMoreBtn->setCursor(Qt::PointingHandCursor);
            readMoreBtn->setStyleSheet(QString(
                "QPushButton { color: %1; font-size: 11px; font-weight: 500; padding: 2px 0px; border: none; background: transparent; text-align: right; }"
                "QPushButton:hover { text-decoration: underline; }")
                .arg(QColor(255, 255, 255).name()));

            QString fullHtml = markdownToHtml(promptText, isDark);
            connect(readMoreBtn, &QPushButton::clicked, [bubble, readMoreBtn, fullHtml]() {
                bubble->setText(fullHtml);
                readMoreBtn->hide();
            });

            bubbleVLayout->addWidget(readMoreBtn);
        }

        // Right-aligned (user bubble)
        itemLayout->addStretch();
        itemLayout->addWidget(bubbleContainer);

        m_activityLayout->addWidget(itemWidget);
    }

    // === Activities ===
    if (!m_session->activities.has_value()) {
        m_activityLayout->addStretch();
        return;
    }

    // Find the latest progressUpdated activity ID (Mac app skips only this one,
    // showing it as a live indicator instead; earlier progress activities render inline)
    const auto& allActivities = m_session->activities.value();
    QString latestProgressId;
    for (auto it = allActivities.rbegin(); it != allActivities.rend(); ++it) {
        if (it->progressUpdated.has_value()) {
            latestProgressId = it->id;
            break;
        }
    }

    for (const auto& activity : allActivities) {
        // Special handling for plan generated activities
        if (activity.planGenerated.has_value()) {
            // Build a single HTML bullet list from plan steps
            const auto& steps = activity.planGenerated->plan.steps;
            QString html;
            html += QString("<b style='font-size: 13px;'>Created Plan</b><br><ul style='margin: 4px 0; padding-left: 20px;'>");
            for (const auto& step : steps) {
                QString stepTitle = step.title.value_or("Untitled Step");
                QString stepHtml = markdownToHtml(stepTitle, isDark);
                html += QString("<li style='margin: 2px 0;'>%1</li>").arg(stepHtml);
            }
            html += "</ul>";

            auto* planContainer = new QWidget();
            auto* planOuterLayout = new QHBoxLayout(planContainer);
            planOuterLayout->setContentsMargins(0, 6, 0, 6);

            auto* planLabel = new QLabel(planContainer);
            planLabel->setTextFormat(Qt::RichText);
            planLabel->setWordWrap(true);
            planLabel->setTextInteractionFlags(Qt::TextSelectableByMouse | Qt::LinksAccessibleByMouse);
            planLabel->setOpenExternalLinks(true);
            planLabel->setText(html);

            QColor bubbleBg = AppColors::backgroundSecondary(isDark);
            QColor bubbleText = AppColors::textPrimary(isDark);
            QColor borderColor = AppColors::separator(isDark);
            borderColor.setAlphaF(0.5);

            planLabel->setStyleSheet(QString(
                "background-color: %1; color: %2; "
                "padding: 14px 18px; border-radius: 16px; font-size: 13px; "
                "border: 1px solid %3;")
                .arg(bubbleBg.name())
                .arg(bubbleText.name())
                .arg(borderColor.name(QColor::HexArgb)));

            planOuterLayout->addWidget(planLabel, 1);
            m_activityLayout->addWidget(planContainer);
            continue;
        }

        // Styled completion/failure banners
        if (activity.sessionCompleted.has_value() || activity.sessionFailed.has_value()) {
            bool isCompleted = activity.sessionCompleted.has_value();
            QString bannerText = isCompleted
                ? "Session completed"
                : QString("Session failed: %1").arg(
                    activity.sessionFailed->reason.value_or("Unknown error"));

            QColor bannerTextColor = isCompleted
                ? AppColors::running(isDark)
                : AppColors::destructive(isDark);

            QColor bannerBg = bannerTextColor;
            bannerBg.setAlphaF(0.15);

            auto* bannerWidget = new QWidget();
            auto* bannerLayout = new QHBoxLayout(bannerWidget);
            bannerLayout->setContentsMargins(0, 8, 0, 8);

            auto* bannerLabel = new QLabel(bannerText, bannerWidget);
            bannerLabel->setAlignment(Qt::AlignCenter);
            bannerLabel->setWordWrap(true);
            bannerLabel->setStyleSheet(QString(
                "background-color: %1; color: %2; "
                "padding: 12px 20px; border-radius: 12px; font-size: 13px; font-weight: 500;")
                .arg(bannerBg.name(QColor::HexArgb))
                .arg(bannerTextColor.name()));

            bannerLayout->addWidget(bannerLabel, 1);
            m_activityLayout->addWidget(bannerWidget);
            continue;
        }

        // Skip the latest progress activity (Mac app shows it as a live indicator).
        // Older progress activities with descriptions are rendered inline.
        if (activity.progressUpdated.has_value()) {
            if (activity.id == latestProgressId) {
                continue;  // Skip the live/latest one
            }
            // Skip progress activities with no meaningful description
            QString desc = activity.generatedDescription.value_or(
                activity.progressUpdated->description.value_or(""));
            if (desc.isEmpty()) {
                continue;
            }
        }

        QString text = formatActivityText(activity);
        if (!text.isEmpty()) {
            // Create a custom widget for the activity item (message bubble style)
            auto* itemWidget = new QWidget();
            auto* itemLayout = new QHBoxLayout(itemWidget);
            itemLayout->setContentsMargins(0, 6, 0, 6);

            bool isUser = activity.userMessaged.has_value();

            // Container for bubble + optional Read More button
            auto* bubbleContainer = new QWidget();
            auto* bubbleVLayout = new QVBoxLayout(bubbleContainer);
            bubbleVLayout->setContentsMargins(0, 0, 0, 0);
            bubbleVLayout->setSpacing(4);

            auto* bubble = new QLabel();
            bubble->setTextFormat(Qt::RichText);
            bubble->setWordWrap(true);
            bubble->setTextInteractionFlags(Qt::TextSelectableByMouse | Qt::LinksAccessibleByMouse);
            bubble->setOpenExternalLinks(true);

            if (isUser) {
                // User messages: 80% max width, track for resize updates
                bubbleContainer->setMaximumWidth(static_cast<int>(width() * 0.8));
                m_userBubbles.append(bubbleContainer);
            }
            // Agent messages: no max width, full available width

            // Check if truncation is needed
            bool needsTruncation = isTruncatable(text);
            QString displayText = needsTruncation ? truncateText(text) : text;
            bubble->setText(markdownToHtml(displayText, isDark));

            // User messages: accent background, white text
            // Agent messages: secondary background, primary text
            QColor bubbleBg = isUser
                ? AppColors::accent(isDark)
                : AppColors::backgroundSecondary(isDark);
            QColor bubbleText = isUser
            ? Qt::white  // White for user bubbles
                : AppColors::textPrimary(isDark);

            int borderRadius = isUser ? 18 : 16;
            int paddingV = isUser ? 12 : 14;
            int paddingH = isUser ? 16 : 18;

            // Subtle 1px border on agent bubbles for definition
            QColor borderColor = AppColors::separator(isDark);
            borderColor.setAlphaF(isUser ? 0.0 : 0.5);

            bubble->setStyleSheet(QString(
                "background-color: %1; color: %2; "
                "padding: %3px %4px; border-radius: %5px; font-size: 13px; "
                "border: 1px solid %6;")
                .arg(bubbleBg.name())
                .arg(bubbleText.name())
                .arg(paddingV)
                .arg(paddingH)
                .arg(borderRadius)
                .arg(borderColor.name(QColor::HexArgb)));

            // Activity title badge for agent messages (prefer generatedTitle > title > progressUpdated title)
            if (!isUser) {
                QString badgeText;
                if (activity.generatedTitle.has_value() && !activity.generatedTitle->isEmpty()) {
                    badgeText = activity.generatedTitle.value();
                } else if (activity.title.has_value() && !activity.title->isEmpty()) {
                    badgeText = activity.title.value();
                } else if (activity.progressUpdated.has_value() &&
                           activity.progressUpdated->title.has_value() &&
                           !activity.progressUpdated->title->isEmpty()) {
                    badgeText = activity.progressUpdated->title.value();
                }
                if (!badgeText.isEmpty()) {
                    auto* titleBadge = new QLabel(badgeText);
                    titleBadge->setWordWrap(false);
                    QFont badgeFont = titleBadge->font();
                    badgeFont.setPointSize(10);
                    titleBadge->setFont(badgeFont);
                    titleBadge->setStyleSheet(QString(
                        "background-color: %1; color: %2; padding: 3px 8px; "
                        "border-radius: 4px; font-size: 10px;")
                        .arg(AppColors::backgroundDark(isDark).name())
                        .arg(AppColors::textSecondary(isDark).name()));
                    titleBadge->setMaximumWidth(static_cast<int>(width() * 0.7));
                    QFontMetrics badgeFm(badgeFont);
                    titleBadge->setText(badgeFm.elidedText(badgeText, Qt::ElideRight, titleBadge->maximumWidth()));
                    bubbleVLayout->addWidget(titleBadge);
                }
            }

            bubbleVLayout->addWidget(bubble);

            // Add Read More button if truncated
            if (needsTruncation) {
                auto* readMoreBtn = new QPushButton("Read More");
                readMoreBtn->setFlat(true);
                readMoreBtn->setCursor(Qt::PointingHandCursor);
                QColor accentColor = AppColors::accent(isDark);
                readMoreBtn->setStyleSheet(QString(
                    "QPushButton { color: %1; font-size: 11px; font-weight: 500; padding: 2px 0px; border: none; background: transparent; text-align: %2; }"
                    "QPushButton:hover { text-decoration: underline; }")
                    .arg(accentColor.name())
                    .arg(isUser ? "right" : "left"));

                // Store full text for expansion
                QString fullHtml = markdownToHtml(text, isDark);
                connect(readMoreBtn, &QPushButton::clicked, [bubble, readMoreBtn, fullHtml]() {
                    bubble->setText(fullHtml);
                    readMoreBtn->hide();
                });

                bubbleVLayout->addWidget(readMoreBtn);
            }

            if (isUser) {
                // Right-aligned user bubble
                itemLayout->addStretch();
                itemLayout->addWidget(bubbleContainer);
            } else {
                // Full-width agent bubble
                itemLayout->addWidget(bubbleContainer, 1);
            }

            m_activityLayout->addWidget(itemWidget);
        }
    }

    // Keep items top-aligned
    m_activityLayout->addStretch();

    // Smooth animated scroll to bottom (defer to let layout calculate)
    QTimer::singleShot(0, this, [this]() {
        if (m_scrollArea && isVisible()) {
            auto* bar = m_scrollArea->verticalScrollBar();
            int startVal = bar->value();
            int endVal = bar->maximum();
            if (startVal < endVal) {
                auto* anim = new QPropertyAnimation(bar, "value", this);
                anim->setDuration(300);
                anim->setStartValue(startVal);
                anim->setEndValue(endVal);
                anim->setEasingCurve(QEasingCurve::OutCubic);
                anim->start(QAbstractAnimation::DeleteWhenStopped);
            }
        }
    });
}

QString SessionDetailWidget::formatActivityText(const Activity& activity) const {
    QString text;

    if (activity.userMessaged.has_value()) {
        text = activity.userMessaged->userMessage;
    } else if (activity.agentMessaged.has_value()) {
        text = activity.agentMessaged->agentMessage;
    } else if (activity.progressUpdated.has_value()) {
        // Prefer generatedDescription over original description (matches Mac app)
        text = activity.generatedDescription.value_or(
            activity.progressUpdated->description.value_or(""));
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

QString SessionDetailWidget::markdownToHtml(const QString& markdown, bool isDark) const {
    QString codeBg = isDark ? "rgba(255,255,255,0.08)" : "rgba(0,0,0,0.06)";
    QString accentLightColor = AppColors::accentLight(isDark).name();
    QString textColor = AppColors::textPrimary(isDark).name();
    QString secondaryColor = AppColors::textSecondary(isDark).name();
    QString accentColor = AppColors::accent(isDark).name();
    QString quoteBorder = isDark ? "rgba(255,255,255,0.15)" : "rgba(0,0,0,0.15)";

    // Split into lines, process code blocks separately
    QStringList lines = markdown.split('\n');
    QStringList resultLines;
    bool inCodeBlock = false;
    QStringList codeBlockLines;

    for (const QString& rawLine : lines) {
        // Check for code block fence
        if (rawLine.trimmed().startsWith("```")) {
            if (!inCodeBlock) {
                inCodeBlock = true;
                codeBlockLines.clear();
                continue;
            } else {
                // End of code block - emit as <pre>
                QString codeContent = codeBlockLines.join('\n').toHtmlEscaped();
                resultLines.append(QString("<pre style='background-color: %1; color: %2; padding: 8px; border-radius: 4px; font-family: monospace;'>%3</pre>")
                    .arg(codeBg, accentLightColor, codeContent));
                inCodeBlock = false;
                continue;
            }
        }

        if (inCodeBlock) {
            codeBlockLines.append(rawLine);
            continue;
        }

        // Process non-code-block lines
        QString line = rawLine.toHtmlEscaped();

        // Horizontal rules (--- or ***)
        static QRegularExpression hrRe(R"(^(\-\-\-|\*\*\*)$)");
        if (hrRe.match(line).hasMatch()) {
            resultLines.append(QString("<hr style='border: none; border-top: 1px solid %1; margin: 8px 0;'>").arg(quoteBorder));
            continue;
        }

        // Headers (### before ## before #)
        static QRegularExpression h3Re(R"(^### (.+)$)");
        static QRegularExpression h2Re(R"(^## (.+)$)");
        static QRegularExpression h1Re(R"(^# (.+)$)");
        auto h3Match = h3Re.match(line);
        if (h3Match.hasMatch()) {
            resultLines.append(QString("<h3 style='color: %1; margin: 12px 0 6px;'>%2</h3>").arg(textColor, h3Match.captured(1)));
            continue;
        }
        auto h2Match = h2Re.match(line);
        if (h2Match.hasMatch()) {
            resultLines.append(QString("<h2 style='color: %1; margin: 14px 0 8px;'>%2</h2>").arg(textColor, h2Match.captured(1)));
            continue;
        }
        auto h1Match = h1Re.match(line);
        if (h1Match.hasMatch()) {
            resultLines.append(QString("<h1 style='color: %1; margin: 16px 0 10px;'>%2</h1>").arg(textColor, h1Match.captured(1)));
            continue;
        }

        // Blockquotes (> text)
        static QRegularExpression bqRe(R"(^&gt; (.+)$)");
        auto bqMatch = bqRe.match(line);
        if (bqMatch.hasMatch()) {
            resultLines.append(QString("<blockquote style='border-left: 3px solid %1; padding-left: 12px; margin: 4px 0; color: %2;'>%3</blockquote>")
                .arg(quoteBorder, secondaryColor, bqMatch.captured(1)));
            continue;
        }

        // Bullet lists (- item or * item)
        bool lineHandled = false;
        static QRegularExpression ulRe(R"(^( *)([\-\*]) (.+)$)");
        auto ulMatch = ulRe.match(line);
        if (ulMatch.hasMatch()) {
            int indent = ulMatch.captured(1).length();
            resultLines.append(QString("<li style='margin-left: %1px;'>%2</li>")
                .arg(16 + indent * 8).arg(ulMatch.captured(3)));
            lineHandled = true;
        }

        // Numbered lists (1. item)
        if (!lineHandled) {
            static QRegularExpression olRe(R"(^( *)(\d+)\. (.+)$)");
            auto olMatch = olRe.match(line);
            if (olMatch.hasMatch()) {
                int indent = olMatch.captured(1).length();
                resultLines.append(QString("<li style='margin-left: %1px;'>%2</li>")
                    .arg(16 + indent * 8).arg(olMatch.captured(3)));
                lineHandled = true;
            }
        }

        // Plain text line - add as-is
        if (!lineHandled) {
            resultLines.append(line);
        }

        // Apply inline formatting to the last line
        QString& lastLine = resultLines.last();

        // Inline code
        static QRegularExpression inlineCodeRe(R"(`([^`]+)`)");
        lastLine.replace(inlineCodeRe, QString("<code style='background-color: %1; color: %2; padding: 2px 4px; border-radius: 2px; font-family: monospace;'>\\1</code>").arg(codeBg).arg(accentLightColor));

        // Links [text](url) - avoid matching images ![alt](url)
        static QRegularExpression linkRe(R"((?<!\!)\[([^\]]+)\]\(([^\)]+)\))");
        lastLine.replace(linkRe, QString("<a href='\\2' style='color: %1;'>\\1</a>").arg(accentColor));

        // Images ![alt](url) - just show as a link for now
        static QRegularExpression imgRe(R"(\!\[([^\]]+)\]\(([^\)]+)\))");
        lastLine.replace(imgRe, QString("<a href='\\2' style='color: %1;'>🖼 \\1</a>").arg(accentColor));

        // Bold (**text** or __text__)
        static QRegularExpression boldRe(R"(\*\*([^\*]+)\*\*)");
        lastLine.replace(boldRe, "<b>\\1</b>");
        static QRegularExpression boldRe2(R"(__([^_]+)__)");
        lastLine.replace(boldRe2, "<b>\\1</b>");

        // Italic (*text* or _text_)
        static QRegularExpression italicRe(R"(\*([^\*]+)\*)");
        lastLine.replace(italicRe, "<i>\\1</i>");
        static QRegularExpression italicRe2(R"(_([^_]+)_)");
        lastLine.replace(italicRe2, "<i>\\1</i>");
    }

    // Handle unclosed code block
    if (inCodeBlock && !codeBlockLines.isEmpty()) {
        QString codeContent = codeBlockLines.join('\n').toHtmlEscaped();
        resultLines.append(QString("<pre style='background-color: %1; color: %2; padding: 8px; border-radius: 4px; font-family: monospace;'>%3</pre>")
            .arg(codeBg, accentLightColor, codeContent));
    }

    return resultLines.join("<br>");
}

bool SessionDetailWidget::isTruncatable(const QString& text) const {
    // Truncate if text is longer than 800 chars OR has 15+ newlines
    return text.length() > 800 || text.count('\n') >= 15;
}

QString SessionDetailWidget::truncateText(const QString& text, int maxLines) const {
    QStringList lines = text.split('\n');
    if (lines.size() <= maxLines) {
        // Check character limit
        if (text.length() <= 800) {
            return text;
        }
        return text.left(797) + "...";
    }

    // Take first maxLines and add ellipsis
    QStringList truncated = lines.mid(0, maxLines);
    return truncated.join('\n') + "...";
}

void SessionDetailWidget::changeEvent(QEvent* event) {
    QWidget::changeEvent(event);
    if (event->type() == QEvent::PaletteChange && m_session.has_value()) {
        updateDisplay();
        populateActivities();
    }
}

void SessionDetailWidget::resizeEvent(QResizeEvent* event) {
    QWidget::resizeEvent(event);

    // Update user bubble max widths to 80% of new panel width
    int maxWidth = static_cast<int>(event->size().width() * 0.8);
    for (auto* bubble : m_userBubbles) {
        if (bubble) {
            bubble->setMaximumWidth(maxWidth);
        }
    }
}

}
