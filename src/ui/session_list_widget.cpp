#include "ui/session_list_widget.h"
#include "ui/app_colors.h"

#include <QFrame>
#include <QFont>
#include <QIcon>
#include <QStyledItemDelegate>
#include <QPainter>
#include <QApplication>
#include <QStyleOptionViewItem>
#include <QMenu>
#include <QClipboard>

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

/**
 * SessionItemDelegate - Custom delegate for macOS-style session list rows
 * 
 * Features:
 * - Purple unviewed indicator dot
 * - Hover and selection states with proper colors
 * - Single-line truncated title
 * - Matching spacing and corner radius
 */
class SessionItemDelegate : public QStyledItemDelegate {
public:
    explicit SessionItemDelegate(QObject* parent = nullptr) 
        : QStyledItemDelegate(parent) {}
    
    void paint(QPainter* painter, const QStyleOptionViewItem& option, 
               const QModelIndex& index) const override {
        painter->save();
        painter->setRenderHint(QPainter::Antialiasing, true);
        
        // Determine theme from palette
        bool isDark = option.palette.window().color().lightness() < 128;
        
        // Check if this is a section header
        bool isHeader = index.data(Qt::UserRole + 4).toBool();
        
        if (isHeader) {
            // Render section header: smaller font, muted color, no background/hover
            QRect headerRect = option.rect.adjusted(12, 8, -8, -4);

            QString title = index.data(Qt::DisplayRole).toString();
            QColor textColor = AppColors::textSecondary(isDark);

            painter->setPen(textColor);
            QFont font = option.font;
            font.setPointSize(10);
            font.setWeight(QFont::DemiBold);
            painter->setFont(font);

            painter->drawText(headerRect, Qt::AlignLeft | Qt::AlignVCenter, title);

            // Subtle separator line below header text
            QColor sepColor = AppColors::separator(isDark);
            sepColor.setAlphaF(0.4);
            painter->setPen(QPen(sepColor, 1));
            int lineY = option.rect.bottom() - 2;
            painter->drawLine(option.rect.left() + 12, lineY, option.rect.right() - 12, lineY);

            painter->restore();
            return;
        }
        
        // Regular session item rendering
        QRect rect = option.rect.adjusted(4, 2, -4, -2);
        
        // Get item data
        bool isViewed = index.data(Qt::UserRole + 3).toBool();
        bool isSelected = option.state & QStyle::State_Selected;
        bool isHovered = option.state & QStyle::State_MouseOver;
        
        // Draw background with rounded corners (6pt radius matching macOS)
        QColor bgColor = Qt::transparent;
        if (isSelected) {
            bgColor = AppColors::selectionBackground(isDark);
        } else if (isHovered) {
            bgColor = AppColors::hoverBackground(isDark);
        }
        
        if (bgColor != Qt::transparent) {
            painter->setPen(Qt::NoPen);
            painter->setBrush(bgColor);
            painter->drawRoundedRect(rect, 6, 6);
        }
        
        // Calculate content rect
        QRect contentRect = rect.adjusted(8, 0, -8, 0);
        
        // Draw unviewed indicator (4x4 circle, colored by session state)
        if (!isViewed) {
            int sessionState = index.data(Qt::UserRole + 5).toInt();
            QColor dotColor = AppColors::stateColor(sessionState, isDark);
            painter->setPen(Qt::NoPen);
            painter->setBrush(dotColor);
            int dotY = contentRect.center().y() - 2;
            painter->drawEllipse(contentRect.left(), dotY, 4, 4);
            contentRect.setLeft(contentRect.left() + 12);
        } else {
            contentRect.setLeft(contentRect.left() + 8);
        }
        
        // Draw title text
        QString title = index.data(Qt::DisplayRole).toString();
        QColor textColor = AppColors::textPrimary(isDark);
        
        painter->setPen(textColor);
        QFont font = option.font;
        font.setPointSize(13);
        font.setWeight(QFont::Medium);
        painter->setFont(font);
        
        // Single line, truncate with ellipsis
        QFontMetrics fm(font);
        QString elidedTitle = fm.elidedText(title, Qt::ElideRight, contentRect.width());
        
        QRect textRect = contentRect;
        textRect.setHeight(contentRect.height());
        painter->drawText(textRect, Qt::AlignLeft | Qt::AlignVCenter, elidedTitle);
        
        painter->restore();
    }
    
