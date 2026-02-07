#include "ui/command_palette.h"

#include <QKeyEvent>
#include <QApplication>
#include <QPainter>

namespace jules {

CommandPalette::CommandPalette(QWidget* parent)
    : QWidget(parent)
{
    m_defaultActions = {
        {"new_session", "New Session", QString()},
        {"open_settings", "Open Settings", QString()},
        {"refresh_sessions", "Refresh Sessions", QString()}
    };

    setupUi();
    hide();
}

CommandPalette::~CommandPalette() = default;

void CommandPalette::setupUi()
{
    // Fill entire parent
    if (parentWidget()) {
        setGeometry(parentWidget()->rect());
    }

    // Overlay background (semi-transparent dark)
    m_overlay = this;
    setStyleSheet("background-color: rgba(0, 0, 0, 140);");

    // Centered container at top
    m_container = new QWidget(this);
    m_container->setFixedWidth(500);
    m_container->setStyleSheet(
        "QWidget#commandPaletteContainer {"
        "  background-color: #1e1e2e;"
        "  border: 1px solid #45475a;"
        "  border-radius: 8px;"
        "}"
    );
    m_container->setObjectName("commandPaletteContainer");

    m_containerLayout = new QVBoxLayout(m_container);
    m_containerLayout->setContentsMargins(8, 8, 8, 8);
    m_containerLayout->setSpacing(4);

    // Search input
    m_searchInput = new QLineEdit(m_container);
    m_searchInput->setPlaceholderText("Type a command or session name...");
    m_searchInput->setStyleSheet(
        "QLineEdit {"
        "  background-color: #313244;"
        "  color: #cdd6f4;"
        "  border: 1px solid #585b70;"
        "  border-radius: 6px;"
        "  padding: 8px 12px;"
        "  font-size: 14px;"
        "  selection-background-color: #585b70;"
        "}"
        "QLineEdit:focus {"
        "  border-color: #89b4fa;"
        "}"
    );
    m_containerLayout->addWidget(m_searchInput);

    // Result list
    m_resultList = new QListWidget(m_container);
    m_resultList->setStyleSheet(
        "QListWidget {"
        "  background-color: #1e1e2e;"
        "  color: #cdd6f4;"
        "  border: none;"
        "  outline: none;"
        "  font-size: 13px;"
        "}"
        "QListWidget::item {"
        "  padding: 6px 12px;"
        "  border-radius: 4px;"
        "}"
        "QListWidget::item:selected {"
        "  background-color: #313244;"
        "  color: #cdd6f4;"
        "}"
        "QListWidget::item:hover {"
        "  background-color: #313244;"
        "}"
    );
    m_resultList->setFocusPolicy(Qt::NoFocus);
    m_resultList->setMaximumHeight(300);
    m_containerLayout->addWidget(m_resultList);

    // Connect signals
    connect(m_searchInput, &QLineEdit::textChanged,
            this, &CommandPalette::onSearchTextChanged);
    connect(m_resultList, &QListWidget::itemActivated,
            this, &CommandPalette::onItemActivated);
    connect(m_resultList, &QListWidget::itemClicked,
            this, &CommandPalette::onItemActivated);

    // Install event filter on parent to catch clicks outside
    if (parentWidget()) {
        parentWidget()->installEventFilter(this);
    }
}

void CommandPalette::setSessions(const QList<QPair<QString,QString>>& sessions)
{
    m_sessions = sessions;
}

void CommandPalette::showPalette()
{
    if (parentWidget()) {
        setGeometry(parentWidget()->rect());
    }

    // Position container at top center
    if (parentWidget()) {
        int x = (width() - m_container->width()) / 2;
        m_container->move(x, 40);
    }

    m_searchInput->clear();
    populateResults(QString());

    show();
    raise();
    m_searchInput->setFocus();
}

void CommandPalette::hidePalette()
{
    hide();
}

bool CommandPalette::eventFilter(QObject* watched, QEvent* event)
{
    if (watched == parentWidget() && event->type() == QEvent::Resize) {
        if (isVisible()) {
            setGeometry(parentWidget()->rect());
            int x = (width() - m_container->width()) / 2;
            m_container->move(x, 40);
        }
    }
    return QWidget::eventFilter(watched, event);
}

void CommandPalette::keyPressEvent(QKeyEvent* event)
{
    switch (event->key()) {
    case Qt::Key_Escape:
        hidePalette();
        break;
    case Qt::Key_Down: {
        int next = m_resultList->currentRow() + 1;
        if (next < m_resultList->count()) {
            m_resultList->setCurrentRow(next);
        }
        break;
    }
    case Qt::Key_Up: {
        int prev = m_resultList->currentRow() - 1;
        if (prev >= 0) {
            m_resultList->setCurrentRow(prev);
        }
        break;
    }
    case Qt::Key_Return:
    case Qt::Key_Enter: {
        auto* item = m_resultList->currentItem();
        if (item) {
            onItemActivated(item);
        }
        break;
    }
    default:
        QWidget::keyPressEvent(event);
        break;
    }
}

void CommandPalette::onSearchTextChanged(const QString& text)
{
    populateResults(text);
}

void CommandPalette::onItemActivated(QListWidgetItem* item)
{
    if (!item) return;

    QString actionId = item->data(Qt::UserRole).toString();
    QString sessionId = item->data(Qt::UserRole + 1).toString();

    hidePalette();

    if (actionId == "new_session") {
        emit newSessionRequested();
    } else if (actionId == "open_settings") {
        emit settingsRequested();
    } else if (actionId == "refresh_sessions") {
        emit refreshRequested();
    } else if (actionId == "goto_session") {
        emit actionTriggered(actionId, sessionId);
    } else {
        emit actionTriggered(actionId, sessionId);
    }
}

void CommandPalette::populateResults(const QString& filter)
{
    m_resultList->clear();

    // Add default actions
    for (const auto& action : m_defaultActions) {
        if (filter.isEmpty() || fuzzyMatch(action.label, filter)) {
            auto* item = new QListWidgetItem(action.label, m_resultList);
            item->setData(Qt::UserRole, action.id);
            item->setData(Qt::UserRole + 1, action.sessionId);
        }
    }

    // Add session matches
    if (!filter.isEmpty()) {
        for (const auto& session : m_sessions) {
            if (fuzzyMatch(session.second, filter)) {
                QString label = "Go to: " + session.second;
                auto* item = new QListWidgetItem(label, m_resultList);
                item->setData(Qt::UserRole, "goto_session");
                item->setData(Qt::UserRole + 1, session.first);
            }
        }
    }

    // Select first item
    if (m_resultList->count() > 0) {
        m_resultList->setCurrentRow(0);
    }
}

bool CommandPalette::fuzzyMatch(const QString& text, const QString& pattern) const
{
    // Case-insensitive substring match (simple fuzzy)
    return text.toLower().contains(pattern.toLower());
}

void CommandPalette::mousePressEvent(QMouseEvent* event)
{
    // If click is on the overlay but outside the container, close
    QPoint localPos = event->pos();
    QRect containerRect = m_container->geometry();
    if (!containerRect.contains(localPos)) {
        hidePalette();
        return;
    }
    QWidget::mousePressEvent(event);
}

} // namespace jules
