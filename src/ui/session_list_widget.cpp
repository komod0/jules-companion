#include "ui/session_list_widget.h"

#include <QFrame>
#include <QFont>
#include <QIcon>

namespace jules {

namespace {
const int DEFAULT_POLLING_INTERVAL_MS = 10000;

const QMap<SessionState, QString> STATE_ICONS = {
    {SessionState::Queued, ":/icons/clock.svg"},
    {SessionState::Planning, ":/icons/planning.svg"},
    {SessionState::InProgress, ":/icons/progress.svg"},
    {SessionState::Completed, ":/icons/check.svg"},
    {SessionState::Failed, ":/icons/error.svg"},
    {SessionState::Paused, ":/icons/pause.svg"},
    {SessionState::AwaitingUserFeedback, ":/icons/question.svg"},
    {SessionState::AwaitingPlanApproval, ":/icons/approval.svg"}
};

const QMap<SessionState, QString> STATE_TEXTS = {
    {SessionState::Unspecified, "Unknown"},
    {SessionState::Queued, "Queued"},
    {SessionState::Planning, "Planning"},
    {SessionState::InProgress, "In Progress"},
    {SessionState::Completed, "Completed"},
    {SessionState::CompletedUnknown, "Completed"},
    {SessionState::Failed, "Failed"},
    {SessionState::Paused, "Paused"},
    {SessionState::AwaitingUserFeedback, "Awaiting Feedback"},
    {SessionState::AwaitingPlanApproval, "Awaiting Approval"}
};
}

SessionListWidget::SessionListWidget(SessionRepository* repository, QWidget* parent)
    : QWidget(parent)
    , m_repository(repository)
    , m_listWidget(nullptr)
    , m_newButton(nullptr)
    , m_emptyLabel(nullptr)
    , m_pollTimer(nullptr)
    , m_pollingIntervalMs(DEFAULT_POLLING_INTERVAL_MS)
{
    setupUi();
    
    connect(m_repository, &SessionRepository::sessionChanged,
            this, &SessionListWidget::onSessionChanged);
    connect(m_repository, &SessionRepository::sessionDeleted,
            this, &SessionListWidget::onSessionDeleted);
    connect(m_repository, &SessionRepository::sessionsReloaded,
            this, &SessionListWidget::onSessionsReloaded);
}

SessionListWidget::~SessionListWidget() {
    stopPolling();
}

void SessionListWidget::setupUi() {
    auto* layout = new QVBoxLayout(this);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(0);
    
    auto* header = new QFrame(this);
    auto* headerLayout = new QHBoxLayout(header);
    headerLayout->setContentsMargins(12, 8, 12, 8);
    
    auto* titleLabel = new QLabel("Sessions", header);
    QFont titleFont = titleLabel->font();
    titleFont.setBold(true);
    titleFont.setPointSize(titleFont.pointSize() + 1);
    titleLabel->setFont(titleFont);
    
    m_newButton = new QPushButton("+", header);
    m_newButton->setFixedSize(24, 24);
    m_newButton->setToolTip("Create new session");
    connect(m_newButton, &QPushButton::clicked, this, &SessionListWidget::requestCreateNew);
    
    headerLayout->addWidget(titleLabel);
    headerLayout->addStretch();
    headerLayout->addWidget(m_newButton);
    
    m_listWidget = new QListWidget(this);
    m_listWidget->setFrameShape(QFrame::NoFrame);
    m_listWidget->setSpacing(2);
    m_listWidget->setSelectionMode(QAbstractItemView::SingleSelection);
    connect(m_listWidget, &QListWidget::itemClicked, 
            this, &SessionListWidget::onItemClicked);
    
    m_emptyLabel = new QLabel("No sessions yet.\nCreate a new one to get started.", this);
    m_emptyLabel->setAlignment(Qt::AlignCenter);
    m_emptyLabel->setStyleSheet("color: palette(placeholderText); padding: 24px;");
    m_emptyLabel->setWordWrap(true);
    
    layout->addWidget(header);
    layout->addWidget(m_listWidget, 1);
    layout->addWidget(m_emptyLabel);
    
    m_emptyLabel->hide();
    
    m_pollTimer = new QTimer(this);
    connect(m_pollTimer, &QTimer::timeout, 
            this, &SessionListWidget::onPollTimerTimeout);
}

int SessionListWidget::sessionCount() const {
    return m_listWidget->count();
}

QString SessionListWidget::sessionDisplayText(int index) const {
    if (index < 0 || index >= m_listWidget->count()) {
        return QString();
    }
    return m_listWidget->item(index)->text();
}

QString SessionListWidget::sessionIdAt(int index) const {
    if (index < 0 || index >= m_listWidget->count()) {
        return QString();
    }
    return m_listWidget->item(index)->data(Qt::UserRole).toString();
}

QString SessionListWidget::sessionStateIcon(int index) const {
    if (index < 0 || index >= m_listWidget->count()) {
        return QString();
    }
    return m_listWidget->item(index)->data(Qt::UserRole + 1).toString();
}

QString SessionListWidget::sessionStateText(int index) const {
    if (index < 0 || index >= m_listWidget->count()) {
        return QString();
    }
    return m_listWidget->item(index)->data(Qt::UserRole + 2).toString();
}

QString SessionListWidget::currentSessionId() const {
    auto* item = m_listWidget->currentItem();
    if (!item) {
        return QString();
    }
    return item->data(Qt::UserRole).toString();
}

void SessionListWidget::refresh() {
    populateList();
    emit refreshed();
}

void SessionListWidget::populateList() {
    m_listWidget->clear();
    m_sessionIndexMap.clear();
    
    QList<Session> sessions = m_repository->getAllSessions();
    
    for (int i = 0; i < sessions.size(); ++i) {
        const Session& session = sessions[i];
        auto* item = new QListWidgetItem(m_listWidget);
        updateSessionItem(item, session);
        m_sessionIndexMap[session.id] = i;
    }
    
    bool isEmpty = sessions.isEmpty();
    m_listWidget->setVisible(!isEmpty);
    m_emptyLabel->setVisible(isEmpty);
}

void SessionListWidget::updateSessionItem(QListWidgetItem* item, const Session& session) {
    QString displayText = session.prompt;
    if (displayText.length() > 50) {
        displayText = displayText.left(47) + "...";
    }
    
    item->setText(displayText);
    item->setData(Qt::UserRole, session.id);
    item->setData(Qt::UserRole + 1, STATE_ICONS.value(session.state, ":/icons/unknown.svg"));
    item->setData(Qt::UserRole + 2, stateToText(session.state));
    item->setIcon(stateToIcon(session.state));
    item->setToolTip(QString("%1\n\nState: %2\nCreated: %3")
                         .arg(session.prompt)
                         .arg(stateToText(session.state))
                         .arg(session.createTime.value_or("Unknown")));
    
    QColor stateColor = stateToColor(session.state);
    QFont font = item->font();
    if (session.isActive()) {
        font.setBold(true);
    }
    item->setFont(font);
}

void SessionListWidget::selectSession(int index) {
    if (index >= 0 && index < m_listWidget->count()) {
        m_listWidget->setCurrentRow(index);
        QString sessionId = sessionIdAt(index);
        emit sessionSelected(sessionId);
    }
}

void SessionListWidget::navigateUp() {
    int current = m_listWidget->currentRow();
    if (current > 0) {
        m_listWidget->setCurrentRow(current - 1);
    }
}

void SessionListWidget::navigateDown() {
    int current = m_listWidget->currentRow();
    if (current < m_listWidget->count() - 1) {
        m_listWidget->setCurrentRow(current + 1);
    }
}

void SessionListWidget::requestCreateNew() {
    emit createNewRequested();
}

QList<QString> SessionListWidget::getActiveSessionIds() const {
    QList<QString> activeIds;
    QList<Session> sessions = m_repository->getActiveSessions();
    for (const auto& session : sessions) {
        activeIds.append(session.id);
    }
    return activeIds;
}

void SessionListWidget::startPolling() {
    if (!m_pollTimer->isActive()) {
        m_pollTimer->start(m_pollingIntervalMs);
    }
}

void SessionListWidget::stopPolling() {
    m_pollTimer->stop();
}

bool SessionListWidget::isPolling() const {
    return m_pollTimer->isActive();
}

int SessionListWidget::pollingIntervalMs() const {
    return m_pollingIntervalMs;
}

void SessionListWidget::setPollingIntervalMs(int ms) {
    m_pollingIntervalMs = ms;
    if (m_pollTimer->isActive()) {
        m_pollTimer->setInterval(ms);
    }
}

void SessionListWidget::onSessionChanged(const QString& id) {
    auto session = m_repository->getSession(id);
    if (!session.has_value()) {
        return;
    }
    
    if (m_sessionIndexMap.contains(id)) {
        int index = m_sessionIndexMap[id];
        if (index < m_listWidget->count()) {
            updateSessionItem(m_listWidget->item(index), session.value());
        }
    } else {
        refresh();
    }
}

void SessionListWidget::onSessionDeleted(const QString& id) {
    Q_UNUSED(id);
    refresh();
}

void SessionListWidget::onSessionsReloaded() {
    refresh();
}

void SessionListWidget::onItemClicked(QListWidgetItem* item) {
    if (item) {
        QString sessionId = item->data(Qt::UserRole).toString();
        emit sessionSelected(sessionId);
    }
}

void SessionListWidget::onPollTimerTimeout() {
    refresh();
}

QIcon SessionListWidget::stateToIcon(SessionState state) const {
    QString iconPath = STATE_ICONS.value(state, ":/icons/unknown.svg");
    return QIcon(iconPath);
}

QString SessionListWidget::stateToText(SessionState state) const {
    return STATE_TEXTS.value(state, "Unknown");
}

QColor SessionListWidget::stateToColor(SessionState state) const {
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