    QSize sizeHint(const QStyleOptionViewItem& option, const QModelIndex& index) const override {
        Q_UNUSED(option);
        // Check if this is a section header
        bool isHeader = index.data(Qt::UserRole + 4).toBool();
        if (isHeader) {
            // Headers are shorter with top padding
            return QSize(200, 28);
        }
        // Row height: 8pt vertical padding * 2 + text height ≈ 36px
        return QSize(200, 36);
    }
};

SessionListWidget::SessionListWidget(SessionRepository* repository, QWidget* parent)
    : QWidget(parent)
    , m_repository(repository)
    , m_listWidget(nullptr)
    , m_newButton(nullptr)
    , m_searchEdit(nullptr)
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
    
    // Header with Sessions title and + button
    auto* header = new QFrame(this);
    auto* headerLayout = new QHBoxLayout(header);
    headerLayout->setContentsMargins(16, 12, 16, 12);
    
    auto* titleLabel = new QLabel("Sessions", header);
    QFont titleFont = titleLabel->font();
    titleFont.setBold(true);
    titleFont.setPointSize(14);
    titleLabel->setFont(titleFont);
    
    m_newButton = new QPushButton("+", header);
    m_newButton->setFixedSize(28, 28);
    m_newButton->setToolTip("Create new session");
    m_newButton->setStyleSheet(R"(
        QPushButton {
            background-color: transparent;
            border: none;
            border-radius: 6px;
            font-size: 18px;
            font-weight: bold;
        }
        QPushButton:hover {
            background-color: rgba(128, 128, 128, 0.2);
        }
        QPushButton:pressed {
            background-color: rgba(128, 128, 128, 0.3);
        }
    )");
    connect(m_newButton, &QPushButton::clicked, this, &SessionListWidget::requestCreateNew);
    
    headerLayout->addWidget(titleLabel);
    headerLayout->addStretch();
    headerLayout->addWidget(m_newButton);
    
    // Search field
    m_searchEdit = new QLineEdit(this);
    m_searchEdit->setPlaceholderText("Search sessions...");
    m_searchEdit->setClearButtonEnabled(true);
    m_searchEdit->setStyleSheet(R"(
        QLineEdit {
            background-color: palette(base);
            border: 1px solid palette(mid);
            border-radius: 8px;
            padding: 6px 12px;
            font-size: 13px;
        }
        QLineEdit:focus {
            border-color: palette(highlight);
        }
    )");
    connect(m_searchEdit, &QLineEdit::textChanged,
            this, &SessionListWidget::onSearchTextChanged);
    
    // Session list with custom delegate
    m_listWidget = new QListWidget(this);
    m_listWidget->setFrameShape(QFrame::NoFrame);
    m_listWidget->setSpacing(0);
    m_listWidget->setSelectionMode(QAbstractItemView::SingleSelection);
    m_listWidget->setMouseTracking(true);  // Enable hover states
    m_listWidget->setItemDelegate(new SessionItemDelegate(m_listWidget));
    m_listWidget->setStyleSheet(R"(
        QListWidget {
            background-color: transparent;
            border: none;
            outline: none;
        }
        QListWidget::item {
            background-color: transparent;
            border: none;
            padding: 0px;
        }
        QListWidget::item:selected {
            background-color: transparent;
        }
        QListWidget::item:hover {
            background-color: transparent;
        }
    )");
    connect(m_listWidget, &QListWidget::itemClicked,
            this, &SessionListWidget::onItemClicked);

    m_listWidget->setContextMenuPolicy(Qt::CustomContextMenu);
    connect(m_listWidget, &QListWidget::customContextMenuRequested,
            this, &SessionListWidget::showContextMenu);
    
    m_emptyLabel = new QLabel("No sessions yet.\nPress Ctrl+N to create one.", this);
    m_emptyLabel->setAlignment(Qt::AlignCenter);
    m_emptyLabel->setStyleSheet("color: palette(placeholderText); font-size: 15px; padding: 48px 24px;");
    m_emptyLabel->setWordWrap(true);
    
    layout->addWidget(header);
    layout->addWidget(m_listWidget, 1);
    layout->addWidget(m_emptyLabel);
    
    m_emptyLabel->hide();
    
    // Insert search field after header
    auto* searchContainer = new QWidget(this);
    auto* searchLayout = new QHBoxLayout(searchContainer);
    searchLayout->setContentsMargins(16, 0, 16, 12);
    searchLayout->addWidget(m_searchEdit);
    
    // Rearrange layout: header, search, list, empty
    layout->insertWidget(1, searchContainer);
    
    m_pollTimer = new QTimer(this);
    connect(m_pollTimer, &QTimer::timeout, 
            this, &SessionListWidget::onPollTimerTimeout);
}

