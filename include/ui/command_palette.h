#pragma once

#include <QWidget>
#include <QLineEdit>
#include <QListWidget>
#include <QVBoxLayout>
#include <QPair>
#include <QString>
#include <QList>

namespace jules {

class CommandPalette : public QWidget {
    Q_OBJECT

public:
    explicit CommandPalette(QWidget* parent = nullptr);
    ~CommandPalette() override;

    void setSessions(const QList<QPair<QString,QString>>& sessions);
    void showPalette();
    void hidePalette();

signals:
    void actionTriggered(const QString& actionId, const QString& sessionId);
    void newSessionRequested();
    void settingsRequested();
    void refreshRequested();

protected:
    bool eventFilter(QObject* watched, QEvent* event) override;
    void keyPressEvent(QKeyEvent* event) override;
    void mousePressEvent(QMouseEvent* event) override;

private slots:
    void onSearchTextChanged(const QString& text);
    void onItemActivated(QListWidgetItem* item);

private:
    void setupUi();
    void populateResults(const QString& filter);
    bool fuzzyMatch(const QString& text, const QString& pattern) const;

    QWidget* m_overlay;
    QWidget* m_container;
    QLineEdit* m_searchInput;
    QListWidget* m_resultList;
    QVBoxLayout* m_containerLayout;

    struct ActionItem {
        QString id;
        QString label;
        QString sessionId;
    };

    QList<ActionItem> m_defaultActions;
    QList<QPair<QString,QString>> m_sessions; // id, name
};

} // namespace jules