int SessionListWidget::sessionCount() const {
    // Count only session items, not headers
    int count = 0;
    for (int i = 0; i < m_listWidget->count(); ++i) {
        if (!m_listWidget->item(i)->data(Qt::UserRole + 4).toBool()) {
            count++;
        }
    }
    return count;
}

// Helper to convert session index to list widget index (skipping headers)
int SessionListWidget::sessionIndexToListIndex(int sessionIndex) const {
    int sessionCount = 0;
    for (int i = 0; i < m_listWidget->count(); ++i) {
        if (!m_listWidget->item(i)->data(Qt::UserRole + 4).toBool()) {
            if (sessionCount == sessionIndex) {
                return i;
            }
            sessionCount++;
        }
    }
    return -1;  // Not found
}

QString SessionListWidget::sessionDisplayText(int index) const {
    int listIndex = sessionIndexToListIndex(index);
    if (listIndex < 0) {
        return QString();
    }
    return m_listWidget->item(listIndex)->text();
}

QString SessionListWidget::sessionIdAt(int index) const {
    int listIndex = sessionIndexToListIndex(index);
    if (listIndex < 0) {
        return QString();
    }
    return m_listWidget->item(listIndex)->data(Qt::UserRole).toString();
}

QString SessionListWidget::sessionStateIcon(int index) const {
    int listIndex = sessionIndexToListIndex(index);
    if (listIndex < 0) {
        return QString();
    }
    return m_listWidget->item(listIndex)->data(Qt::UserRole + 1).toString();
}

QString SessionListWidget::sessionStateText(int index) const {
    int listIndex = sessionIndexToListIndex(index);
    if (listIndex < 0) {
        return QString();
    }
    return m_listWidget->item(listIndex)->data(Qt::UserRole + 2).toString();
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
    m_cachedSessions = sessions;

    if (sessions.isEmpty()) {
        m_listWidget->setVisible(false);
        m_emptyLabel->setVisible(true);
        return;
    }
    
    // Categorize sessions by time period
    QList<Session> todaySessions;
    QList<Session> thisWeekSessions;
    QList<Session> olderSessions;
    
    QDateTime now = QDateTime::currentDateTime();
    QDate today = now.date();
    QDate weekStart = today.addDays(-today.dayOfWeek() + 1);  // Monday of current week
    
    for (const Session& session : sessions) {
        QDateTime createDateTime;
        if (session.createTime.has_value()) {
            createDateTime = QDateTime::fromString(session.createTime.value(), Qt::ISODate);
        }
        
        if (!createDateTime.isValid()) {
            olderSessions.append(session);
        } else if (createDateTime.date() == today) {
            todaySessions.append(session);
        } else if (createDateTime.date() >= weekStart) {
            thisWeekSessions.append(session);
        } else {
            olderSessions.append(session);
        }
    }
    
    int itemIndex = 0;
    
    // Add Today section
    if (!todaySessions.isEmpty()) {
        addSectionHeader("Today");
        for (const Session& session : todaySessions) {
            auto* item = new QListWidgetItem(m_listWidget);
            updateSessionItem(item, session);
            m_sessionIndexMap[session.id] = itemIndex++;
        }
    }
    
    // Add This Week section
    if (!thisWeekSessions.isEmpty()) {
        addSectionHeader("This Week");
        for (const Session& session : thisWeekSessions) {
            auto* item = new QListWidgetItem(m_listWidget);
            updateSessionItem(item, session);
            m_sessionIndexMap[session.id] = itemIndex++;
        }
    }
    
    // Add Older section
    if (!olderSessions.isEmpty()) {
        addSectionHeader("Older");
        for (const Session& session : olderSessions) {
            auto* item = new QListWidgetItem(m_listWidget);
            updateSessionItem(item, session);
            m_sessionIndexMap[session.id] = itemIndex++;
        }
    }
    
    m_listWidget->setVisible(true);
    m_emptyLabel->setVisible(false);
}

void SessionListWidget::addSectionHeader(const QString& title) {
    auto* headerItem = new QListWidgetItem(title.toUpper(), m_listWidget);
    headerItem->setFlags(Qt::NoItemFlags);  // Not selectable
    headerItem->setData(Qt::UserRole + 4, true);  // Mark as header
    
    // Style the header - 10pt semibold, uppercase, secondary color
    QFont headerFont = headerItem->font();
    headerFont.setPointSize(10);
    headerFont.setWeight(QFont::DemiBold);
    headerItem->setFont(headerFont);
    
    // Use AppColors::textSecondary for proper theming
    bool isDark = palette().window().color().lightness() < 128;
    QColor headerColor = AppColors::textSecondary(isDark);
    headerItem->setForeground(headerColor);
}

void SessionListWidget::updateSessionItem(QListWidgetItem* item, const Session& session) {
    // Use title if available, otherwise use truncated prompt
    QString displayText = session.title.value_or(session.prompt);
    if (displayText.length() > 50) {
        displayText = displayText.left(47) + "...";
    }
    
    item->setText(displayText);
    item->setData(Qt::UserRole, session.id);
    item->setData(Qt::UserRole + 1, STATE_ICONS.value(session.state, ":/icons/unknown.svg"));
    item->setData(Qt::UserRole + 2, stateToText(session.state));
    item->setData(Qt::UserRole + 3, session.isViewed());  // For custom delegate
    item->setData(Qt::UserRole + 5, static_cast<int>(session.state));  // For state-colored indicator
    item->setToolTip(QString("%1\n\nState: %2\nCreated: %3")
                         .arg(session.prompt)
                         .arg(stateToText(session.state))
                         .arg(session.createTime.value_or("Unknown")));
}

void SessionListWidget::selectSession(int index) {
    int listIndex = sessionIndexToListIndex(index);
    if (listIndex >= 0) {
        m_listWidget->setCurrentRow(listIndex);
        QString sessionId = sessionIdAt(index);
        emit sessionSelected(sessionId);
    }
}

void SessionListWidget::navigateUp() {
    int current = m_listWidget->currentRow();
    int target = current - 1;
    // Skip header items
    while (target >= 0 && m_listWidget->item(target)->data(Qt::UserRole + 4).toBool()) {
        target--;
    }
    if (target >= 0) {
        m_listWidget->setCurrentRow(target);
    }
}

void SessionListWidget::navigateDown() {
    int current = m_listWidget->currentRow();
    int target = current + 1;
    // Skip header items
    while (target < m_listWidget->count() && m_listWidget->item(target)->data(Qt::UserRole + 4).toBool()) {
        target++;
    }
    if (target < m_listWidget->count()) {
        m_listWidget->setCurrentRow(target);
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
        int sessionIndex = m_sessionIndexMap[id];
        int listIndex = sessionIndexToListIndex(sessionIndex);
        if (listIndex >= 0 && listIndex < m_listWidget->count()) {
            updateSessionItem(m_listWidget->item(listIndex), session.value());
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
    // Use AppColors for consistency
    bool isDark = palette().window().color().lightness() < 128;
    return AppColors::stateColor(static_cast<int>(state), isDark);
}

void SessionListWidget::setSearchText(const QString& text) {
    m_searchEdit->setText(text);
}

QString SessionListWidget::searchText() const {
    return m_searchText;
}

void SessionListWidget::clearSearch() {
    m_searchEdit->clear();
    m_searchText.clear();
    applySearchFilter();
}

void SessionListWidget::onSearchTextChanged(const QString& text) {
    m_searchText = text;
    applySearchFilter();
}

void SessionListWidget::applySearchFilter() {
    if (m_searchText.isEmpty()) {
        // Show all items
        for (int i = 0; i < m_listWidget->count(); ++i) {
            m_listWidget->item(i)->setHidden(false);
        }
        return;
    }
    
    QString searchLower = m_searchText.toLower();
    if (m_cachedSessions.isEmpty()) {
        m_cachedSessions = m_repository->getAllSessions();
    }
    const QList<Session>& sessions = m_cachedSessions;
    
    // Track which section headers should be visible
    bool currentSectionHasVisibleItems = false;
    QListWidgetItem* currentHeader = nullptr;
    
    for (int i = 0; i < m_listWidget->count(); ++i) {
        QListWidgetItem* item = m_listWidget->item(i);
        bool isHeader = item->data(Qt::UserRole + 4).toBool();
        
        if (isHeader) {
            // Hide header initially, show if any items below it are visible
            if (currentHeader) {
                currentHeader->setHidden(!currentSectionHasVisibleItems);
            }
            currentHeader = item;
            currentSectionHasVisibleItems = false;
        } else {
            QString sessionId = item->data(Qt::UserRole).toString();
            
            // Find the session and check if it matches
            bool matches = false;
            for (const Session& session : sessions) {
                if (session.id == sessionId) {
                    matches = sessionMatchesSearch(session);
                    break;
                }
            }
            
            item->setHidden(!matches);
            if (matches) {
                currentSectionHasVisibleItems = true;
            }
        }
    }
    
    // Handle last section header
    if (currentHeader) {
        currentHeader->setHidden(!currentSectionHasVisibleItems);
    }
    
    // Check if any items are visible
    bool anyVisible = false;
    for (int i = 0; i < m_listWidget->count(); ++i) {
        if (!m_listWidget->item(i)->isHidden()) {
            anyVisible = true;
            break;
        }
    }
    
    // Show/hide empty state based on filter results
    if (!anyVisible && !sessions.isEmpty()) {
        m_emptyLabel->setText("No matching sessions found.");
        m_emptyLabel->setVisible(true);
        m_listWidget->setVisible(false);
    } else {
        m_emptyLabel->setText("No sessions yet.\nPress Ctrl+N to create one.");
        m_emptyLabel->setVisible(sessions.isEmpty());
        m_listWidget->setVisible(!sessions.isEmpty());
    }
}

void SessionListWidget::showContextMenu(const QPoint& pos) {
    QListWidgetItem* item = m_listWidget->itemAt(pos);
    if (!item || item->data(Qt::UserRole + 4).toBool()) return;

    QString sessionId = item->data(Qt::UserRole).toString();
    QMenu menu(this);
    menu.addAction("Open in Browser", [this, sessionId]() {
        emit openInBrowserRequested(sessionId);
    });
    menu.addAction("Copy Session ID", [sessionId]() {
        QApplication::clipboard()->setText(sessionId);
    });
    menu.addSeparator();
    menu.addAction("Refresh", [this]() {
        refresh();
    });
    menu.exec(m_listWidget->mapToGlobal(pos));
}

bool SessionListWidget::sessionMatchesSearch(const Session& session) const {
    if (m_searchText.isEmpty()) {
        return true;
    }
    
    QString searchLower = m_searchText.toLower();
    
    // Check title
    if (session.title.has_value() && 
        session.title.value().toLower().contains(searchLower)) {
        return true;
    }
    
    // Check prompt
    if (session.prompt.toLower().contains(searchLower)) {
        return true;
    }
    
    // Check source context
    if (session.sourceContext.has_value() &&
        session.sourceContext->source.toLower().contains(searchLower)) {
        return true;
    }
    
    return false;
}

}
